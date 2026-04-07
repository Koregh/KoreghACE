--!strict
--!optimize 2
--!native

-- ============================================================
--  DataCollector.luau  v3.0
--  Collects all raw telemetry. Zero allocation in hot path.
--
--  v3 changes:
--    • Sample now includes fps field
--    • CPS window uses a ring buffer (no table.move / O(n) shift)
--    • CFrameTracker builds individual baseline (first BASELINE_N)
--    • wFps Welford tracks player fps
--    • PhysicsEvent whitelist API added
--    • SessionKey initialised per profile
--    • Anomaly list replaced with fixed-size ring in profile
-- ============================================================

local RunService = game:GetService("RunService")
local Players    = game:GetService("Players")

local Types     = require(script.Parent.Parent.Shared.Types)
local MathLib   = require(script.Parent.Parent.Shared.MathLib)
local CryptoLib = require(script.Parent.Parent.Shared.CryptoLib)

-- ── Config ───────────────────────────────────────────────────
local SAMPLE_CAP   : number = 256    -- power-of-two
local IET_CAP      : number = 64
local CF_CAP       : number = 32
local TICK_HZ      : number = 20
local TICK_DT      : number = 1 / TICK_HZ
local HIT_WIN_SEC  : number = 1.0
local ANOMALY_CAP  : number = 200    -- ring size for anomaly records
local CF_BASELINE_N: number = 60     -- samples to build CFrame baseline

-- CPS ring: track clicks in last 1 s using a fixed-size ring.
-- Head points to oldest slot; we count how many are within window.
local CPS_CAP : number = 64          -- max physically possible in 1 s

-- ── State ────────────────────────────────────────────────────
local _profiles  : { [Types.PlayerId]: Types.PlayerProfile } = {}
-- Per-player CPS ring: { times, head, size }
local _cpsRings  : { [Types.PlayerId]: { times: { number }, head: number, size: number } } = {}
local _stimulusT : { [Types.PlayerId]: number }              = {}
local _lastReact : { [Types.PlayerId]: number }              = {}

-- ── Sentinel / zero values ────────────────────────────────────
local ZERO_CF   : CFrame  = CFrame.identity
local ZERO_V3   : Vector3 = Vector3.zero

-- ── Welford factory ──────────────────────────────────────────
local function newWelford(): Types.Welford
	return { n = 0, mean = 0.0, M2 = 0.0 }
end

-- ── IET factory ──────────────────────────────────────────────
local function newIET(): Types.IETTracker
	return {
		intervals = table.create(IET_CAP, 0.0),
		head      = 1,
		lastTime  = 0.0,
		wIET      = newWelford(),
	}
end

-- ── CFrame tracker factory ────────────────────────────────────
local function newCFTracker(): Types.CFrameTracker
	return {
		samples       = table.create(CF_CAP, ZERO_CF),
		head          = 1,
		angularDeltas = table.create(CF_CAP, 0.0),
		wDelta        = newWelford(),
		wDeltaBase    = newWelford(),
		baselineReady = false,
	}
end

-- ── Session factory ───────────────────────────────────────────
local function newSession(): Types.SessionStats
	return {
		kills         = 0,
		deaths        = 0,
		headshotKills = 0,
		totalShots    = 0,
		totalHits     = 0,
		killTimings   = table.create(32, 0.0),
		avgKillDist   = 0.0,
		sessionStart  = os.clock(),
	}
end

