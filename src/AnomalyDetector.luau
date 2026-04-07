--!strict
--!optimize 2
--!native


local Types            = require(script.Parent.Parent.Shared.Types)
local MathLib          = require(script.Parent.Parent.Shared.MathLib)
local StatsEngine      = require(script.Parent.StatsEngine)
local PopulationConfig = require(script.Parent.Parent.Shared.PopulationConfig)

local CFG = {
	Z_REACTION   = 3.5,
	Z_CPS        = 3.5,
	Z_ACCURACY   = 3.0,
	Z_SPEED      = 4.0,
	Z_IET        = 3.0,
	Z_CFRAME     = 3.5,   -- v3: used for individual-baseline z-score

	-- Absolute human limits
	MIN_REACTION_MS  = 70,     -- below AND below fps floor = superhuman
	MAX_CPS          = 16,
	ACCURACY_CEIL    = 0.97,
	MAX_SPEED_STUDS  = 50,

	-- IET
	IET_CV_FLOOR     = 0.05,
	IET_MIN_SAMPLES  = 20,

	-- CFrame — v3: global snap still used as an upper bound,
	-- but individual z-score is the primary signal.
	CFRAME_SNAP_RADPS  = 25.0,  -- raised from 18 — only for obvious snaps
	CFRAME_MECH_CV     = 0.08,
	CFRAME_MIN_N       = 15,
	CFRAME_BASELINE_N  = 60,    -- samples before individual z is active

	-- Teleport
	TELEPORT_MAX_STUDS_PER_SEC = 80,
	TELEPORT_MIN_SAMPLES       = 5,

	-- Recoil correlation — now active
	RECOIL_PEARSON_THRESHOLD = 0.96,
	RECOIL_MIN_SAMPLES       = 20,

	-- Session headshot
	SESSION_HS_RATE_CEIL = 0.75,
	SESSION_HS_MIN_KILLS = 20,

	-- Account integrity
	ACCOUNT_AGE_DAYS = 30,
	SMURF_ACCURACY   = 0.70,

	-- Markov
	MARKOV_RARE_PROB     = 0.01,
	MARKOV_ENTROPY_LOW   = 0.15,
	MARKOV_MIN_EDGES     = 50,
	VOCAB_SIZE           = 32,

	-- Suspicion dynamics
	DELTA_SCALE = 8.0,
	HALF_LIFE   = 60.0,

	-- Weights
	W_REACTION   = 0.12,
	W_CPS        = 0.14,
	W_ACCURACY   = 0.12,
	W_SPEED      = 0.10,
	W_IET        = 0.12,
	W_CFRAME     = 0.10,
	W_MARKOV     = 0.08,
	W_TELEPORT   = 0.10,
	W_POPULATION = 0.05,
	W_SESSION    = 0.03,
	W_ACCOUNT    = 0.02,
	W_RECOIL     = 0.02,
}

local ANOMALY_CAP : number = 200   -- must match DataCollector

local AnomalyDetector = {}

local function push(
	profile  : Types.PlayerProfile,
	kind     : Types.AnomalyKind,
	severity : number,
	sample   : Types.Sample,
	extra    : string?,
	z        : number?,
	tp       : number?
): ()
	local rec : Types.AnomalyRecord = {
		kind      = kind,
		severity  = severity,
		zScore    = z,
		transProb = tp,
		extra     = extra,
		t         = sample.t,
		raw       = sample,
	}
	profile.anomalies[profile.anomalyHead] = rec
	profile.anomalyHead = (profile.anomalyHead % ANOMALY_CAP) + 1
	profile.anomalySize = math.min(profile.anomalySize + 1, ANOMALY_CAP)
end

@inline
local function zSev(z: number, threshold: number): number
	local absZ : number = math.abs(z)
	if absZ < threshold then return 0.0 end
	return MathLib.clamp01((absZ - threshold) / 6.0)
end

