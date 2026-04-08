--!strict
--!optimize 2



local RunService        = game:GetService("RunService")
local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DataCollector   = require(script.Server.DataCollector)
local AnomalyDetector = require(script.Server.AnomalyDetector)
local DecisionEngine  = require(script.Server.DecisionEngine)
local HitValidator    = require(script.Server.HitValidator)
local Logger          = require(script.Server.Logger)
local CryptoLib       = require(script.Shared.CryptoLib)
local Types           = require(script.Shared.Types)
local MathLib         = require(script.Shared.MathLib)
local InputGuard      = require(script.Security.InputGuard)

local function makeEvent(name: string): RemoteEvent
	local r = Instance.new("RemoteEvent"); r.Name = name; r.Parent = ReplicatedStorage; return r
end
local function makeFunction(name: string): RemoteFunction
	local r = Instance.new("RemoteFunction"); r.Name = name; r.Parent = ReplicatedStorage; return r
end

-- AC_Handshake: client calls this once on join.
--   Server → Client: session key (16 bytes)
--   Client → Server: initial FPS (number)
local HandshakeFunc : RemoteFunction = makeFunction("AC_Handshake")

-- AC_FPS: client fires periodically with current FPS.
-- Payload is a single number — not encrypted (not sensitive).
local FpsEvent      : RemoteEvent    = makeEvent("AC_FPS")

-- Game events (encrypted payloads)
local ActionEvent   : RemoteEvent    = makeEvent("AC_Action")
local StimulusEvent : RemoteEvent    = makeEvent("AC_Stimulus")
local HitEvent      : RemoteEvent    = makeEvent("AC_Hit")

-- Client calls AC_Handshake() → receives the key as a byte array.
-- The client caches it; no further key exchange needed this session.
HandshakeFunc.OnServerInvoke = function(player: Player, clientFps: unknown): { number }
	local pid     : Types.PlayerId       = player.UserId
	local profile : Types.PlayerProfile? = DataCollector.getProfile(pid)
	if not profile then
		DataCollector.register(player)
		profile = DataCollector.getProfile(pid)
	end
	if not profile then return {} end

	-- Accept initial FPS from client
	if type(clientFps) == "number" then
		DataCollector.updateFps(pid, clientFps :: number)
	end

	-- Return the 16-byte session key
	return profile.sessionKey.key
end

FpsEvent.OnServerEvent:Connect(function(player: Player, fps: unknown)
	local ok, err = InputGuard.checkFps(fps)
	if not ok then return end
	DataCollector.updateFps(player.UserId, fps :: number)
end)

-- Returns decoded byte array or nil on failure (tamper / replay).
local function decodePayload(
	player  : Player,
	packet  : unknown
): { number }?
	if type(packet) ~= "table" then return nil end
	local p    = packet :: any
	if type(p.nonce) ~= "number"
		or type(p.cs) ~= "number"
		or type(p.data) ~= "table" then
		return nil
	end
	local pid     : Types.PlayerId       = player.UserId
	local profile : Types.PlayerProfile? = DataCollector.getProfile(pid)
	if not profile then return nil end

	local sk      : Types.SessionKey  = profile.sessionKey
	local decoded : { number }?       = CryptoLib.decode(
		{ nonce = p.nonce, cs = p.cs, data = p.data :: { number } },
		sk.key,
		sk.nonce
	)
	if not decoded then
		-- Tampered or replayed — report and return nil
		local sample : Types.Sample? = DataCollector.getLatestSample(pid)
		if sample then
			AnomalyDetector.reportReplayAttack(profile, sample,
				string.format("nonce=%d last=%d", p.nonce, sk.nonce))
		end
		return nil
	end

	-- Advance nonce to the received value (allows gaps, rejects reversals)
	sk.nonce = p.nonce
	return decoded
end

local _actionCount  : { [Types.PlayerId]: number } = {}
local _actionWindow : { [Types.PlayerId]: number } = {}
local MAX_ACTIONS   : number = 30

local function rateLimited(pid: Types.PlayerId): boolean
	local now : number = os.clock()
	local win : number = _actionWindow[pid] or 0
	local cnt : number = _actionCount[pid]  or 0
	if now - win > 1.0 then
		_actionWindow[pid] = now; _actionCount[pid] = 1; return false
	end
	cnt += 1; _actionCount[pid] = cnt
	return cnt > MAX_ACTIONS
