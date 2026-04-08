--!strict

local Types = require(script.Parent.Types)

-- Set to false to run in adaptive-only mode (ignores tiers).
local ENABLED : boolean = true

-- Replace with your actual game data collected via AntiCheatService.dumpSessionStats().
-- See PopulationConfig.example.luau for full documentation and reference values.
local TIERS : Types.PopulationBaseline = {
	{
		label    = "silver",
		minKills = 0,
		reaction     = { p50 = 420,  p95 = 680  },
		cps          = { p50 = 3.5,  p95 = 8.0  },
		accuracy     = { p50 = 0.22, p95 = 0.50 },
		speed        = { p50 = 14.0, p95 = 22.0 },
		headshotRate = { p50 = 0.18, p95 = 0.42 },
	},
	{
		label    = "gold_nova",
		minKills = 100,
		reaction     = { p50 = 310,  p95 = 510  },
		cps          = { p50 = 4.5,  p95 = 9.0  },
		accuracy     = { p50 = 0.38, p95 = 0.63 },
		speed        = { p50 = 15.0, p95 = 24.0 },
		headshotRate = { p50 = 0.28, p95 = 0.52 },
	},
	{
		label    = "dmg_eagle",
		minKills = 1_000,
		reaction     = { p50 = 225,  p95 = 370  },
		cps          = { p50 = 5.5,  p95 = 10.0 },
		accuracy     = { p50 = 0.54, p95 = 0.76 },
		speed        = { p50 = 15.5, p95 = 26.0 },
		headshotRate = { p50 = 0.40, p95 = 0.63 },
	},
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
