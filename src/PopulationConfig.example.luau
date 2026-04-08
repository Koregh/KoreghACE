--!strict

--  PopulationConfig  —  EXAMPLE / REFERENCE FILE
--  DO NOT use this file directly in production.
--  Copy PopulationConfig.luau and fill with your own data.
--
-- HOW TO USE:
-- Replace the values below with actual data from YOUR game.
-- Each tier maps a range of kills to expected percentiles.
-- The system compares each player against the tier they correspond to
-- their kill count — not just against your own record.
--
-- If you don't have real data yet, use the defaults below
-- as a starting point. The system runs in adaptive-only mode
-- when no tier matches the player.
--
-- HOW TO COLLECT DATA:
-- Call AntiCheatService.dumpSessionStats() on reliable players
-- at the end of the session to collect real values.
-- Do this for ~50 players per tier for solid percentiles.
--
--
-- Metrics source:
-- Reaction time: CS2 performance studies (leetify.com)
-- Headshot rate : leetify.com population data 2024
-- Accuracy: CS2 Match Stats (Valve + community trackers)
-- Speed (studs/s): CS2 → Roblox mapping:
--     CS2 walking = 130 u/s ≈  8 studs/s
--     CS2 running = 250 u/s ≈ 16 studs/s (default Roblox walk)
--     CS2 knife   = 260 u/s ≈ 17 studs/s
-- CPS: frequency of player actions (not just shots)
--     Includes skill use, weapon switching, jumps, etc.
--     CS2 rifles fire at ~10 RPS; pistols ~4–8 RPS.
--
-- Tiers mapped by equivalent CS2 rank:
--   Tier 1 (    0 –    99 kills) → Silver I – Silver Elite Master
--   Tier 2 (  100 –   999 kills) → Gold Nova – Master Guardian Elite
--   Tier 3 (1 000 – 9 999 kills) → DMG – Legendary Eagle Master
--   Tier 4 (10 000+      kills)  → Supreme – Global Elite / Faceit 10
--
-- NOTE: These values are approximations for a Roblox FPS game
-- with mechanics similar to CS2. Calibrate with your own data.

local Types = require(script.Parent.Types)

-- ENABLED = false → system runs in adaptive-only mode (ignores tiers).
local ENABLED : boolean = true

--
-- reaction     : ms    — reaction time (visual stimulus → input)
-- cps          : n/s   — actions per second (clicks, skills)
-- accuracy     : [0,1] — % of shots that hit a target
-- speed        : studs/s — observed movement speed
-- headshotRate : [0,1] — % of kills that are headshots
--
-- p50 = expected median for players in this tier
-- p95 = ceiling of the 95th percentile — above this is a population outlier

