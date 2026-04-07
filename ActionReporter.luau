--!strict
--!optimize 2

-- ============================================================
--  ServerAuthority.luau  v1.0
--  Server-side position authority + temporal packet validation.
--
--  Princípio: O cliente NUNCA é confiável.
--  Toda posição/velocidade recebida é tratada como não verificada.
--  O servidor recalcula e valida com base em física + tempo + ping.
--
--  Fórmula central:
--    expectedDistance = speed * (deltaTime + pingCompensation)
--    if actualDistance > expectedDistance * TOLERANCE → flag
--
--  Integração com o pipeline existente:
--    • Chamado por DataCollector antes de persistir cada Sample
--    • Rejeições são reportadas ao AnomalyDetector como TELEPORT
--    • Replay attacks são reportados como REPLAY_ATTACK
--    • ApplyServerState força rollback no Character do jogador
--
--  Dependências: Types, MathLib (já existentes no projeto)
-- ============================================================

local Players = game:GetService("Players")

local Types   = require(script.Parent.Parent.Shared.Types)
local MathLib = require(script.Parent.Parent.Shared.MathLib)

-- ── Config (pode ser sobrescrito via patchConfig) ─────────────
local CFG = {
	-- ── Velocidade máxima física esperada (studs/s) ────────────
	-- Ajustar para os valores do SEU jogo.
	-- CS2 equivalente: 250 u/s running → ~16 studs/s default Roblox.
	-- Aumentar se o jogo tem sprint, veículos, etc.
	BASE_MAX_SPEED     = 24.0,   -- studs/s: corrida normal com sprint
	CROUCH_MAX_SPEED   = 10.0,   -- studs/s: agachado
	ABSOLUTE_MAX_SPEED = 80.0,   -- studs/s: teto absoluto (physics events)

	-- ── Tolerância: margem de erro sobre o expected ────────────
	-- 1.20 = aceita até 20% acima do esperado (lag, frames grandes)
	-- Aumentar em jogos com física instável; diminuir em FPS rígidos.
	TOLERANCE           = 1.20,

	-- ── Tolerância extra para primeiro sample do jogador ──────
	-- Evita falso positivo no spawn/teleporte legítimo de início.
	SPAWN_GRACE_SAMPLES = 10,

	-- ── Ping compensation cap ─────────────────────────────────
	-- Impede que jogadores com ping propositalmente alto (lag switch)
	-- tenham tolerância infinita.
	MAX_PING_COMPENSATION = 0.400,  -- 400 ms máximo aceito

	-- ── Replay / nonce ────────────────────────────────────────
	-- Janela de tempo máxima para aceitar um packet atrasado.
	-- Packets mais velhos que isso são rejeitados como replay.
	MAX_PACKET_AGE_SEC = 5.0,

	-- ── Rollback ──────────────────────────────────────────────
	-- Número máximo de vezes que ApplyServerState pode ser chamado
	-- por segundo antes de o jogador ser escalado para RESTRICT.
	MAX_ROLLBACKS_PER_SEC = 5,
}

-- ── Resultado de validação ────────────────────────────────────
export type MovementResult = {
	valid       : boolean,
	rejectCode  : string?,   -- motivo para log / AnomalyDetector
	actualDist  : number,
	expectedMax : number,
}

export type PacketResult = {
	valid  : boolean,
	reason : string?,
}

-- ── Estado interno de rollback por jogador ───────────────────
local _rollbackCount  : { [Types.PlayerId]: number } = {}
local _rollbackWindow : { [Types.PlayerId]: number } = {}

-- ============================================================
--  validateMovement
--  Valida se o deslocamento entre dois Samples é fisicamente
--  possível dado o tempo decorrido e o ping do jogador.
--
--  Retorna MovementResult — válido se dentro do esperado.
-- ============================================================
local function validateMovement(
	profile  : Types.PlayerProfile,
	sample   : Types.Sample,
	prev     : Types.Sample
): MovementResult

	-- Grace period: ignora primeiros N samples (spawn, carga inicial)
	if profile.bufSize < CFG.SPAWN_GRACE_SAMPLES then
		return { valid = true, actualDist = 0, expectedMax = 0 }
	end

	local dt : number = sample.t - prev.t
	if dt < 0.005 then
		-- Intervalo irrelevante — skip sem rejeitar
		return { valid = true, actualDist = 0, expectedMax = 0 }
	end

	-- ── Deslocamento real reportado pelo cliente ───────────────
	local actualDist : number = (sample.pos - prev.pos).Magnitude

	-- ── Ping compensation (capped) ────────────────────────────
	--   O servidor precisa compensar a latência do cliente.
	--   Um jogador com 150ms de ping pode ter enviado essa posição
	--   150ms atrás — o servidor dá esse crédito de tempo.
	local pingComp : number = math.min(sample.ping, CFG.MAX_PING_COMPENSATION)

	-- ── Velocidade máxima para este frame ─────────────────────
	--   Respeita physics events (explosões, dashes) registrados
	--   pelo jogo via AntiCheatService.registerPhysicsEvent.
	local now     : number = sample.t
	local physMax : number = MathLib.activePhysicsMax(
		profile.physicsEvents, CFG.ABSOLUTE_MAX_SPEED, now
	)
	-- Velocidade efetiva: menor entre physMax e BASE_MAX_SPEED,
	-- a menos que um physics event explicitamente eleve o limite.
	local effectiveSpeed : number = math.min(
		math.max(physMax, CFG.BASE_MAX_SPEED),
		physMax
	)

	-- ── FPS scale: jogador com 20 fps tem frames maiores ───────
	--   Sem isso, um jogador a 20 fps sempre seria flagado porque
	--   seu delta de posição por frame é 3x maior que a 60 fps.
	local fpsFactor : number = MathLib.fpsScaleFactor(sample.fps)

	-- ── Fórmula central de validação temporal ─────────────────
	--
	--   expectedDistance = speed * (deltaTime + pingCompensation)
	--
	--   Onde:
	--     speed            → velocidade máxima física do estado
	--     deltaTime        → tempo real entre os dois samples
	--     pingCompensation → latência do jogador (janela de crédito)
	--     fpsFactor        → margem para frames grandes (low fps)
	--     TOLERANCE        → margem de erro da rede/física
	--
	local expectedMax : number =
		effectiveSpeed * (dt + pingComp) * fpsFactor * CFG.TOLERANCE

	if actualDist > expectedMax then
		return {
			valid      = false,
			rejectCode = string.format(
				"TEMPORAL_VIOLATION: dist=%.2f max=%.2f spd=%.1f dt=%.3f ping=%.3f fps=%.0f",
				actualDist, expectedMax, effectiveSpeed, dt, pingComp, sample.fps
			),
			actualDist  = actualDist,
			expectedMax = expectedMax,
		}
	end

	return { valid = true, actualDist = actualDist, expectedMax = expectedMax }
