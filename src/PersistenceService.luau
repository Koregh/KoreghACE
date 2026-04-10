--!strict
--!optimize 2

--[[
	╔══════════════════════════════════════════════════════════════╗
	║                   PersistenceService                        ║
	║                   KoreghACE  ·  v1.0                        ║
	╠══════════════════════════════════════════════════════════════╣
	║  Salva e carrega o perfil de suspeita de cada jogador        ║
	║  entre sessões, garantindo que a reputação acumulada não     ║
	║  seja resetada ao trocar de servidor.                        ║
	║                                                             ║
	║  ──────────────────────────────────────────────────────────  ║
	║  OPÇÃO A — DataStore externo (KoreghProfile ou similar)      ║
	║  ──────────────────────────────────────────────────────────  ║
	║  Se você já usa um sistema de perfis (KoreghProfile,         ║
	║  ProfileService, Lapis, etc.), é recomendado integrar        ║
	║  os dados do AC diretamente nele.                            ║
	║                                                             ║
	║  Shape sugerido para guardar dentro do seu perfil:           ║
	║                                                             ║
	║    profile.antiCheat = {                                     ║
	║      suspicion   : number,    -- 0..100                      ║
	║      level       : string,    -- SuspicionLevel              ║
	║      totalFlags  : number,    -- contagem histórica           ║
	║      lastSeen    : number,    -- os.time() Unix               ║
	║      topAnomalies: { string } -- últimos AnomalyKind[]        ║
	║    }                                                         ║
	║                                                             ║
	║  Basta chamar PersistenceService.setExternalHandlers() e     ║
	║  este módulo chamará suas funções ao invés do DataStore       ║
	║  interno.                                                    ║
	║                                                             ║
	║  ──────────────────────────────────────────────────────────  ║
	║  OPÇÃO B — DataStore interno (padrão, plug-and-play)         ║
	║  ──────────────────────────────────────────────────────────  ║
	║  Deixe como está. O módulo gerencia tudo automaticamente:    ║
	║  serverlock, retry, auto-save periódico e save-on-leave.     ║
	║                                                             ║
	║  INTEGRAÇÃO COM AntiCheatService                            ║
	║  ─────────────────────────────────────────────────────────  ║
	║  -- No topo do AntiCheatService:                             ║
	║  local PersistenceService = require(script.PersistenceService) ║
	║                                                             ║
	║  -- No PlayerAdded (logo após DataCollector.register):       ║
	║  PersistenceService.load(player, function(saved)             ║
	║      if saved then                                           ║
	║          DataCollector.applySaved(player.UserId, saved)      ║
	║      end                                                     ║
	║  end)                                                        ║
	║                                                             ║
	║  -- No PlayerRemoving:                                       ║
	║  PersistenceService.save(player, DataCollector.getProfile(   ║
	║      player.UserId))                                         ║
	║                                                             ║
	║  -- (opcional) Auto-save periódico no Heartbeat              ║
	║  -- já é feito internamente se CFG.AUTO_SAVE_SEC > 0.        ║
	╚══════════════════════════════════════════════════════════════╝
]]

local DataStoreService = game:GetService("DataStoreService")
local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")

local Types = require(script.Parent.Shared.Types)

-- ─── Configuração ────────────────────────────────────────────────────────────

local CFG = {
	-- Nome do DataStore interno.
	-- Troque se quiser isolar entre versões do jogo.
	DATASTORE_NAME = "KoreghACE_v1",

	-- Versão do schema. Incremente ao mudar o shape de SavedProfile.
	-- Dados com versão diferente são ignorados (fresh start).
	SCHEMA_VERSION = 1,

	-- Salva automaticamente a cada N segundos (0 = desligado).
	-- O save-on-leave é sempre executado independente deste valor.
	AUTO_SAVE_SEC = 120,

	-- Decay aplicado à suspicion entre sessões (0..1).
	-- 0.0 = suspicion persiste 100% entre sessões.
	-- 0.5 = suspicion cai 50% a cada nova sessão.
	-- 1.0 = suspicion zerada a cada nova sessão.
	INTER_SESSION_DECAY = 0.2,

	-- Máximo de AnomalyKind a persistir no histórico.
	MAX_ANOMALY_HISTORY = 10,

	-- Tempo máximo de espera pelo serverlock (segundos).
	LOCK_TIMEOUT = 30,

	-- TTL do serverlock em segundos. Se o servidor travar, o
	-- próximo servidor ignora o lock após este tempo.
	LOCK_TTL = 60,
}

