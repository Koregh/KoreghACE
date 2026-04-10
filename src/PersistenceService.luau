--!strict
--!optimize 2

local DataStoreService = game:GetService("DataStoreService")
local RunService       = game:GetService("RunService")
local Players          = game:GetService("Players")

local Types = require(script.Parent.Shared.Types)


local CFG = {
	-- Name of the internal DataStore.
	-- Swap if you want to isolate between game versions.
	DATASTORE_NAME = "KoreghACE_v1",

	-- Schema version. Increment by changing the shape of SavedProfile.
	-- Data with a different version is ignored (fresh start).
	SCHEMA_VERSION = 1,

	-- Automatically saves every N seconds (0 = off).
	-- Save-on-leave is always executed regardless of this value.
	AUTO_SAVE_SEC = 120,

	-- Decay aplicado à suspicion entre sessões (0..1).
	-- 0.0 = suspicion persists 100% between sessions.
	-- 0.5 = suspicion drops by 50% with each new session.
	-- 1.0 = suspicion reset with each new session.
	INTER_SESSION_DECAY = 0.2,

	-- Maximum AnomalyKind to persist in history.
	MAX_ANOMALY_HISTORY = 10,

	-- Maximum wait time for serverlock (seconds).
	LOCK_TIMEOUT = 30,

	-- Serverlock TTL in seconds. If the server crashes, the
	-- next server ignores the lock after this time.
	LOCK_TTL = 60,
}


--[[
	Complete shape that is saved in the DataStore.
	If you use external DataStore (KoreghProfile, ProfileService,
	etc.), this is the shape you should keep inside your
	profile in the `antiCheat` field.
]]
export type SavedProfile = {
	version      : number,
	suspicion    : number,
	level        : string,       
	totalFlags   : number,       
	topAnomalies : { string },   
	kills        : number,
	deaths       : number,
	headshotKills: number,
	totalShots   : number,
	totalHits    : number,
	lastSeen     : number,      
	_lock        : string?,      
	_lockAt      : number?,      
}

type ExternalGetFn = (pid: Types.PlayerId) -> SavedProfile?
type ExternalSetFn = (pid: Types.PlayerId, data: SavedProfile) -> ()


local _store       : DataStore?                           = nil
local _extGet      : ExternalGetFn?                       = nil
local _extSet      : ExternalSetFn?                       = nil
local _locks       : { [Types.PlayerId]: boolean }        = {}  
local _autoSaveAcc : number                               = 0.0
local _jobId       : string                               = game.JobId

if not RunService:IsStudio() or true then  
	local ok, ds = pcall(function()
		return DataStoreService:GetDataStore(CFG.DATASTORE_NAME)
	end)
	if ok then
		_store = ds :: DataStore
	else
		warn("[PersistenceService] DataStore unavailable — data will not be persisted.")
	end
end


local function dsKey(pid: Types.PlayerId): string
	return "player_" .. tostring(pid)
end

local function now(): number
	return os.time()
end

local function extractSave(profile: Types.PlayerProfile): SavedProfile
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

local function acquireLockAndSave(
	pid      : Types.PlayerId,
	saveData : SavedProfile
): (boolean, string)

	if not _store then return false, "no_datastore" end
	local key = dsKey(pid)
	local success = false
	local reason  = "unknown"

	local ok, err = pcall(function()
		(_store :: DataStore):UpdateAsync(key, function(existing: any)
			local rec : SavedProfile? = existing

			if rec and rec._lock and rec._lock ~= _jobId then
				local lockAge : number = now() - (rec._lockAt or 0)
				if lockAge < CFG.LOCK_TTL then
					reason  = "locked_by_" .. rec._lock:sub(1, 8)
					return nil  -- nil = não atualiza
				end
			end

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
			if rec._lock ~= _jobId then return nil end
			rec._lock  = nil
			rec._lockAt = nil
			return rec
		end)
	end)
end


local PersistenceService = {}

function PersistenceService.setExternalHandlers(
	getFn : ExternalGetFn,
	setFn : ExternalSetFn
): ()
	_extGet = getFn
	_extSet = setFn
end

function PersistenceService.load(
	player   : Player,
	callback : (SavedProfile?) -> ()
): ()
	local pid : Types.PlayerId = player.UserId

	task.spawn(function()
		local saved : SavedProfile? = nil

		if _extGet then
			local ok, result = pcall(_extGet, pid)
			if ok then saved = result end
		elseif _store then
			local ok, result = pcall(function()
				return (_store :: DataStore):GetAsync(dsKey(pid))
			end)
			if ok and result then
				saved = result :: SavedProfile
			end
		end

		if saved and saved.version ~= CFG.SCHEMA_VERSION then
			saved = nil
		end
		if saved then
			saved.suspicion = saved.suspicion * (1.0 - CFG.INTER_SESSION_DECAY)
		end

		callback(saved)
	end)
end


function PersistenceService.save(
	player  : Player,
	profile : Types.PlayerProfile?
): boolean
	if not profile then return false end
	if _locks[player.UserId] then return false end   

	local pid       : Types.PlayerId = player.UserId
	local saveData  : SavedProfile   = extractSave(profile)

	_locks[pid] = true

	local ok : boolean = false

	if _extSet then
		local callOk, err = pcall(_extSet, pid, saveData)
		ok = callOk
		if not callOk then
			warn("[PersistenceService] extSet error:", err)
		end
	elseif _store then
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

PersistenceService.CFG = CFG

Players.PlayerRemoving:Connect(function(player: Player)
	local ok, DataCollector = pcall(function()
		return require(script.Parent.Server.DataCollector)
	end)
	if not ok then return end

	local profile : Types.PlayerProfile? = DataCollector.getProfile(player.UserId)
	if profile then
		PersistenceService.save(player, profile)
	end

	releaseLock(player.UserId)
end)

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
