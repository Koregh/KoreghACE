--!strict
--!optimize 2
--!native

-- ============================================================
--  MathLib.luau  v3.0 — Low-level computational mathematics
--  All functions: pure, @inline where applicable, zero alloc.
--
--  v3 additions:
--    • fpsScaleFactor   — normalise thresholds by player FPS
--    • reactionFpsFloor — minimum reaction given FPS frame time
--    • sensitivityZ     — CFrame z-score relative to own baseline
--    • activePhysicsMax — max speed considering physics events
-- ============================================================

local MathLib = {}

-- ── Constants ────────────────────────────────────────────────
local INV_SQRT2PI : number = 0.3989422804014327
local LN2         : number = 0.6931471805599453

-- ── Welford Online Mean/Variance ─────────────────────────────

@inline
function MathLib.welfordPush(n: number, mean: number, M2: number, x: number)
	: (number, number, number)
	n += 1
	local delta  = x - mean
	mean += delta / n
	M2   += delta * (x - mean)
	return n, mean, M2
end

@inline
function MathLib.welfordVariance(n: number, M2: number): number
	if n < 2 then return 0.0 end
	return M2 / n
end

@inline
function MathLib.welfordStddev(n: number, M2: number): number
	return math.sqrt(MathLib.welfordVariance(n, M2))
end

-- ── Z-score & p-value ────────────────────────────────────────

@inline
function MathLib.zScore(x: number, mean: number, stddev: number): number
	if stddev < 1e-9 then return 0.0 end
	return (x - mean) / stddev
end

-- Normal CDF — Abramowitz & Stegun §26.2.17, error < 7.5e-8
function MathLib.normalCDF(x: number): number
	local sign : number = 1.0
	if x < 0 then x = -x; sign = -1.0 end
	local t  = 1.0 / (1.0 + 0.2316419 * x)
	local t2 = t*t; local t3 = t2*t; local t4 = t3*t; local t5 = t4*t
	local poly = 0.319381530*t - 0.356563782*t2 + 1.781477937*t3
	            - 1.821255978*t4 + 1.330274429*t5
	local cdf = 1.0 - INV_SQRT2PI * math.exp(-0.5*x*x) * poly
	return if sign < 0 then 1.0 - cdf else cdf
end

@inline
function MathLib.pValue(z: number): number
	return 2.0 * (1.0 - MathLib.normalCDF(math.abs(z)))
end

-- ── Exponential decay ────────────────────────────────────────

@inline
function MathLib.expDecay(value: number, dt: number, halfLife: number): number
	if halfLife <= 0.0 then return value end
	return value * math.exp(-(LN2 / halfLife) * dt)
end

