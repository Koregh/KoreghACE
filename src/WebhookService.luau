--!strict
--!optimize 2

--[[
	╔══════════════════════════════════════════════════════════════╗
	║                    WebhookService                           ║
	║                   KoreghACE  ·  v1.0                        ║
	╠══════════════════════════════════════════════════════════════╣
	║  Envia notificações de eventos do anti-cheat para um        ║
	║  endpoint HTTP externo (Discord, servidor próprio, etc).    ║
	║                                                             ║
	║  ⚠  HttpService precisa estar HABILITADO nas configurações  ║
	║     do jogo (Game Settings → Security → Allow HTTP).        ║
	║                                                             ║
	║  COMO USAR                                                  ║
	║  ─────────────────────────────────────────────────────────  ║
	║  1. Configure a URL do seu endpoint em CFG.URL abaixo.      ║
	║  2. Ajuste CFG.MIN_LEVEL para controlar quais eventos       ║
	║     disparam o webhook (padrão: ALERT e acima).             ║
	║  3. Opcionalmente sobrescreva buildPayload() com a          ║
	║     estrutura JSON que seu endpoint espera.                 ║
	║                                                             ║
	║  INTEGRAÇÃO COM AntiCheatService                            ║
	║  ─────────────────────────────────────────────────────────  ║
	║  No AntiCheatService, dentro do Heartbeat, após            ║
	║  DecisionEngine.evaluate(), adicione:                       ║
	║                                                             ║
	║    if decision.action ~= "NONE" then                        ║
	║        WebhookService.notify(player, decision, latest)      ║
	║    end                                                      ║
	╚══════════════════════════════════════════════════════════════╝
]]

local HttpService = game:GetService("HttpService")
local RunService  = game:GetService("RunService")
local Players     = game:GetService("Players")

local Types = require(script.Parent.Shared.Types)

-- ─── Configuração ────────────────────────────────────────────────────────────

local CFG = {
	-- ┌─────────────────────────────────────────────────────────────┐
	-- │  URL do seu webhook.                                        │
	-- │  Discord  → https://discord.com/api/webhooks/ID/TOKEN       │
	-- │  Próprio  → https://seuservidor.com/koregh/events           │
	-- └─────────────────────────────────────────────────────────────┘
	URL = "https://discord.com/api/webhooks/SEU_ID/SEU_TOKEN",

	-- Nível mínimo para disparar o webhook.
	-- Ordem: CLEAN < MONITOR < ALERT < RESTRICT < SHADOWBAN < REMOVE
	MIN_LEVEL = "ALERT",

	-- Número máximo de requisições enfileiradas aguardando envio.
	-- Eventos acima desse limite são descartados silenciosamente
	-- para não acumular memória em caso de endpoint indisponível.
	QUEUE_CAP = 50,

	-- Intervalo em segundos entre tentativas de envio (rate-limit
	-- interno). Discord limita ~5 req/2s por webhook; ajuste
	-- conforme seu endpoint.
	SEND_INTERVAL = 0.5,

	-- Número de tentativas por evento antes de descartar.
	MAX_RETRIES = 3,

	-- Timeout de cada requisição HTTP em segundos.
	TIMEOUT = 5,

	-- Incluir dados brutos do sample no payload (posição, vel, etc).
	-- Desative se o payload for muito grande ou não necessário.
	INCLUDE_SAMPLE = true,
}

-- Mapa de nível → peso numérico (para comparação MIN_LEVEL)
local LEVEL_ORDER: { [string]: number } = {
	CLEAN     = 0,
	MONITOR   = 1,
	ALERT     = 2,
	RESTRICT  = 3,
	SHADOWBAN = 4,
	REMOVE    = 5,
}

-- Emoji por nível (padrão Discord — remova se não usar Discord)
local LEVEL_EMOJI: { [string]: string } = {
	CLEAN     = "✅",
	MONITOR   = "👁️",
	ALERT     = "⚠️",
	RESTRICT  = "🔒",
	SHADOWBAN = "👻",
	REMOVE    = "🔨",
}

-- ─── Tipagem interna ──────────────────────────────────────────────────────────

type QueueEntry = {
	payload  : string,   -- JSON já serializado
	retries  : number,
}

-- ─── Estado interno ───────────────────────────────────────────────────────────

local _queue    : { QueueEntry } = {}
local _sendAcc  : number         = 0.0

