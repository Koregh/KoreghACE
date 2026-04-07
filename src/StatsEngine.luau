--!strict
--!optimize 2
--!native


local Types   = require(script.Parent.Parent.Shared.Types)
local MathLib = require(script.Parent.Parent.Shared.MathLib)

local StatsEngine = {}

export type ZReport = {
	zReaction : number,
	zCps      : number,
	zAccuracy : number,
	zSpeed    : number,
}

function StatsEngine.computeZReport(
	p : Types.PlayerProfile,
	s : Types.Sample
): ZReport
	local spd : number = MathLib.speed(s.vel)
	return {
		zReaction = MathLib.zScore(s.reactionMs, p.wReaction.mean, MathLib.welfordStddev(p.wReaction.n, p.wReaction.M2)),
		zCps      = MathLib.zScore(s.cps,        p.wCps.mean,      MathLib.welfordStddev(p.wCps.n,      p.wCps.M2)),
		zAccuracy = MathLib.zScore(s.accuracy,    p.wAccuracy.mean, MathLib.welfordStddev(p.wAccuracy.n, p.wAccuracy.M2)),
		zSpeed    = MathLib.zScore(spd,           p.wSpeed.mean,    MathLib.welfordStddev(p.wSpeed.n,    p.wSpeed.M2)),
	}
end

function StatsEngine.hasSufficientBaseline(p: Types.PlayerProfile): boolean
	return p.wReaction.n >= 30
end

return StatsEngine