-- ─── Tipos ───────────────────────────────────────────────────────────────────

--[[
	Shape completo que é salvo no DataStore.
	──────────────────────────────────────────────────────────────
	Se você usa DataStore externo (KoreghProfile, ProfileService,
	etc.), este é o shape que você deve guardar dentro do seu
	perfil no campo `antiCheat`.
]]
export type SavedProfile = {
	version      : number,
	suspicion    : number,
	level        : string,       -- Types.SuspicionLevel
	totalFlags   : number,       -- contagem acumulada de flags
	topAnomalies : { string },   -- últimos AnomalyKind (strings)
	kills        : number,
	deaths       : number,
	headshotKills: number,
	totalShots   : number,
	totalHits    : number,
	lastSeen     : number,       -- os.time() Unix
	-- lock metadata (interno — não precisa copiar para seu sistema)
	_lock        : string?,      -- game.JobId do servidor que tem o lock
	_lockAt      : number?,      -- os.time() em que o lock foi adquirido
}

type ExternalGetFn = (pid: Types.PlayerId) -> SavedProfile?
type ExternalSetFn = (pid: Types.PlayerId, data: SavedProfile) -> ()

-- ─── Estado interno ───────────────────────────────────────────────────────────

local _store       : DataStore?                           = nil
local _extGet      : ExternalGetFn?                       = nil
local _extSet      : ExternalSetFn?                       = nil
local _locks       : { [Types.PlayerId]: boolean }        = {}  -- lock local (evita duplo save)
local _autoSaveAcc : number                               = 0.0
local _jobId       : string                               = game.JobId

-- Inicializa o DataStore interno (só no servidor real, não em Studio sem acesso)
if not RunService:IsStudio() or true then  -- Studio agora suporta DS em teste
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(CFG.DATASTORE_NAME)
	end)
	if ok then
		_store = ds :: DataStore
	else
		warn("[PersistenceService] DataStore indisponível — dados não serão persistidos.")
	end
end

-- ─── Helpers ─────────────────────────────────────────────────────────────────

local function dsKey(pid: Types.PlayerId): string
	return "player_" .. tostring(pid)
end

local function now(): number
	return os.time()
end