-- This prevents flagging players whose frame time alone explains
-- a reaction above the 70ms absolute constant.
local function dReaction(p: Types.PlayerProfile, s: Types.Sample, z: number): number
	local r : number = s.reactionMs
	if r <= 0 then return 0.0 end

	-- Dynamic floor: 2 frames at the player's FPS
	local fpsFloor : number = MathLib.reactionFpsFloor(s.fps)
	local floor    : number = math.max(CFG.MIN_REACTION_MS, fpsFloor)

	if r < floor then
		local sev : number = MathLib.clamp01(1.0 - r / floor)
		push(p, "REACTION_SUPERHUMAN", sev, s,
			string.format("%.0f ms (floor %.0f ms, fps=%.0f)", r, floor, s.fps))
		return sev * CFG.W_REACTION
	end
	local sev : number = zSev(z, CFG.Z_REACTION)
	if sev > 0 then push(p, "Z_SCORE_SPIKE", sev, s, "reaction", z) end
	return sev * CFG.W_REACTION
end

local function dCPS(p: Types.PlayerProfile, s: Types.Sample, z: number): number
	if s.cps > CFG.MAX_CPS then
		local sev : number = MathLib.clamp01((s.cps - CFG.MAX_CPS) / CFG.MAX_CPS)
		push(p, "CPS_MECHANICAL", sev, s,
			string.format("%.1f cps (max %.0f)", s.cps, CFG.MAX_CPS))
		return sev * CFG.W_CPS
	end
	local sev : number = zSev(z, CFG.Z_CPS)
	if sev > 0 then push(p, "Z_SCORE_SPIKE", sev, s, "cps", z) end
	return sev * CFG.W_CPS
end

local function dAccuracy(p: Types.PlayerProfile, s: Types.Sample, z: number): number
	if s.accuracy >= CFG.ACCURACY_CEIL and p.wAccuracy.n >= 30 then
		local sev : number = MathLib.clamp01(
			(s.accuracy - CFG.ACCURACY_CEIL) / (1 - CFG.ACCURACY_CEIL)
		)
		push(p, "ACCURACY_CEILING", sev, s,
			string.format("%.1f%% sustained", s.accuracy * 100))
		return sev * CFG.W_ACCURACY
	end
	local sev : number = zSev(z, CFG.Z_ACCURACY)
	if sev > 0 then push(p, "Z_SCORE_SPIKE", sev, s, "accuracy", z) end
	return sev * CFG.W_ACCURACY
end

local function dSpeed(p: Types.PlayerProfile, s: Types.Sample, z: number): number
	local spd : number = MathLib.speed(s.vel)

	-- Physics-event override + fps scaling
	local now      : number = s.t
	local physMax  : number = MathLib.activePhysicsMax(
		p.physicsEvents, CFG.MAX_SPEED_STUDS, now
	)
	-- At low fps, physics steps are larger — scale the threshold up
	local scaledMax : number = physMax * MathLib.fpsScaleFactor(s.fps)

	if spd > scaledMax then
		local sev : number = MathLib.clamp01((spd - scaledMax) / scaledMax)
		push(p, "VELOCITY_IMPOSSIBLE", sev, s,
			string.format("%.1f studs/s (max %.1f, fps=%.0f)", spd, scaledMax, s.fps))
		return sev * CFG.W_SPEED
	end
	local sev : number = zSev(z, CFG.Z_SPEED)
	if sev > 0 then push(p, "Z_SCORE_SPIKE", sev, s, "speed", z) end
	return sev * CFG.W_SPEED
end

local function dIET(p: Types.PlayerProfile, s: Types.Sample): number
	local w : Types.Welford = p.iet.wIET
	if w.n < CFG.IET_MIN_SAMPLES then return 0.0 end
	local stddev : number = MathLib.welfordStddev(w.n, w.M2)
	local cv     : number = MathLib.cv(w.mean, stddev)
	if cv < CFG.IET_CV_FLOOR then
		local sev : number = MathLib.clamp01(1.0 - cv / CFG.IET_CV_FLOOR)
		push(p, "IET_DETERMINISTIC", sev, s,
			string.format("CV=%.4f (floor=%.2f)", cv, CFG.IET_CV_FLOOR))
		return sev * CFG.W_IET
	end
	return 0.0