end

-- Wire format (plaintext after decode): { actionId: u8 }
-- Encoded as: [ actionId ]  (1 byte)
ActionEvent.OnServerEvent:Connect(function(player: Player, packet: unknown)
	local pid : Types.PlayerId = player.UserId
	if rateLimited(pid) then return end

	local pok, perr = InputGuard.checkPacket(packet)
	if not pok then return end

	local bytes : { number }? = decodePayload(player, packet)
	if not bytes or #bytes < 1 then return end

	local aid : number = math.clamp(bytes[1], 0, 31)
	DataCollector.recordAction(pid, aid)
end)

-- No payload needed — just signal arrival is sufficient.
-- Still encrypted to prevent forged timings.
StimulusEvent.OnServerEvent:Connect(function(player: Player, packet: unknown)
	local sok, serr = InputGuard.checkPacket(packet)
	if not sok then return end

	local bytes : { number }? = decodePayload(player, packet)
	if not bytes then return end
	DataCollector.recordStimulus(player.UserId)
end)

-- Wire format (plaintext after decode, little-endian):
--   bytes 1-4  : victimId  (u32)
--   bytes 5-8  : posX      (f32 approximated as 4 bytes via pack)
--   bytes 9-12 : posY
--   bytes 13-16: posZ
--   bytes 17-20: weaponRange (u16 in studs, packed as u32 for simplicity)
--   bytes 21-24: damage     (u16 packed as u32)
--   byte  25   : flags      (bit0 = isHeadshot)
--
-- NOTE: For positions we use integer studs (1 stud precision) to
-- keep byte count low. Upgrade to f32 packing if sub-stud precision
-- is needed for your game.
HitEvent.OnServerEvent:Connect(function(attacker: Player, packet: unknown)
	local attackerPid : Types.PlayerId = attacker.UserId

	local hok, herr = InputGuard.checkPacket(packet)
	if not hok then return end

	local bytes : { number }? = decodePayload(attacker, packet)
	if not bytes or #bytes < 25 then return end

	local victimId   : number  = CryptoLib.unpackU32(bytes, 1)
	local posX       : number  = CryptoLib.unpackU32(bytes, 5)  - 32768  -- offset encode
	local posY       : number  = CryptoLib.unpackU32(bytes, 9)  - 32768
	local posZ       : number  = CryptoLib.unpackU32(bytes, 13) - 32768
	local wRange     : number  = CryptoLib.unpackU32(bytes, 17)
	local damage     : number  = CryptoLib.unpackU32(bytes, 21)
	local flags      : number  = bytes[25]
	local isHeadshot : boolean = bit32.band(flags, 1) == 1

	local clientPos  : Vector3 = Vector3.new(posX, posY, posZ)

	local attackerProfile : Types.PlayerProfile? = DataCollector.getProfile(attackerPid)
	local victimProfile   : Types.PlayerProfile? = DataCollector.getProfile(victimId)
	if not attackerProfile or not victimProfile then return end

	local req : Types.HitRequest = {
		victimId    = victimId,
		clientPos   = clientPos,
		weaponRange = math.clamp(wRange, 0, 500),
		damage      = math.clamp(damage, 0, 1000),
		isHeadshot  = isHeadshot,
	}

	local result : Types.HitResult = HitValidator.validate(attackerProfile, req, victimProfile)

	if not result.valid then
		local sample : Types.Sample? = DataCollector.getLatestSample(attackerPid)
		if sample and result.rejectCode then
			AnomalyDetector.reportInvalidHit(attackerProfile, result.rejectCode, sample)
		end
		return
	end

	local victim : Player? = Players:GetPlayerByUserId(victimId)
	if victim then
		local char = victim.Character
		local hum  = char and char:FindFirstChildOfClass("Humanoid")
		if hum then hum:TakeDamage(req.damage) end
	end

	DataCollector.recordShot(attackerPid, true)
end)

local ANALYSIS_DT : number = 1 / 5
local _anAcc      : number = 0.0
local _lastT      : { [Types.PlayerId]: number } = {}
-- Per-player last weapon name (set by game code via setPlayerWeapon)
local _playerWeapon : { [Types.PlayerId]: string? } = {}