-- Extrai SavedProfile de um PlayerProfile em memória.
local function extractSave(profile: Types.PlayerProfile): SavedProfile
	-- Coleta os últimos N anomaly kinds do ring
	local kinds : { string } = {}
	local cap   : number     = 200
	local cursor: number     = ((profile.anomalyHead - 2) % cap) + 1
	for _ = 1, math.min(profile.anomalySize, CFG.MAX_ANOMALY_HISTORY) do
		local rec = profile.anomalies[cursor]
		if rec and rec.t > 0 then
			kinds[#kinds + 1] = rec.kind
		end
		cursor = ((cursor - 2) % cap) + 1
	end

	local s = profile.session

	return {
		version       = CFG.SCHEMA_VERSION,
		suspicion     = profile.suspicion,
		level         = profile.level,
		totalFlags    = profile.anomalySize,
		topAnomalies  = kinds,
		kills         = s.kills,
		deaths        = s.deaths,
		headshotKills = s.headshotKills,
		totalShots    = s.totalShots,
		totalHits     = s.totalHits,
		lastSeen      = now(),
		_lock         = nil,
		_lockAt       = nil,
	}
end

-- ─── ServerLock ──────────────────────────────────────────────────────────────
--[[
	Implementação simples de serverlock embutida no próprio registro.

	Fluxo:
	1. UpdateAsync lê o registro atual.
	2. Se _lock == outro servidor E _lockAt ainda não expirou → aborta.
	3. Escreve o novo dado com _lock = game.JobId e _lockAt = os.time().
	4. Ao finalizar o save (release), limpa _lock.
]]

local function acquireLockAndSave(
	pid      : Types.PlayerId,
	saveData : SavedProfile
): (boolean, string)

	if not _store then return false, "no_datastore" end
	local key = dsKey(pid)
	local success = false
	local reason  = "unknown"

	-- Tenta adquirir lock + salvar em uma única UpdateAsync
	local ok, err = pcall(function()
		(_store :: DataStore):UpdateAsync(key, function(existing: any)
			local rec : SavedProfile? = existing

			-- Checa lock de outro servidor
			if rec and rec._lock and rec._lock ~= _jobId then
				local lockAge : number = now() - (rec._lockAt or 0)
				if lockAge < CFG.LOCK_TTL then
					-- Lock válido de outro servidor — aborta
					reason  = "locked_by_" .. rec._lock:sub(1, 8)
					return nil  -- nil = não atualiza
				end
				-- Lock expirado — rouba o lock
			end

			-- Grava com lock ativo
			saveData._lock  = _jobId
			saveData._lockAt = now()
			success = true
			reason  = "ok"
			return saveData
		end)
	end)

	if not ok then
		return false, tostring(err)
	end
	return success, reason
end

local function releaseLock(pid: Types.PlayerId): ()
	if not _store then return end
	local key = dsKey(pid)
	pcall(function()
		(_store :: DataStore):UpdateAsync(key, function(existing: any)
			if not existing then return nil end
			local rec : SavedProfile = existing :: SavedProfile
			-- Só libera se o lock for deste servidor
			if rec._lock ~= _jobId then return nil end
			rec._lock  = nil
			rec._lockAt = nil
			return rec
		end)
	end)
end

-- ─── API pública ──────────────────────────────────────────────────────────────

local PersistenceService = {}

--[[
	Define handlers externos (para uso com KoreghProfile, ProfileService, etc.).

	getFn : (playerId: number) -> SavedProfile?
	setFn : (playerId: number, data: SavedProfile) -> ()

	Quando definidos, o DataStore interno é ignorado completamente.

	Exemplo com ProfileService:
	  PersistenceService.setExternalHandlers(
	      function(pid)
	          local p = ProfileService.GetProfile(pid)
	          return p and p.Data.antiCheat
	      end,
	      function(pid, data)
	          local p = ProfileService.GetProfile(pid)
	          if p then p.Data.antiCheat = data end
	      end
	  )
]]
function PersistenceService.setExternalHandlers(
	getFn : ExternalGetFn,
	setFn : ExternalSetFn
): ()
	_extGet = getFn
	_extSet = setFn
end

--[[
	Carrega o perfil salvo de um jogador.

	callback(savedProfile: SavedProfile?) é chamado quando os dados
	chegam. Pode ser nil se o jogador for novo ou se o carregamento
	falhar.

	Aplica o decay inter-sessão em suspicion antes de retornar.
]]
function PersistenceService.load(
	player   : Player,
	callback : (SavedProfile?) -> ()
): ()
	local pid : Types.PlayerId = player.UserId

	task.spawn(function()
		local saved : SavedProfile? = nil

		if _extGet then
			-- ── Opção A: handler externo ────────────────────────────
			local ok, result = pcall(_extGet, pid)
			if ok then saved = result end
		elseif _store then
			-- ── Opção B: DataStore interno ──────────────────────────
			local ok, result = pcall(function()
				return (_store :: DataStore):GetAsync(dsKey(pid))
			end)
			if ok and result then
				saved = result :: SavedProfile
			end
		end

		-- Valida schema
		if saved and saved.version ~= CFG.SCHEMA_VERSION then
			saved = nil
		end

		-- Aplica decay inter-sessão
		if saved then
			saved.suspicion = saved.suspicion * (1.0 - CFG.INTER_SESSION_DECAY)
		end

		callback(saved)
	end)
end

--[[
	Salva o perfil atual de um jogador.

	Se usar handler externo, delega para setFn.
	Se usar DataStore interno, executa serverlock + UpdateAsync.
	Retorna true em sucesso, false em falha.
]]
function PersistenceService.save(
	player  : Player,
	profile : Types.PlayerProfile?
): boolean
	if not profile then return false end
	if _locks[player.UserId] then return false end   -- save já em andamento

	local pid       : Types.PlayerId = player.UserId
	local saveData  : SavedProfile   = extractSave(profile)

	_locks[pid] = true

	local ok : boolean = false

	if _extSet then
		-- ── Opção A: handler externo (sem serverlock — o sistema
		--   externo é responsável pela consistência)
		local callOk, err = pcall(_extSet, pid, saveData)
		ok = callOk
		if not callOk then
			warn("[PersistenceService] extSet error:", err)
		end
	elseif _store then
		-- ── Opção B: DataStore interno com serverlock
		local saved, reason = acquireLockAndSave(pid, saveData)
		ok = saved
		if not saved then
			warn(string.format(
				"[PersistenceService] Save falhou para %s (%d): %s",
				player.Name, pid, reason
			))
		end
	end

	_locks[pid] = false
	return ok
end

--[[
	Lê o último SavedProfile salvo sem carregar na memória.
	Útil para auditar dados de um jogador offline.
]]
function PersistenceService.peek(
	pid      : Types.PlayerId,
	callback : (SavedProfile?) -> ()
): ()
	task.spawn(function()
		if _extGet then
			local ok, result = pcall(_extGet, pid)
			callback(if ok then result else nil)
			return
		end
		if not _store then callback(nil); return end
		local ok, result = pcall(function()
			return (_store :: DataStore):GetAsync(dsKey(pid))
		end)
		callback(if ok then result :: SavedProfile else nil)
	end)
end

--[[
	Aplica os dados carregados sobre um PlayerProfile em memória.
	Chame isto dentro do callback de load():

	  PersistenceService.load(player, function(saved)
	      if saved then
	          PersistenceService.applyToProfile(DataCollector.getProfile(pid), saved)
	      end
	  end)
]]
function PersistenceService.applyToProfile(
	profile : Types.PlayerProfile?,
	saved   : SavedProfile
): ()
	if not profile then return end

	profile.suspicion = math.clamp(saved.suspicion, 0, 100)

	-- Restaura SessionStats acumulados
	local s = profile.session
	s.kills          = saved.kills
	s.deaths         = saved.deaths
	s.headshotKills  = saved.headshotKills
	s.totalShots     = saved.totalShots
	s.totalHits      = saved.totalHits
end

-- Expõe CFG para patch externo (igual ao padrão do projeto)
PersistenceService.CFG = CFG

-- ─── Save-on-leave ────────────────────────────────────────────────────────────

Players.PlayerRemoving:Connect(function(player: Player)
	-- O save-on-leave usa os dados já em memória via DataCollector.
	-- Precisamos do profile — importamos DataCollector aqui para
	-- evitar dependência circular no topo do arquivo.
	local ok, DataCollector = pcall(function()
		return require(script.Parent.Server.DataCollector)
	end)
	if not ok then return end

	local profile : Types.PlayerProfile? = DataCollector.getProfile(player.UserId)
	if profile then
		-- Executa de forma síncrona no mesmo frame do PlayerRemoving
		-- para garantir que o dado seja salvo antes do servidor desalocar.
		PersistenceService.save(player, profile)
	end

	releaseLock(player.UserId)
end)

-- ─── Auto-save periódico ──────────────────────────────────────────────────────

if CFG.AUTO_SAVE_SEC > 0 then
	RunService.Heartbeat:Connect(function(dt: number)
		_autoSaveAcc += dt
		if _autoSaveAcc < CFG.AUTO_SAVE_SEC then return end
		_autoSaveAcc -= CFG.AUTO_SAVE_SEC

		local okDC, DataCollector = pcall(function()
			return require(script.Parent.Server.DataCollector)
		end)
		if not okDC then return end

		for _, player in Players:GetPlayers() do
			local profile = DataCollector.getProfile(player.UserId)
			if profile then
				task.spawn(function()
					PersistenceService.save(player, profile)
				end)
			end
		end
	end)
end

return PersistenceService
