--!strict
--!optimize 2

-- ============================================================
--  Types.luau  v3.0
--  Single source of truth for every type in the system.
--  Rule: if it crosses a module boundary, it lives here.
--
--  v3 additions:
--    • fps field in Sample and wFps Welford in PlayerProfile
--    • CFrameTracker gets individual baseline for sensitivity
--    • PhysicsEvent for legitimate force whitelisting
--    • SessionKey for per-player XOR stream cipher
--    • anomaly ring fields (anomalyHead / anomalySize)
--    • REPLAY_ATTACK AnomalyKind
-- ============================================================

export type PlayerId = number

-- ── Raw telemetry sample (20 Hz ring) ───────────────────────
export type Sample = {
	t          : number,    -- os.clock() monotonic
	pos        : Vector3,
	vel        : Vector3,
	cf         : CFrame,
	reactionMs : number,
	cps        : number,
	accuracy   : number,
	actionId   : number,
	ping       : number,    -- seconds
	fps        : number,    -- client-reported; default 60 if unknown
}

-- ── Welford online accumulator ───────────────────────────────
export type Welford = {
	n    : number,
	mean : number,
	M2   : number,
}

-- ── Markov ───────────────────────────────────────────────────
export type MarkovMatrix = { [number]: { [number]: number } }
export type MarkovModel  = {
	matrix      : MarkovMatrix,
	stateCounts : { [number]: number },
	totalEdges  : number,
}

-- ── IET tracker ──────────────────────────────────────────────
export type IETTracker = {
	intervals : { number },
	head      : number,
	lastTime  : number,
	wIET      : Welford,
}

-- ── CFrame tracker ───────────────────────────────────────────
export type CFrameTracker = {
	samples       : { CFrame },
	head          : number,
	angularDeltas : { number },  -- rad/s
	wDelta        : Welford,     -- running stats (all time)
	wDeltaBase    : Welford,     -- first BASELINE_N samples — player's own baseline
	baselineReady : boolean,     -- true once wDeltaBase has enough data
}

-- ── Session aggregates ────────────────────────────────────────
export type SessionStats = {
	kills         : number,
	deaths        : number,
	headshotKills : number,
	totalShots    : number,
	totalHits     : number,
	killTimings   : { number },
	avgKillDist   : number,
	sessionStart  : number,
}

-- ── Physics event whitelist ───────────────────────────────────
-- Registered by the game when it applies legitimate forces.
-- While any event is active, speed/teleport checks are relaxed.
export type PhysicsEvent = {
	expiresAt     : number,   -- os.clock()
	maxSpeedStuds : number,   -- per-event override
}

-- ── Per-session XOR stream cipher ────────────────────────────
-- 128-bit key generated server-side per player connection.
-- Nonce is monotonic; server rejects any nonce ≤ last seen.
export type SessionKey = {
	key   : { number },  -- 16 bytes [0,255]
	nonce : number,
}

-- ── Population baseline ───────────────────────────────────────
export type PopulationTier = {
	label        : string,
	minKills     : number,
	reaction     : { p50: number, p95: number },
	cps          : { p50: number, p95: number },
	accuracy     : { p50: number, p95: number },
	speed        : { p50: number, p95: number },
	headshotRate : { p50: number, p95: number },
}
export type PopulationBaseline = { PopulationTier }

-- ── Hit validation ────────────────────────────────────────────
export type HitRequest = {
	victimId    : PlayerId,
	clientPos   : Vector3,
	weaponRange : number,
	damage      : number,
	isHeadshot  : boolean,
}

export type HitResult = {
	valid      : boolean,
	rejectCode : string?,
}

-- ── Anomaly record ────────────────────────────────────────────
export type AnomalyKind =
	  "Z_SCORE_SPIKE"
	| "MARKOV_RARE_SEQ"
	| "VELOCITY_IMPOSSIBLE"
	| "REACTION_SUPERHUMAN"
	| "CPS_MECHANICAL"
	| "ACCURACY_CEILING"
	| "IET_DETERMINISTIC"
	| "CFRAME_MECHANICAL"
	| "HIT_GEOMETRY_INVALID"
	| "HIT_RATE_ABUSE"
	| "TELEPORT"
	| "ACCOUNT_INTEGRITY"
	| "SESSION_HEADSHOT_RATE"
	| "POPULATION_OUTLIER"
	| "RECOIL_PERFECT"
	| "REPLAY_ATTACK"

export type AnomalyRecord = {
	kind      : AnomalyKind,
	severity  : number,
	zScore    : number?,
	transProb : number?,
	extra     : string?,
	t         : number,
	raw       : Sample,
}

-- ── Suspicion state machine ───────────────────────────────────
export type SuspicionLevel =
	  "CLEAN"
	| "MONITOR"
	| "ALERT"
	| "RESTRICT"
	| "SHADOWBAN"
	| "REMOVE"

-- ── Full per-player profile ───────────────────────────────────
export type PlayerProfile = {
	playerId    : PlayerId,
	accountAge  : number,

	wReaction   : Welford,
	wCps        : Welford,
	wAccuracy   : Welford,
	wSpeed      : Welford,
	wFps        : Welford,      -- v3: fps baseline

	iet         : IETTracker,
	cfTracker   : CFrameTracker,

	markov      : MarkovModel,
	lastAction  : number,
	lastActionT : number,

	session     : SessionStats,

	suspicion   : number,
	level       : SuspicionLevel,
	anomalies   : { AnomalyRecord },  -- fixed-size ring (ANOMALY_CAP)
	anomalyHead : number,
	anomalySize : number,

	buffer      : { Sample },
	bufHead     : number,
	bufSize     : number,

	hitCount    : number,
	hitWindow   : number,

	lastServerPos : Vector3,
	lastPosTime   : number,

	physicsEvents : { PhysicsEvent },  -- v3: force whitelist
	sessionKey    : SessionKey,         -- v3: per-session crypto
}

-- ── Decision ──────────────────────────────────────────────────
export type Decision = {
	action    : "NONE" | "WARN" | "RESTRICT" | "SHADOWBAN" | "REMOVE",
	reason    : string,
	suspicion : number,
}

return nil
