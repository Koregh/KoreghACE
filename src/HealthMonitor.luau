--!strict
--!optimize 2

local RunService = game:GetService("RunService")

export type SystemStatus = "OK" | "DEGRADED" | "FAIL"

export type HealthSnapshot = {
	status          : SystemStatus,
	uptimeSeconds   : number,
	activePlayers   : number,
	eventsPerSecond : number,
	analysisHz      : number,
	latencyAvgMs    : number,
	latencyP95Ms    : number,
	latencyP99Ms    : number,
	estimatedMemKB  : number,
	totalFlagsLast60s : number,
	highRiskPlayers   : number,
}

export type PlayerMetrics = {
	playerId      : number,
	suspicion     : number,
	riskScore     : number,
	anomalyCount  : number,
	level         : string,
	topAnomalies  : { string },
	fps           : number,
	ping          : number,
}

local _startTime    : number = os.clock()
local _eventCount   : number = 0
local _eventWindow  : number = os.clock()
local _eps          : number = 0.0
local _epsCount     : number = 0

local LAT_CAP    : number = 200
local _latRing   : { number } = table.create(LAT_CAP, 0.0)
local _latHead   : number = 1
local _latSize   : number = 0

local _flagRing  : { number } = table.create(600, 0)
local _flagHead  : number = 1
local _flagSize  : number = 0

local _anTicks   : number = 0
local _anWindow  : number = os.clock()
local _anHz      : number = 0.0

local _getProfile : ((number) -> any)? = nil
local _getPlayers : (() -> { any })? = nil

local HealthMonitor = {}

function HealthMonitor.init(
	getProfileFn : (number) -> any,
	getPlayersFn : () -> { any }
): ()
	_getProfile = getProfileFn
	_getPlayers = getPlayersFn
end

function HealthMonitor.recordEvent(): ()
	_eventCount += 1
	_epsCount   += 1
end

function HealthMonitor.recordLatency(ms: number): ()
	if type(ms) ~= "number" or ms ~= ms or ms < 0 then return end
	_latRing[_latHead] = ms
	_latHead  = (_latHead % LAT_CAP) + 1
	_latSize  = math.min(_latSize + 1, LAT_CAP)
end

function HealthMonitor.recordFlags(count: number): ()
	_flagRing[_flagHead] = count
	_flagHead = (_flagHead % 600) + 1
	_flagSize = math.min(_flagSize + 1, 600)
end

function HealthMonitor.recordAnalysisTick(): ()
	_anTicks += 1
end

local function percentile(ring: { number }, size: number, pct: number): number
	if size == 0 then return 0.0 end
	local copy : { number } = table.create(size, 0.0)
	for i = 1, size do copy[i] = ring[i] end
	table.sort(copy)
	local idx = math.max(1, math.ceil(pct * size))
	return copy[idx]
end

local PROFILE_KB_EACH : number = 24

function HealthMonitor.snapshot(): HealthSnapshot
	local now : number = os.clock()

	local winDt : number = now - _eventWindow
	if winDt >= 5.0 then
		_eps         = _epsCount / math.max(winDt, 1e-3)
		_epsCount    = 0
		_eventWindow = now
	end

	local anDt : number = now - _anWindow
	if anDt >= 1.0 then
		_anHz     = _anTicks / math.max(anDt, 1e-3)
		_anTicks  = 0
		_anWindow = now
	end

	local p95 : number = percentile(_latRing, _latSize, 0.95)
	local p99 : number = percentile(_latRing, _latSize, 0.99)
	local avg : number = 0.0
	for i = 1, _latSize do avg += _latRing[i] end
	if _latSize > 0 then avg /= _latSize end

	local totalFlags : number = 0
	for i = 1, _flagSize do totalFlags += _flagRing[i] end

	local activePlayers : number = 0
	local highRisk      : number = 0
	local memKB         : number = 0

	if _getPlayers then
		local players = _getPlayers()
		activePlayers = #players
		memKB         = activePlayers * PROFILE_KB_EACH
		if _getProfile then
			for _, p in players do
				local profile = _getProfile(p.UserId)
				if profile and profile.suspicion >= 60 then
					highRisk += 1
				end
			end
		end
	end

	local status : SystemStatus = "OK"
	if avg > 20 or p99 > 100 then
		status = "DEGRADED"
	end
	if avg > 50 or _anHz < 2.0 or p99 > 250 then
		status = "FAIL"
	end

	return {
		status            = status,
		uptimeSeconds     = now - _startTime,
		activePlayers     = activePlayers,
		eventsPerSecond   = _eps,
		analysisHz        = _anHz,
		latencyAvgMs      = avg,
		latencyP95Ms      = p95,
		latencyP99Ms      = p99,
		estimatedMemKB    = memKB,
		totalFlagsLast60s = totalFlags,
		highRiskPlayers   = highRisk,
	}
end

function HealthMonitor.playerMetrics(playerId: number): PlayerMetrics?
	if not _getProfile then return nil end
	local profile = _getProfile(playerId)
	if not profile then return nil end

	local now      : number = os.clock()
	local cutoff   : number = now - 60.0
	local aCount   : number = 0
	local topKinds : { string } = {}

	local cap    : number = 200
	local cursor : number = ((profile.anomalyHead - 2) % cap) + 1
	for _ = 1, profile.anomalySize do
		local rec = profile.anomalies[cursor]
		if rec and rec.t >= cutoff then
			aCount += 1
			if #topKinds < 3 then
				topKinds[#topKinds + 1] = rec.kind
			end
		end
		cursor = ((cursor - 2) % cap) + 1
	end

	local density   : number = math.min(aCount / 10.0, 1.0)
	local riskScore : number = math.min(100, profile.suspicion * 0.7 + density * 100 * 0.3)

	local fps  : number = profile.wFps.mean or 60.0
	local ping : number = 0.0
	if profile.bufSize > 0 then
		local idx = ((profile.bufHead - 2) % 256) + 1
		local s   = profile.buffer[idx]
		if s then ping = s.ping * 1000 end
	end

	return {
		playerId     = playerId,
		suspicion    = math.floor(profile.suspicion),
		riskScore    = math.floor(riskScore),
		anomalyCount = aCount,
		level        = profile.level,
		topAnomalies = topKinds,
		fps          = math.floor(fps),
		ping         = math.floor(ping),
	}
end

HealthMonitor.getHealthSnapshot = HealthMonitor.snapshot
HealthMonitor.getPlayerMetrics  = HealthMonitor.playerMetrics

RunService.Heartbeat:Connect(function(_dt: number)
	HealthMonitor.recordAnalysisTick()
end)

return HealthMonitor
