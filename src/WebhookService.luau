--!strict
--!optimize 2
local HttpService = game:GetService("HttpService")
local RunService  = game:GetService("RunService")
local Players     = game:GetService("Players")

local Types = require(script.Parent.Shared.Types)


local CFG = {
	URL = "https://discord.com/api/webhooks/YOUR_ID/TOKEN",

	-- CLEAN < MONITOR < ALERT < RESTRICT < SHADOWBAN < REMOVE
	MIN_LEVEL = "ALERT",

	-- Maximum number of queued requests waiting to be sent.
	-- Events above this threshold are silently discarded
	-- to not accumulate memory in case of an unavailable endpoint.
	QUEUE_CAP = 50,

	-- Interval in seconds between sending attempts (rate-limit
	-- internal). Discord limits ~5 req/2s per webhook; adjustment
	-- as per your endpoint.
	SEND_INTERVAL = 0.5,

	-- Number of retries per event before discarding.
	MAX_RETRIES = 3,

	TIMEOUT = 5,

	-- Include raw sample data in the payload (position, speed, etc.).
	-- Disable if payload is too large or not necessary.
	INCLUDE_SAMPLE = true,
}

local LEVEL_ORDER: { [string]: number } = {
	CLEAN     = 0,
	MONITOR   = 1,
	ALERT     = 2,
	RESTRICT  = 3,
	SHADOWBAN = 4,
	REMOVE    = 5,
}

local LEVEL_EMOJI: { [string]: string } = {
	CLEAN     = "✅",
	MONITOR   = "👁️",
	ALERT     = "⚠️",
	RESTRICT  = "🔒",
	SHADOWBAN = "👻",
	REMOVE    = "🔨",
}

type QueueEntry = {
	payload  : string,  
	retries  : number,
}

local _queue    : { QueueEntry } = {}
local _sendAcc  : number         = 0.0

local function buildPayload(
	player   : Player,
	decision : Types.Decision,
	anomaly  : Types.AnomalyRecord?
): string

	local gameId   : number = game.PlaceId
	local serverId : string = game.JobId
	local ts       : number = os.time()
	local emoji    : string = LEVEL_EMOJI[decision.reason] or "🔍"

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

	local anomalyLine : string = "—"
	if anomaly then
		anomalyLine = string.format(
			"%s · sev `%.2f`%s",
			anomaly.kind,
			anomaly.severity,
			anomaly.extra and (" · `" .. anomaly.extra .. "`") or ""
		)
	end

	-- Replace this block with the JSON structure of your endpoint.
	local color : number =
		if decision.reason == "REMOVE"    then 0xED4245  -- Red
		elseif decision.reason == "SHADOWBAN" then 0xFEE75C  -- Yellow
		elseif decision.reason == "RESTRICT"  then 0xFF8C00  -- Orange
		else                                      0x5865F2   -- Blue

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


local WebhookService = {}

function WebhookService.notify(
	player   : Player,
	decision : Types.Decision,
	anomaly  : Types.AnomalyRecord?
): ()
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

function WebhookService.setUrl(url: string): ()
	CFG.URL = url
end

WebhookService.CFG = CFG


RunService.Heartbeat:Connect(function(dt: number)
	_sendAcc += dt
	if _sendAcc < CFG.SEND_INTERVAL then return end
	_sendAcc -= CFG.SEND_INTERVAL

	if #_queue == 0 then return end
	if CFG.URL == "" or CFG.URL:find("YOUR_ID") then return end  

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
				_queue[#_queue + 1] = entry
			else
				warn(string.format(
					"[WebhookService] Discarded after %d attempts: %s",
					CFG.MAX_RETRIES, tostring(err)
				))
			end
		end
	end)
end)

return WebhookService
