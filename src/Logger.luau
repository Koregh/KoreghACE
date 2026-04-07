--!strict
--!optimize 2

-- ============================================================
--  Logger.luau  v2.0 — Unchanged architecture from v1.
--  In-memory ring (1000) + async DataStore flush (30s).
-- ============================================================

local DataStoreService = game:GetService("DataStoreService")
local RunService       = game:GetService("RunService")
local Types            = require(script.Parent.Parent.Shared.Types)

local LOG_CAP     : number = 1000
local FLUSH_SEC   : number = 30
local DS_PREFIX   : string = "ACLog_v2_"

type LogEntry = {
	timestamp  : number,
	playerId   : Types.PlayerId,
	playerName : string,
	decision   : Types.Decision,
	anomaly    : Types.AnomalyRecord?,
}

local _ring     : { LogEntry } = table.create(LOG_CAP)
local _ringHead : number       = 1
local _ringSize : number       = 0
local _pidIdx   : { [Types.PlayerId]: { number } } = {}
local _flush    : { LogEntry } = {}
local _store    : DataStore?   = nil

if not RunService:IsStudio() then
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore("AdaptiveAC_Logs_v2")
	end)
	if ok then _store = ds :: DataStore end
end

local Logger = {}

function Logger.logDecision(
	player  : Player,
	decision: Types.Decision,
	anomaly : Types.AnomalyRecord?
): ()
	local entry : LogEntry = {
		timestamp  = os.time(),
		playerId   = player.UserId,
		playerName = player.Name,
		decision   = decision,
		anomaly    = anomaly,
	}

	_ring[_ringHead] = entry
	local pid : Types.PlayerId = player.UserId
	local idx = _pidIdx[pid]
	if not idx then idx = {}; _pidIdx[pid] = idx end
	idx[#idx + 1] = _ringHead
	_ringHead = (_ringHead % LOG_CAP) + 1
	_ringSize = math.min(_ringSize + 1, LOG_CAP)

	if decision.action ~= "NONE" then
		_flush[#_flush + 1] = entry
	end
end

function Logger.getPlayerLogs(pid: Types.PlayerId, limit: number): { LogEntry }
	local slots = _pidIdx[pid]
	if not slots then return {} end
	local result : { LogEntry } = {}
	for i = #slots, 1, -1 do
		local e : LogEntry? = _ring[slots[i]]
		if e and e.playerId == pid then
			result[#result + 1] = e
			if #result >= limit then break end
		end
	end
	return result
end

function Logger.getRecentLogs(limit: number): { LogEntry }
	local result : { LogEntry } = {}
	local cursor : number = ((_ringHead - 2) % LOG_CAP) + 1
	for _ = 1, math.min(_ringSize, limit) do
		if _ring[cursor] then result[#result + 1] = _ring[cursor] end
		cursor = ((cursor - 2) % LOG_CAP) + 1
	end
	return result
end

local _flushAcc : number = 0.0
RunService.Heartbeat:Connect(function(dt: number)
	_flushAcc += dt
	if _flushAcc < FLUSH_SEC then return end
	_flushAcc -= FLUSH_SEC

	if #_flush == 0 or not _store then _flush = {}; return end
	local batch = _flush
	_flush = {}

	local byPlayer : { [Types.PlayerId]: { any } } = {}
	for _, e in batch do
		local pid = e.playerId
		if not byPlayer[pid] then byPlayer[pid] = {} end
		byPlayer[pid][#byPlayer[pid] + 1] = {
			t  = e.timestamp,
			pn = e.playerName,
			a  = e.decision.action,
			s  = math.floor(e.decision.suspicion),
			k  = e.anomaly and e.anomaly.kind or nil,
			ex = e.anomaly and e.anomaly.extra or nil,
		}
	end

	for pid, entries in byPlayer do
		local key : string = DS_PREFIX .. tostring(pid)
		task.spawn(function()
			pcall(function()
				(_store :: DataStore):UpdateAsync(key, function(existing: any)
					local list : { any } = existing or {}
					for _, e in entries do list[#list + 1] = e end
					if #list > 500 then
						list = table.move(list, #list - 499, #list, 1, {})
					end
					return list
				end)
			end)
		end)
	end
end)

return Logger