-- ── Pearson correlation coefficient ──────────────────────────
function MathLib.pearson(xs: { number }, ys: { number }): number
	local n : number = math.min(#xs, #ys)
	if n < 2 then return 0.0 end
	local sumX : number = 0.0
	local sumY : number = 0.0
	for i = 1, n do sumX += xs[i]; sumY += ys[i] end
	local mx : number = sumX / n
	local my : number = sumY / n
	local num  : number = 0.0
	local denX : number = 0.0
	local denY : number = 0.0
	for i = 1, n do
		local dx : number = xs[i] - mx
		local dy : number = ys[i] - my
		num  += dx * dy
		denX += dx * dx
		denY += dy * dy
	end
	local den : number = math.sqrt(denX * denY)
	if den < 1e-12 then return 0.0 end
	return num / den
end

-- ── Angular delta between two CFrames ────────────────────────
@inline
function MathLib.cframeDelta(a: CFrame, b: CFrame): number
	local dot : number = math.clamp(a.LookVector:Dot(b.LookVector), -1.0, 1.0)
	return math.acos(dot)
end

@inline
function MathLib.angularVelocity(a: CFrame, b: CFrame, dt: number): number
	if dt < 1e-6 then return 0.0 end
	return MathLib.cframeDelta(a, b) / dt
end

-- ── Vector3 speed ─────────────────────────────────────────────
@inline
function MathLib.speed(v: Vector3): number
	local x = v.X; local y = v.Y; local z = v.Z
	return math.sqrt(x*x + y*y + z*z)
end

-- ── Ping-compensated position threshold ──────────────────────
@inline
function MathLib.positionThreshold(
	speed       : number,
	ping        : number,
	errorMargin : number
): number
	local window : number = math.clamp(ping * 2.0, 0.05, 2.0)
	return speed * window + errorMargin
end

-- ── Coefficient of variation ──────────────────────────────────
@inline
function MathLib.cv(mean: number, stddev: number): number
	if math.abs(mean) < 1e-9 then return 0.0 end
	return stddev / math.abs(mean)
end

-- ── Markov ───────────────────────────────────────────────────
function MathLib.markovProbSmoothed(
	matrix      : { [number]: { [number]: number } },
	stateCounts : { [number]: number },
	from        : number,
	to          : number,
	alpha       : number,
	vocabSize   : number
): number
	local rowSum : number = (stateCounts[from] or 0.0) + alpha * vocabSize
	local row    : { [number]: number }? = matrix[from]
	local count  : number = ((row and row[to]) or 0.0) + alpha
	return count / rowSum
end

-- ── Shannon entropy (normalised) ──────────────────────────────
function MathLib.entropyNorm(
	row      : { [number]: number },
	rowSum   : number,
	vocabSize: number
): number
	if rowSum <= 0 then return 0.0 end
	local H : number = 0.0
	for _, count in row do
		local p : number = count / rowSum
		if p > 0.0 then H -= p * math.log(p) end
	end
	return H / math.log(math.max(vocabSize, 2))
end

-- ── Clamp utilities ──────────────────────────────────────────
@inline function MathLib.clamp01(x: number): number
	return math.max(0.0, math.min(1.0, x))
end

@inline function MathLib.clampSusp(x: number): number
	return math.max(0.0, math.min(100.0, x))
end

-- ── Ring index (1-based) ─────────────────────────────────────
@inline function MathLib.ringIdx(head: number, offset: number, cap: number): number
	return ((head + offset - 2) % cap) + 1
end

-- ════════════════════════════════════════════════════════════
--  v3 additions
-- ════════════════════════════════════════════════════════════

-- ── FPS scale factor ─────────────────────────────────────────
-- Returns a multiplier (≥1) that relaxes thresholds for low-fps
-- players. At TARGET_FPS (60) the factor is 1.0.
-- At 20 fps it returns ~1.73; at 10 fps ~2.45.
-- Used to scale position deltas and reaction floors.
local TARGET_FPS : number = 60.0

@inline
function MathLib.fpsScaleFactor(fps: number): number
	local safeFps : number = math.max(fps, 5.0)
	-- Scale proportional to sqrt(TARGET/fps) — aggressive enough
	-- to avoid false positives at low fps without fully disabling
	-- detection (a sqrt curve, not a linear one).
	return math.sqrt(TARGET_FPS / safeFps)
end

-- ── Reaction-time FPS floor ───────────────────────────────────
-- The minimum measurable reaction at a given FPS is one frame.
-- Below this value a reaction is physically impossible regardless
-- of how fast the player is — the client simply cannot have
-- registered the input faster than one render frame.
-- Returns the floor in milliseconds.
@inline
function MathLib.reactionFpsFloor(fps: number): number
	local safeFps : number = math.max(fps, 1.0)
	-- Two frames: one to render the stimulus, one to process input.
	return (2.0 / safeFps) * 1000.0
end

-- ── CFrame z-score relative to individual baseline ───────────
-- Compares the latest angular velocity against the player's own
-- established baseline (wDeltaBase), not a global constant.
-- This neutralises the effect of mouse sensitivity / DPI.
-- Returns z-score (positive = faster than own history).
@inline
function MathLib.sensitivityZ(
	angVel       : number,
	baselineMean : number,
	baselineM2   : number,
	baselineN    : number
): number
	local stddev : number = MathLib.welfordStddev(baselineN, baselineM2)
	return MathLib.zScore(angVel, baselineMean, stddev)
end

-- ── Active physics max speed ─────────────────────────────────
-- Returns the effective max speed for a player considering any
-- active physics events (explosions, dashes, knockback).
-- physicsEvents : array of PhysicsEvent (may be empty)
-- defaultMax    : the configured TELEPORT_MAX_STUDS_PER_SEC
-- now           : os.clock()
function MathLib.activePhysicsMax(
	physicsEvents : { { expiresAt: number, maxSpeedStuds: number } },
	defaultMax    : number,
	now           : number
): number
	local best : number = defaultMax
	for _, ev in physicsEvents do
		if ev.expiresAt > now then
			if ev.maxSpeedStuds > best then
				best = ev.maxSpeedStuds
			end
		end
	end
	return best
end

-- ── Purge expired physics events (mutates array in-place) ────
function MathLib.purgeExpiredPhysics(
	events : { { expiresAt: number, maxSpeedStuds: number } },
	now    : number
): ()
	local i : number = #events
	while i >= 1 do
		if events[i].expiresAt <= now then
			table.remove(events, i)
		end
		i -= 1
	end
end

return MathLib