end

-- This normalises for mouse sensitivity and DPI.
-- Global snap threshold kept as a hard upper bound only.
local function dCFrame(p: Types.PlayerProfile, s: Types.Sample): number
	local cft : Types.CFrameTracker = p.cfTracker
	local w   : Types.Welford       = cft.wDelta
	if w.n < CFG.CFRAME_MIN_N then return 0.0 end

	-- Latest angular velocity
	local latest : number = cft.angularDeltas[
		((cft.head - 2) % #cft.angularDeltas) + 1
	]

	-- Hard cap: global snap (no sensitivity can explain this)
	if latest > CFG.CFRAME_SNAP_RADPS then
		local sev : number = MathLib.clamp01(
			(latest - CFG.CFRAME_SNAP_RADPS) / CFG.CFRAME_SNAP_RADPS
		)
		push(p, "CFRAME_MECHANICAL", sev, s,
			string.format("hard snap %.2f rad/s (cap %.0f)", latest, CFG.CFRAME_SNAP_RADPS))
		return sev * CFG.W_CFRAME
	end

	if cft.baselineReady then
		local wb   : Types.Welford = cft.wDeltaBase
		local zAng : number = MathLib.sensitivityZ(latest, wb.mean, wb.M2, wb.n)
		local sev  : number = zSev(zAng, CFG.Z_CFRAME)
		if sev > 0 then
			push(p, "CFRAME_MECHANICAL", sev, s,
				string.format("z=%.2f vs own baseline (mean=%.3f rad/s)", zAng, wb.mean))
			return sev * CFG.W_CFRAME
		end
	else
		-- Fallback to global CV check while baseline builds
		local stddev : number = MathLib.welfordStddev(w.n, w.M2)
		local cv     : number = MathLib.cv(w.mean, stddev)
		if cv < CFG.CFRAME_MECH_CV and w.mean > 0.1 then
			local sev : number = MathLib.clamp01(1.0 - cv / CFG.CFRAME_MECH_CV)
			push(p, "CFRAME_MECHANICAL", sev, s,
				string.format("smooth CV=%.4f (baseline building %d/%d)",
					cv, cft.wDeltaBase.n, CFG.CFRAME_BASELINE_N))
			return sev * CFG.W_CFRAME
		end
	end

	return 0.0
end

local function dTeleport(p: Types.PlayerProfile, s: Types.Sample, prev: Types.Sample): number
	if p.bufSize < CFG.TELEPORT_MIN_SAMPLES then return 0.0 end
	local dt : number = s.t - prev.t
	if dt < 0.01 then return 0.0 end

	local displacement : number = (s.pos - prev.pos).Magnitude

	local now      : number = s.t
	local physMax  : number = MathLib.activePhysicsMax(
		p.physicsEvents, CFG.TELEPORT_MAX_STUDS_PER_SEC, now
	)
	-- Scale max displacement by fps factor (large dt at low fps = big step)
	local scaledMax : number = physMax * MathLib.fpsScaleFactor(s.fps)
	local maxDisp   : number = scaledMax * dt
		+ MathLib.positionThreshold(MathLib.speed(prev.vel), s.ping, 3.0)

	if displacement > maxDisp then
		local sev : number = MathLib.clamp01((displacement - maxDisp) / maxDisp)
		push(p, "TELEPORT", sev, s,
			string.format("Δ=%.1f studs, max=%.1f, fps=%.0f", displacement, maxDisp, s.fps))
		return sev * CFG.W_TELEPORT
	end
	return 0.0
end

local function dMarkov(p: Types.PlayerProfile, s: Types.Sample, prevAction: number): number
	if p.markov.totalEdges < CFG.MARKOV_MIN_EDGES then return 0.0 end
	local prob : number = MathLib.markovProbSmoothed(
		p.markov.matrix, p.markov.stateCounts,
		prevAction, s.actionId,
		1, CFG.VOCAB_SIZE
	)
	if prob < CFG.MARKOV_RARE_PROB then
		local sev : number = MathLib.clamp01(1.0 - prob / CFG.MARKOV_RARE_PROB)
		push(p, "MARKOV_RARE_SEQ", sev, s, string.format("P=%.4f", prob), nil, prob)
		return sev * CFG.W_MARKOV
	end
	local row    : { [number]: number }? = p.markov.matrix[prevAction]
	local rowSum : number = p.markov.stateCounts[prevAction] or 0
	if row and rowSum > 0 then
		local entropy : number = MathLib.entropyNorm(row, rowSum, CFG.VOCAB_SIZE)
		if entropy < CFG.MARKOV_ENTROPY_LOW then
			local sev : number = MathLib.clamp01(
				1.0 - entropy / CFG.MARKOV_ENTROPY_LOW
			) * 0.5
			push(p, "MARKOV_RARE_SEQ", sev, s,
				string.format("entropy=%.4f (low)", entropy))
			return sev * CFG.W_MARKOV
		end
	end
	return 0.0
end

local function dPopulation(p: Types.PlayerProfile, s: Types.Sample): number
	local tier : Types.PopulationTier? = PopulationConfig.getTier(p.session.kills)
	if not tier then return 0.0 end
	local rFast : number = PopulationConfig.outlierSeverity(
		tier.reaction.p50 - s.reactionMs, 0,
		tier.reaction.p50 - tier.reaction.p50 * 0.3
	)
	local cSev  : number = PopulationConfig.outlierSeverity(s.cps, tier.cps.p50, tier.cps.p95)
	local sessionAcc : number = if p.session.totalShots > 0
		then p.session.totalHits / p.session.totalShots
		else 0.0
	local aSev  : number = PopulationConfig.outlierSeverity(sessionAcc, tier.accuracy.p50, tier.accuracy.p95)
	local maxSev : number = math.max(rFast, cSev, aSev)
	if maxSev > 0 then
		push(p, "POPULATION_OUTLIER", maxSev, s, string.format("tier=%s", tier.label))
	end
	return maxSev * CFG.W_POPULATION
end

local function dSession(p: Types.PlayerProfile, s: Types.Sample): number
	local sess : Types.SessionStats = p.session
	if sess.kills < CFG.SESSION_HS_MIN_KILLS then return 0.0 end
	local hsRate : number = sess.headshotKills / sess.kills
	if hsRate > CFG.SESSION_HS_RATE_CEIL then
		local sev : number = MathLib.clamp01(
			(hsRate - CFG.SESSION_HS_RATE_CEIL) / (1 - CFG.SESSION_HS_RATE_CEIL)
		)
		push(p, "SESSION_HEADSHOT_RATE", sev, s,
			string.format("HS=%.1f%% over %d kills", hsRate * 100, sess.kills))
		return sev * CFG.W_SESSION
	end
	return 0.0
end

local function dAccount(p: Types.PlayerProfile, s: Types.Sample): number
	if p.accountAge > CFG.ACCOUNT_AGE_DAYS then return 0.0 end
	if p.wAccuracy.n < 30 then return 0.0 end
	local acc : number = p.wAccuracy.mean
	if acc >= CFG.SMURF_ACCURACY then
		local sev : number = MathLib.clamp01(
			(acc - CFG.SMURF_ACCURACY) / (1 - CFG.SMURF_ACCURACY)
		) * 0.6
		push(p, "ACCOUNT_INTEGRITY", sev, s,
			string.format("age=%d days, acc=%.1f%%", p.accountAge, acc * 100))
		return sev * CFG.W_ACCOUNT
	end
	return 0.0
end

-- Compares the last N angular deltas of the camera against the
-- "perfect inverse recoil" pattern: if a weapon kicks upward by
-- some pattern and the player's camera mirrors it exactly
-- (Pearson |r| → 1), that is scripted recoil compensation.
--
-- In practice you supply the expected recoil pattern per weapon
-- via AntiCheatService.setRecoilPattern(). Without a registered
-- pattern this detector is a no-op.
local _recoilPatterns : { [string]: { number } } = {}

function AnomalyDetector.setRecoilPattern(weaponName: string, pattern: { number }): ()
	_recoilPatterns[weaponName] = pattern
end

local function dRecoil(
	p          : Types.PlayerProfile,
	s          : Types.Sample,
	weaponName : string?
): number
	if not weaponName then return 0.0 end
	local pattern : { number }? = _recoilPatterns[weaponName]
	if not pattern then return 0.0 end
	local n : number = #pattern
	if n < CFG.RECOIL_MIN_SAMPLES then return 0.0 end

	-- Extract last n angular deltas from ring
	local cft      : Types.CFrameTracker = p.cfTracker
	local deltas   : { number } = table.create(n, 0.0)
	local ringCap  : number = #cft.angularDeltas
	local cur      : number = ((cft.head - 2) % ringCap) + 1
	for i = n, 1, -1 do
		deltas[i] = cft.angularDeltas[cur]
		cur = ((cur - 2) % ringCap) + 1
	end

	local r   : number = math.abs(MathLib.pearson(deltas, pattern))
	if r >= CFG.RECOIL_PEARSON_THRESHOLD then
		local sev : number = MathLib.clamp01((r - CFG.RECOIL_PEARSON_THRESHOLD) / (1 - CFG.RECOIL_PEARSON_THRESHOLD))
		push(p, "RECOIL_PERFECT", sev, s,
			string.format("|r|=%.4f weapon=%s", r, weaponName))
		return sev * CFG.W_RECOIL
	end
	return 0.0
end

function AnomalyDetector.analyse(
	profile    : Types.PlayerProfile,
	sample     : Types.Sample,
	prevSamp   : Types.Sample,
	dt         : number,
	weaponName : string?
): number
	profile.suspicion = MathLib.expDecay(profile.suspicion, dt, CFG.HALF_LIFE)

	local hasBaseline : boolean = profile.wReaction.n >= 30
	local zRpt = StatsEngine.computeZReport(profile, sample)

	local delta : number = 0.0
	delta += dReaction(profile, sample, zRpt.zReaction)
	delta += dCPS(profile, sample, zRpt.zCps)
	delta += dSpeed(profile, sample, zRpt.zSpeed)
	delta += dTeleport(profile, sample, prevSamp)

	if hasBaseline then
		delta += dAccuracy(profile, sample, zRpt.zAccuracy)
		delta += dIET(profile, sample)
		delta += dCFrame(profile, sample)
		delta += dMarkov(profile, sample, profile.lastAction)
		delta += dSession(profile, sample)
		delta += dAccount(profile, sample)
		delta += dPopulation(profile, sample)
		delta += dRecoil(profile, sample, weaponName)
	end

	local applied : number = delta * CFG.DELTA_SCALE
	profile.suspicion = MathLib.clampSusp(profile.suspicion + applied)
	return applied
end

function AnomalyDetector.reportInvalidHit(
	profile    : Types.PlayerProfile,
	rejectCode : string,
	sample     : Types.Sample
): ()
	local sev : number = if rejectCode == "GEOMETRY" then 0.8
		elseif rejectCode == "RANGE" then 0.5
		else 0.3
	push(profile, "HIT_GEOMETRY_INVALID", sev, sample, "rejectCode=" .. rejectCode)
	profile.suspicion = MathLib.clampSusp(
		profile.suspicion + sev * CFG.DELTA_SCALE * 0.5
	)
end

function AnomalyDetector.reportReplayAttack(
	profile : Types.PlayerProfile,
	sample  : Types.Sample,
	extra   : string?
): ()
	push(profile, "REPLAY_ATTACK", 0.9, sample, extra)
	profile.suspicion = MathLib.clampSusp(profile.suspicion + 0.9 * CFG.DELTA_SCALE)
end

function AnomalyDetector.latestAnomaly(profile: Types.PlayerProfile): Types.AnomalyRecord?
	if profile.anomalySize == 0 then return nil end
	local idx : number = ((profile.anomalyHead - 2) % ANOMALY_CAP) + 1
	return profile.anomalies[idx]
end

AnomalyDetector.CFG = CFG

return AnomalyDetector