end

-- ============================================================
--  validatePacket
--  Verifica timestamp e nonce para bloquear replay attacks.
--
--  Chamado ANTES de qualquer cálculo de estado.
--  Complementa o CryptoLib.decode que já valida o nonce
--  criptográfico — aqui validamos a camada temporal.
-- ============================================================
local function validatePacket(
	packet   : { timestamp: number, nonce: number },
	profile  : Types.PlayerProfile,
	serverNow: number
): PacketResult

	-- ── Anti-Replay: timestamp ────────────────────────────────
	--   Rejeita packets com timestamp no futuro (clock sync attack)
	--   ou muito antigos (replay de captura anterior).
	local age : number = serverNow - packet.timestamp
	if age < -1.0 then
		-- Timestamp no futuro (> 1s de tolerância) — impossível se relógio é monotônico
		return { valid = false, reason = string.format("FUTURE_TIMESTAMP age=%.3fs", age) }
	end
	if age > CFG.MAX_PACKET_AGE_SEC then
		return { valid = false, reason = string.format("STALE_PACKET age=%.3fs", age) }
	end

	-- ── Anti-Replay: nonce ────────────────────────────────────
	--   Nonce deve ser estritamente crescente.
	--   O CryptoLib já verifica nonce criptográfico; aqui validamos
	--   a ordem temporal do nonce para dupla proteção.
	if packet.nonce <= profile.sessionKey.nonce then
		return {
			valid  = false,
			reason = string.format(
				"NONCE_REPLAY got=%d last=%d",
				packet.nonce, profile.sessionKey.nonce
			),
		}
	end

	return { valid = true }
end

-- ============================================================
--  applyServerState  (Rollback)
--  Força o Character do jogador de volta à última posição
--  confirmada pelo servidor (lastServerPos no profile).
--
--  Usado quando validateMovement retorna valid=false.
--  Escalona automaticamente o contador de rollbacks por segundo;
--  muitos rollbacks → jogador marcado para RESTRICT.
-- ============================================================
local function applyServerState(
	profile : Types.PlayerProfile,
	player  : Player
): boolean

	local char = player.Character
	if not char then return false end

	local hrp = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return false end

	-- ── Rate limit: evita spam de rollback (network jitter legítimo) ─
	local now : number = os.clock()
	local pid : Types.PlayerId = profile.playerId
	local win : number = _rollbackWindow[pid] or 0
	local cnt : number = _rollbackCount[pid]  or 0

	if now - win > 1.0 then
		_rollbackWindow[pid] = now
		_rollbackCount[pid]  = 1
	else
		cnt += 1
		_rollbackCount[pid] = cnt
		-- Devolve true mas sinaliza ao chamador que o limite foi atingido
		if cnt > CFG.MAX_ROLLBACKS_PER_SEC then
			-- Chamador deve escalar suspicion — demasiados rollbacks por segundo
			-- são um sinal de speedhack contínuo, não jitter pontual.
			hrp.CFrame = CFrame.new(profile.lastServerPos)
			return false   -- false = limite atingido (requer ação adicional)
		end
	end

	-- Aplica o estado correto
	hrp.CFrame = CFrame.new(profile.lastServerPos)
	return true
end

-- ============================================================
--  updateServerPos
--  Deve ser chamado pelo DataCollector APÓS o Sample ser aceito.
--  Mantém lastServerPos / lastPosTime sincronizados com o
--  estado validado mais recente.
-- ============================================================
local function updateServerPos(
	profile : Types.PlayerProfile,
	sample  : Types.Sample
): ()
	profile.lastServerPos = sample.pos
	profile.lastPosTime   = sample.t
end

-- ── API pública ───────────────────────────────────────────────
local ServerAuthority = {}

ServerAuthority.CFG = CFG

ServerAuthority.validateMovement = validateMovement
ServerAuthority.validatePacket   = validatePacket
ServerAuthority.applyServerState = applyServerState
ServerAuthority.updateServerPos  = updateServerPos

-- ── patchConfig: permite override via AntiCheatService.patchConfig
function ServerAuthority.patch(patch: { [string]: number | boolean }): ()
	for k, v in patch do
		if CFG[k] ~= nil then (CFG :: any)[k] = v end
	end
end

return ServerAuthority