-- ── Profile factory ───────────────────────────────────────────
local function newProfile(pid: Types.PlayerId, player: Player): Types.PlayerProfile
	local buf : { Types.Sample } = table.create(SAMPLE_CAP)
	local sentinel : Types.Sample = {
		t = 0, pos = ZERO_V3, vel = ZERO_V3, cf = ZERO_CF,
		reactionMs = 0, cps = 0, accuracy = 0, actionId = 0,
		ping = 0, fps = 60,
	}
	for i = 1, SAMPLE_CAP do buf[i] = sentinel end

	-- Pre-fill anomaly ring
	local emptyAnomaly : Types.AnomalyRecord = {
		kind = "Z_SCORE_SPIKE", severity = 0, t = 0,
		raw  = sentinel,
	}
	local anomRing : { Types.AnomalyRecord } = table.create(ANOMALY_CAP)
	for i = 1, ANOMALY_CAP do anomRing[i] = emptyAnomaly end

	return {
		playerId    = pid,
		accountAge  = player.AccountAge,

		wReaction   = newWelford(),
		wCps        = newWelford(),
		wAccuracy   = newWelford(),
		wSpeed      = newWelford(),
		wFps        = newWelford(),

		iet         = newIET(),
		cfTracker   = newCFTracker(),

		markov      = { matrix = {}, stateCounts = {}, totalEdges = 0 },
		lastAction  = 0,
		lastActionT = 0.0,

		session     = newSession(),

		suspicion   = 0.0,
		level       = "CLEAN",
		anomalies   = anomRing,
		anomalyHead = 1,
		anomalySize = 0,

		buffer      = buf,
		bufHead     = 1,
		bufSize     = 0,

		hitCount    = 0,
		hitWindow   = 0.0,

		lastServerPos = ZERO_V3,
		lastPosTime   = 0.0,

		physicsEvents = {},
		sessionKey    = {
			key   = CryptoLib.generateKey(),
			nonce = 0,
		},
	}
end

-- ── CPS ring (O(1) push, O(count) query — count ≤ CPS_CAP) ───
local function newCpsRing(): { times: { number }, head: number, size: number }
	return { times = table.create(CPS_CAP, 0.0), head = 1, size = 0 }
end

local function cpsRingPush(ring: { times: { number }, head: number, size: number }, t: number): ()
	ring.times[ring.head] = t
	ring.head  = (ring.head % CPS_CAP) + 1
	ring.size  = math.min(ring.size + 1, CPS_CAP)
end

-- Count clicks within the last 1 s — O(CPS_CAP) = O(64)
local function cpsCount(ring: { times: { number }, head: number, size: number }, now: number): number
	local cutoff : number = now - 1.0
	local times  : { number } = ring.times
	local count  : number = 0
	-- Walk backwards from most-recent
	local cur : number = ((ring.head - 2) % CPS_CAP) + 1
	for _ = 1, ring.size do
		if times[cur] >= cutoff then
			count += 1
		else
			-- Older entries are all expired (ring is insertion-ordered)
			break
		end
		cur = ((cur - 2) % CPS_CAP) + 1
	end
	return count
end

-- ── IET push (inline, no alloc) ──────────────────────────────
local function pushIET(iet: Types.IETTracker, now: number): ()
	local last : number = iet.lastTime
	if last <= 0.0 then iet.lastTime = now; return end
	local deltaMs : number = (now - last) * 1000.0
	iet.lastTime = now
	iet.intervals[iet.head] = deltaMs
	iet.head = (iet.head % IET_CAP) + 1
	local w : Types.Welford = iet.wIET
	w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, deltaMs)
end

-- ── CFrame tracker push ───────────────────────────────────────
local function pushCFrame(cft: Types.CFrameTracker, cf: CFrame, dt: number): ()
	local prev : CFrame = cft.samples[(((cft.head - 2) % CF_CAP) + 1)]
	local angV : number = MathLib.angularVelocity(prev, cf, dt)

	cft.samples[cft.head]       = cf
	cft.angularDeltas[cft.head] = angV
	cft.head = (cft.head % CF_CAP) + 1

	-- Running stats (all time)
	local w : Types.Welford = cft.wDelta
	w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, angV)

	-- Individual baseline: first CF_BASELINE_N samples only
	if not cft.baselineReady then
		local wb : Types.Welford = cft.wDeltaBase
		wb.n, wb.mean, wb.M2 = MathLib.welfordPush(wb.n, wb.mean, wb.M2, angV)
		if wb.n >= CF_BASELINE_N then
			cft.baselineReady = true
		end
	end