RunService.Heartbeat:Connect(function(dt: number)
	_anAcc += dt
	if _anAcc < ANALYSIS_DT then return end
	_anAcc -= ANALYSIS_DT

	for _, player in Players:GetPlayers() do
		local pid     : Types.PlayerId       = player.UserId
		local profile : Types.PlayerProfile? = DataCollector.getProfile(pid)
		local sample  : Types.Sample?        = DataCollector.getLatestSample(pid)
		if not profile or not sample then continue end

		local now      : number = os.clock()
		local playerDt : number = now - (_lastT[pid] or now)
		_lastT[pid] = now

		local bufPrev  : number        = ((profile.bufHead - 3) % 256) + 1
		local prevSamp : Types.Sample  = profile.buffer[bufPrev]

		local delta    = AnomalyDetector.analyse(
			profile, sample, prevSamp, playerDt, _playerWeapon[pid]
		)
		local decision = DecisionEngine.evaluate(profile, player)

		local latest = AnomalyDetector.latestAnomaly(profile)
		if decision.action ~= "NONE" or latest then
			Logger.logDecision(player, decision, latest)
		end
	end
end)


local AntiCheatService = {}

function AntiCheatService.isShadowBanned(player: Player): boolean
	return player:HasTag("__AC_SB")
end

function AntiCheatService.getSuspicion(player: Player): number
	local p = DataCollector.getProfile(player.UserId)
	return p and p.suspicion or 0.0
end

function AntiCheatService.reportShot(player: Player, hit: boolean): ()
	DataCollector.recordShot(player.UserId, hit)
end

function AntiCheatService.reportAccuracy(player: Player, acc: number): ()
	DataCollector.updateAccuracy(player.UserId, math.clamp(acc, 0, 1))
end

function AntiCheatService.reportKill(
	player      : Player,
	isHeadshot  : boolean,
	killTimeSec : number?,
	killDistSt  : number?
): ()
	DataCollector.recordKill(player.UserId, isHeadshot, killTimeSec, killDistSt)
end

function AntiCheatService.reportDeath(player: Player): ()
	DataCollector.recordDeath(player.UserId)
end

-- Call this BEFORE applying the force so the detector has time
-- to see the whitelist entry.
-- duration : seconds the leniency lasts (usually 0.5–2.0)
-- maxSpeed : studs/s override (e.g. 200 for a rocket jump)
function AntiCheatService.registerPhysicsEvent(
	player   : Player,
	duration : number,
	maxSpeed : number
): ()
	DataCollector.registerPhysicsEvent(player.UserId, duration, maxSpeed)
end

-- ── v3: set current weapon for recoil detection ───────────────
function AntiCheatService.setPlayerWeapon(player: Player, weaponName: string?): ()
	_playerWeapon[player.UserId] = weaponName
end

-- ── v3: register a recoil pattern for a weapon ───────────────
function AntiCheatService.setRecoilPattern(weaponName: string, pattern: { number }): ()
	AnomalyDetector.setRecoilPattern(weaponName, pattern)
end

function AntiCheatService.validateHit(
	attacker : Player,
	victimId : Types.PlayerId,
	clientPos: Vector3,
	range    : number,
	damage   : number,
	headshot : boolean
): boolean
	local ap = DataCollector.getProfile(attacker.UserId)
	local vp = DataCollector.getProfile(victimId)
	if not ap or not vp then return false end
	local req : Types.HitRequest = {
		victimId = victimId, clientPos = clientPos,
		weaponRange = range, damage = damage, isHeadshot = headshot,
	}
	local res = HitValidator.validate(ap, req, vp)
	if not res.valid then
		local s = DataCollector.getLatestSample(attacker.UserId)
		if s and res.rejectCode then
			AnomalyDetector.reportInvalidHit(ap, res.rejectCode, s)
		end
	end
	return res.valid
end

function AntiCheatService.addHitIgnore(instance: Instance): ()
	HitValidator.addIgnore(instance)
end

function AntiCheatService.dumpSessionStats(player: Player): Types.SessionStats?
	local p = DataCollector.getProfile(player.UserId)
	return p and p.session or nil
end

function AntiCheatService.patchConfig(patch: { [string]: number | boolean }): ()
	local cfg = AnomalyDetector.CFG
	for k, v in patch do
		if cfg[k] ~= nil then (cfg :: any)[k] = v end
	end
end

function AntiCheatService.getPlayerLogs(player: Player, limit: number)
	return Logger.getPlayerLogs(player.UserId, limit)
end

return AntiCheatService