-- ─── buildPayload ─────────────────────────────────────────────────────────────
--[[
	┌─────────────────────────────────────────────────────────────────┐
	│  PERSONALIZE AQUI                                               │
	│                                                                 │
	│  Esta função converte os dados do evento em um JSON pronto      │
	│  para ser enviado ao seu endpoint.                              │
	│                                                                 │
	│  O preset abaixo gera um Discord Embed. Se você usar um         │
	│  servidor próprio, substitua o corpo da função pelo shape       │
	│  JSON que sua API espera.                                       │
	│                                                                 │
	│  Variáveis disponíveis:                                         │
	│    player   : Player            — instância Roblox              │
	│    decision : Types.Decision    — action, reason, suspicion     │
	│    anomaly  : Types.AnomalyRecord? — kind, severity, extra, t   │
	│    gameId   : number            — game.PlaceId                  │
	│    serverId : string            — game.JobId                    │
	│    ts       : number            — os.time() (Unix)              │
	└─────────────────────────────────────────────────────────────────┘
]]
local function buildPayload(
	player   : Player,
	decision : Types.Decision,
	anomaly  : Types.AnomalyRecord?
): string

	local gameId   : number = game.PlaceId
	local serverId : string = game.JobId
	local ts       : number = os.time()
	local emoji    : string = LEVEL_EMOJI[decision.reason] or "🔍"

	-- ── Campos de debug do sample (opcional) ─────────────────────
	local sampleInfo : string = ""
	if CFG.INCLUDE_SAMPLE and anomaly and anomaly.raw then
		local s = anomaly.raw
		sampleInfo = string.format(
			"\n> pos `(%.1f, %.1f, %.1f)` · vel `%.1f st/s` · ping `%dms` · fps `%d`",
			s.pos.X, s.pos.Y, s.pos.Z,
			math.sqrt(s.vel.X^2 + s.vel.Y^2 + s.vel.Z^2),
			math.floor(s.ping * 1000),
			math.floor(s.fps)
		)
	end

	-- ── Anomaly detail ────────────────────────────────────────────
	local anomalyLine : string = "—"
	if anomaly then
		anomalyLine = string.format(
			"%s · sev `%.2f`%s",
			anomaly.kind,
			anomaly.severity,
			anomaly.extra and (" · `" .. anomaly.extra .. "`") or ""
		)
	end

	-- ── Discord Embed (preset padrão) ─────────────────────────────
	-- Substitua este bloco pela estrutura JSON do seu endpoint.
	local color : number =
		if decision.reason == "REMOVE"    then 0xED4245  -- vermelho
		elseif decision.reason == "SHADOWBAN" then 0xFEE75C  -- amarelo
		elseif decision.reason == "RESTRICT"  then 0xFF8C00  -- laranja
		else                                      0x5865F2   -- azul

	local description : string = string.format(
		"%s **%s** › `%s`\n\n" ..
		"**Suspicion** `%.1f / 100`\n" ..
		"**Anomaly** %s\n" ..
		"**Server** `%s`\n" ..
		"**Place** `%d`\n" ..
		"**Unix** `%d`%s",
		emoji,
		player.Name,
		decision.action,
		decision.suspicion,
		anomalyLine,
		serverId ~= "" and serverId:sub(1, 18) .. "…" or "Studio",
		gameId,
		ts,
		sampleInfo
	)

	local embed = {
		title       = string.format("[KoreghACE] %s · %s", decision.reason, player.Name),
		description = description,
		color       = color,
		footer      = { text = "KoreghACE Anti-Cheat" },
		timestamp   = DateTime.fromUnixTimestamp(ts):ToIsoDate(),
	}

	local body = { embeds = { embed } }
	return HttpService:JSONEncode(body)

	--[[
	── EXEMPLO: payload para servidor próprio ──────────────────────
	local body = {
		event      = "ac_decision",
		playerId   = player.UserId,
		playerName = player.Name,
		action     = decision.action,
		level      = decision.reason,
		suspicion  = decision.suspicion,
		anomaly    = anomaly and {
			kind     = anomaly.kind,
			severity = anomaly.severity,
			extra    = anomaly.extra,
		} or nil,
		gameId     = gameId,
		serverId   = serverId,
		timestamp  = ts,
	}
	return HttpService:JSONEncode(body)
	]]
end

-- ─── API pública ──────────────────────────────────────────────────────────────

local WebhookService = {}

--[[
	Enfileira uma notificação para envio assíncrono.

	Chamada típica (em AntiCheatService, no Heartbeat):
	  WebhookService.notify(player, decision, latestAnomaly)
]]
function WebhookService.notify(
	player   : Player,
	decision : Types.Decision,
	anomaly  : Types.AnomalyRecord?
): ()
	-- Filtra por nível mínimo
	local minW : number = LEVEL_ORDER[CFG.MIN_LEVEL] or 2
	local evW  : number = LEVEL_ORDER[decision.reason] or 0
	if evW < minW then return end

	if #_queue >= CFG.QUEUE_CAP then return end   -- overflow guard

	local ok, payload = pcall(buildPayload, player, decision, anomaly)
	if not ok then
		warn("[WebhookService] buildPayload error:", payload)
		return
	end

	_queue[#_queue + 1] = { payload = payload, retries = 0 }
end

-- Permite ao desenvolvedor trocar a URL em runtime (útil para testes).
function WebhookService.setUrl(url: string): ()
	CFG.URL = url
end

-- Expõe CFG para o desenvolvedor poder fazer patch (igual ao AnomalyDetector).
WebhookService.CFG = CFG

-- ─── Loop de envio assíncrono ────────────────────────────────────────────────

RunService.Heartbeat:Connect(function(dt: number)
	_sendAcc += dt
	if _sendAcc < CFG.SEND_INTERVAL then return end
	_sendAcc -= CFG.SEND_INTERVAL

	if #_queue == 0 then return end
	if CFG.URL == "" or CFG.URL:find("SEU_ID") then return end   -- não configurado

	local entry : QueueEntry = table.remove(_queue, 1) :: QueueEntry

	task.spawn(function()
		local ok, err = pcall(function()
			HttpService:PostAsync(
				CFG.URL,
				entry.payload,
				Enum.HttpContentType.ApplicationJson,
				false
			)
		end)

		if not ok then
			entry.retries += 1
			if entry.retries < CFG.MAX_RETRIES then
				-- Reinsere no final da fila para retry
				_queue[#_queue + 1] = entry
			else
				warn(string.format(
					"[WebhookService] Descartado após %d tentativas: %s",
					CFG.MAX_RETRIES, tostring(err)
				))
			end
		end
	end)
end)

return WebhookService