end

-- ── Main sample tick ──────────────────────────────────────────
local _acc     : number = 0.0

local function samplePlayer(pid: Types.PlayerId, player: Player, dt: number): ()
	local profile : Types.PlayerProfile? = _profiles[pid]
	if not profile then return end

	local char : Model? = player.Character
	if not char then return end
	local hrp : BasePart? = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then return end

	local now  : number  = os.clock()
	local ring              = _cpsRings[pid]
	local cps  : number  = if ring then cpsCount(ring, now) else 0.0
	local reac : number  = _lastReact[pid] or 0.0
	local ping : number  = player:GetNetworkPing()

	-- FPS: Roblox exposes workspace:GetRealPhysicsFPS() server-side
	-- but it reflects server fps. Client fps must be sent by client
	-- via the secure handshake or the AC_FPS remote. We fall back
	-- to 60 if not yet received to avoid false positives.
	local fps  : number  = (profile.wFps.n > 0 and profile.wFps.mean) or 60.0

	local sample : Types.Sample = {
		t          = now,
		pos        = hrp.Position,
		vel        = hrp.AssemblyLinearVelocity,
		cf         = hrp.CFrame,
		reactionMs = reac,
		cps        = cps,
		accuracy   = 0.0,
		actionId   = profile.lastAction,
		ping       = ping,
		fps        = fps,
	}

	-- Ring write
	local head : number = profile.bufHead
	profile.buffer[head] = sample
	profile.bufHead = (head % SAMPLE_CAP) + 1
	profile.bufSize = math.min(profile.bufSize + 1, SAMPLE_CAP)

	profile.lastServerPos = hrp.Position
	profile.lastPosTime   = now

	pushCFrame(profile.cfTracker, hrp.CFrame, dt)

	-- Welford updates
	local spd : number = MathLib.speed(hrp.AssemblyLinearVelocity)
	do local w = profile.wSpeed;    w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, spd)    end
	do local w = profile.wReaction; w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, reac)   end
	do local w = profile.wCps;      w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, cps)    end
	do local w = profile.wFps;      w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, fps)    end

	-- Purge expired physics events
	MathLib.purgeExpiredPhysics(profile.physicsEvents, now)
end

RunService.Heartbeat:Connect(function(dt: number)
	_acc += dt
	if _acc < TICK_DT then return end
	_acc -= TICK_DT
	for _, player in Players:GetPlayers() do
		samplePlayer(player.UserId, player, dt)
	end
end)

-- ── Public API ────────────────────────────────────────────────

local DataCollector = {}

function DataCollector.register(player: Player): ()
	local pid : Types.PlayerId = player.UserId
	if _profiles[pid] then return end
	_profiles[pid]  = newProfile(pid, player)
	_cpsRings[pid]  = newCpsRing()
	_stimulusT[pid] = 0.0
	_lastReact[pid] = 0.0
end

function DataCollector.unregister(pid: Types.PlayerId): ()
	_profiles[pid]  = nil :: any
	_cpsRings[pid]  = nil :: any
	_stimulusT[pid] = nil :: any
	_lastReact[pid] = nil :: any
end

function DataCollector.recordAction(pid: Types.PlayerId, actionId: number): ()
	local now  : number = os.clock()
	local ring           = _cpsRings[pid]
	if ring then cpsRingPush(ring, now) end

	local stim : number = _stimulusT[pid] or 0.0
	if stim > 0.0 then
		_lastReact[pid] = (now - stim) * 1000.0
		_stimulusT[pid] = 0.0
	end

	local profile : Types.PlayerProfile? = _profiles[pid]
	if not profile then return end

	pushIET(profile.iet, now)

	local from   : number = profile.lastAction
	local markov : Types.MarkovModel = profile.markov
	local row    : { [number]: number }? = markov.matrix[from]
	if not row then row = {}; markov.matrix[from] = row end
	row[actionId] = (row[actionId] or 0) + 1
	markov.stateCounts[from] = (markov.stateCounts[from] or 0) + 1
	markov.totalEdges += 1
	profile.lastAction  = actionId
	profile.lastActionT = now