local DEFAULT_TIERS : Types.PopulationBaseline = {

	--  Tier 1 · Silver  (0 – 99 kills)
	--  CS2 equiv.: Silver I → Silver Elite Master
	--
	--  Profile: beginner, inconsistent aim, slow reaction,
	--  predictable movement, little counter-strafing.
	--
	--  CS2 reference data:
	--    reaction p50 ≈ 420ms  (leetify Silver avg: ~430ms)
	--    hs rate  p50 ≈ 18%    (Valve: Silver avg ~17–20%)
	--    accuracy p50 ≈ 22%    (CS2 Silver match accuracy avg)
	--    speed    p50 ≈ 14     (cautious movement, few sprints)
	--    cps      p50 ≈ 3.5    (pistol/semi-auto casual)
	{
		label    = "silver",
		minKills = 0,
		reaction     = { p50 = 420,  p95 = 680  },  -- ms
		cps          = { p50 = 3.5,  p95 = 8.0  },
		accuracy     = { p50 = 0.22, p95 = 0.50 },  -- [0,1]
		speed        = { p50 = 14.0, p95 = 22.0 },  -- studs/s
		headshotRate = { p50 = 0.18, p95 = 0.42 },
	},

	--  Tier 2 · Gold Nova / Master Guardian  (100 – 999 kills)
	--  CS2 equiv.: Gold Nova I → Master Guardian Elite
	--
	--  Profile: intermediate, improving aim, starting peeks and
	--  spray control, uses automatic rifles more often.
	--
	--  CS2 reference data:
	--    reaction p50 ≈ 310ms  (leetify GN avg: ~300–320ms)
	--    hs rate  p50 ≈ 28%    (GN/MG community avg: ~26–30%)
	--    accuracy p50 ≈ 38%    (CS2 MG match accuracy avg)
	--    speed    p50 ≈ 15     (starting to use counter-strafing)
	--    cps      p50 ≈ 4.5    (fully-auto rifles more common)
	{
		label    = "gold_nova",
		minKills = 100,
		reaction     = { p50 = 310,  p95 = 510  },
		cps          = { p50 = 4.5,  p95 = 9.0  },
		accuracy     = { p50 = 0.38, p95 = 0.63 },
		speed        = { p50 = 15.0, p95 = 24.0 },
		headshotRate = { p50 = 0.28, p95 = 0.52 },
	},

	--  Tier 3 · DMG / Legendary Eagle  (1 000 – 9 999 kills)
	--  CS2 equiv.: Distinguished MG → Legendary Eagle Master
	--
	--  Profile: advanced, technical aim, pre-aim, utility usage,
	--  precise burst fire, consistent counter-strafing.
	--
	--  CS2 reference data:
	--    reaction p50 ≈ 225ms  (leetify DMG avg: ~210–240ms)
	--    hs rate  p50 ≈ 40%    (Eagle players: ~38–43%)
	--    accuracy p50 ≈ 54%    (CS2 Eagle match accuracy avg)
	--    speed    p50 ≈ 15.5   (counter-strafe almost always)
	--    cps      p50 ≈ 5.5    (refined mechanics, tap+burst)
	{
		label    = "dmg_eagle",
		minKills = 1_000,
		reaction     = { p50 = 225,  p95 = 370  },
		cps          = { p50 = 5.5,  p95 = 10.0 },
		accuracy     = { p50 = 0.54, p95 = 0.76 },
		speed        = { p50 = 15.5, p95 = 26.0 },
		headshotRate = { p50 = 0.40, p95 = 0.63 },
	},

	--  Tier 4 · Global Elite / Faceit 10  (10 000+ kills)
	--  CS2 equiv.: Supreme → Global Elite / Faceit Level 10
	--
	--  Profile: elite, near-mechanical aim, reaction at human limit,
	--  first-bullet always precise, consistent headshots.
	--
	--  CS2 reference data:
	--    reaction p50 ≈ 165ms  (leetify GE avg: ~155–175ms)
	--                 ← below 130ms starts to be suspicious
	--    hs rate  p50 ≈ 54%    (GE/Faceit 10 avg: ~52–57%)
	--    accuracy p50 ≈ 68%    (Faceit lvl 10 match accuracy avg)
	--    speed    p50 ≈ 16     (perfect counter-strafe = 250 u/s)
	--    cps      p50 ≈ 6.5    (high-frequency tap/burst)
	--
	--    WARNING:
	--    accuracy p95 = 0.88 → close to the verifiable human ceiling.
	--    Values above 0.92 over a long session (>100 shots) are
	--    strongly suspicious. ACCURACY_CEIL in AnomalyDetector
	--    is set to 0.97 — adjust to 0.92 for a pure FPS game.
	{
		label    = "global_elite",
		minKills = 10_000,
		reaction     = { p50 = 165,  p95 = 260  },
		cps          = { p50 = 6.5,  p95 = 11.0 },
		accuracy     = { p50 = 0.68, p95 = 0.88 },
		speed        = { p50 = 16.0, p95 = 28.0 },
		headshotRate = { p50 = 0.54, p95 = 0.72 },
	},
}

local TIERS : Types.PopulationBaseline = DEFAULT_TIERS


local PopulationConfig = {}

PopulationConfig.ENABLED = ENABLED


function PopulationConfig.getTier(kills: number): Types.PopulationTier?
	if not ENABLED then return nil end

	local matched : Types.PopulationTier? = nil
	for _, tier in TIERS do
		if kills >= tier.minKills then
			matched = tier
		end
	end
	return matched
end


function PopulationConfig.outlierSeverity(
	value : number,
	p50   : number,
	p95   : number
): number
	local sigma : number = (p95 - p50) / 1.6449
	if sigma < 1e-9 then return 0.0 end
	local z : number = (value - p95) / sigma
	if z <= 0 then return 0.0 end
	return math.max(0.0, math.min(1.0, z / 3.0))
end

return PopulationConfig
