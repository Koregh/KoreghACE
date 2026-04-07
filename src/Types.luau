--!strict
--!optimize 2


export type PlayerId = number

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

export type Welford = {
	n    : number,
	mean : number,
	M2   : number,
}

export type MarkovMatrix = { [number]: { [number]: number } }
export type MarkovModel  = {
	matrix      : MarkovMatrix,
	stateCounts : { [number]: number },
	totalEdges  : number,
}

export type IETTracker = {
	intervals : { number },
	head      : number,
	lastTime  : number,
	wIET      : Welford,
}

export type CFrameTracker = {
	samples       : { CFrame },
	head          : number,
	angularDeltas : { number },  -- rad/s
	wDelta        : Welford,     -- running stats (all time)
	wDeltaBase    : Welford,     -- first BASELINE_N samples — player's own baseline
	baselineReady : boolean,     -- true once wDeltaBase has enough data
}

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

export type SuspicionLevel =
	  "CLEAN"
	| "MONITOR"
	| "ALERT"
	| "RESTRICT"
	| "SHADOWBAN"
	| "REMOVE"

export type PlayerProfile = {
	playerId    : PlayerId,
	accountAge  : number,

	wReaction   : Welford,
	wCps        : Welford,
	wAccuracy   : Welford,
	wSpeed      : Welford,
	wFps        : Welford,      

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

	physicsEvents : { PhysicsEvent }, 
	sessionKey    : SessionKey,         
}

export type Decision = {
	action    : "NONE" | "WARN" | "RESTRICT" | "SHADOWBAN" | "REMOVE",
	reason    : string,
	suspicion : number,
}

return nil