end

function DataCollector.recordStimulus(pid: Types.PlayerId): ()
	_stimulusT[pid] = os.clock()
end

function DataCollector.updateAccuracy(pid: Types.PlayerId, accuracy: number, weight: number?): ()
	local profile : Types.PlayerProfile? = _profiles[pid]
	if not profile then return end
	local w   : Types.Welford = profile.wAccuracy
	local wgt : number = weight or 1
	for _ = 1, wgt do
		w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, accuracy)
	end
end

function DataCollector.recordKill(pid: Types.PlayerId, isHeadshot: boolean, killTime: number?, killDist: number?): ()
	local profile : Types.PlayerProfile? = _profiles[pid]
	if not profile then return end
	local s : Types.SessionStats = profile.session
	s.kills += 1
	if isHeadshot then s.headshotKills += 1 end
	if killTime then
		local idx : number = ((s.kills - 1) % 32) + 1
		s.killTimings[idx] = killTime
	end
	if killDist then
		s.avgKillDist = s.avgKillDist + (killDist - s.avgKillDist) / s.kills
	end
end

function DataCollector.recordDeath(pid: Types.PlayerId): ()
	local profile : Types.PlayerProfile? = _profiles[pid]
	if profile then profile.session.deaths += 1 end
end

function DataCollector.recordShot(pid: Types.PlayerId, hit: boolean): ()
	local profile : Types.PlayerProfile? = _profiles[pid]
	if not profile then return end
	local s : Types.SessionStats = profile.session
	s.totalShots += 1
	if hit then s.totalHits += 1 end
end

-- ── v3: client fps update (called from AntiCheatService on handshake) ──
function DataCollector.updateFps(pid: Types.PlayerId, fps: number): ()
	local profile : Types.PlayerProfile? = _profiles[pid]
	if not profile then return end
	-- Clamp to sane range: 5–240
	local safeFps : number = math.clamp(fps, 5.0, 240.0)
	local w : Types.Welford = profile.wFps
	w.n, w.mean, w.M2 = MathLib.welfordPush(w.n, w.mean, w.M2, safeFps)
end

-- ── v3: register a legitimate physics event ──────────────────
-- Call from your explosion / dash / knockback code BEFORE the
-- force is applied so the detector does not flag the frame.
-- duration   : seconds the leniency should last
-- maxSpeed   : studs/s override during this window
function DataCollector.registerPhysicsEvent(
	pid      : Types.PlayerId,
	duration : number,
	maxSpeed : number
): ()
	local profile : Types.PlayerProfile? = _profiles[pid]
	if not profile then return end
	profile.physicsEvents[#profile.physicsEvents + 1] = {
		expiresAt     = os.clock() + duration,
		maxSpeedStuds = maxSpeed,
	}
end

function DataCollector.getProfile(pid: Types.PlayerId): Types.PlayerProfile?
	return _profiles[pid]
end

function DataCollector.getLatestSample(pid: Types.PlayerId): Types.Sample?
	local p : Types.PlayerProfile? = _profiles[pid]
	if not p or p.bufSize == 0 then return nil end
	local idx : number = ((p.bufHead - 2) % SAMPLE_CAP) + 1
	return p.buffer[idx]
end

-- ── Auto register / unregister ────────────────────────────────
Players.PlayerAdded:Connect(function(p: Player) DataCollector.register(p) end)
Players.PlayerRemoving:Connect(function(p: Player) DataCollector.unregister(p.UserId) end)
for _, p in Players:GetPlayers() do DataCollector.register(p) end

return DataCollector
