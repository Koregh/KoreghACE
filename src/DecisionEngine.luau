--!strict
--!optimize 2

local Players = game:GetService("Players")
local Types   = require(script.Parent.Parent.Shared.Types)

local THRESHOLDS = {
	CLEAN     =  0,
	MONITOR   = 30,
	ALERT     = 60,
	RESTRICT  = 80,
	SHADOWBAN = 95,
	REMOVE    = 100,
}

local SHADOWBAN_TAG : string = "__AC_SB"
local RESTRICT_TAG  : string = "__AC_RS"

local _origSpeed : { [Types.PlayerId]: number } = {}

local function applyRestrict(player: Player): ()
	if player:HasTag(RESTRICT_TAG) then return end
	local char = player.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if not hum then return end
	_origSpeed[player.UserId] = hum.WalkSpeed
	hum.WalkSpeed = math.min(hum.WalkSpeed, 8)
	player:AddTag(RESTRICT_TAG)
end

local function removeRestrict(player: Player): ()
	if not player:HasTag(RESTRICT_TAG) then return end
	local char = player.Character
	local hum  = char and char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.WalkSpeed = _origSpeed[player.UserId] or 16
		_origSpeed[player.UserId] = nil :: any
	end
	player:RemoveTag(RESTRICT_TAG)
end

local DecisionEngine = {}
DecisionEngine.THRESHOLDS = THRESHOLDS

local function resolveLevel(s: number): Types.SuspicionLevel
	if s >= THRESHOLDS.REMOVE    then return "REMOVE"    end
	if s >= THRESHOLDS.SHADOWBAN then return "SHADOWBAN" end
	if s >= THRESHOLDS.RESTRICT  then return "RESTRICT"  end
	if s >= THRESHOLDS.ALERT     then return "ALERT"     end
	if s >= THRESHOLDS.MONITOR   then return "MONITOR"   end
	return "CLEAN"
end

function DecisionEngine.evaluate(
	profile : Types.PlayerProfile,
	player  : Player
): Types.Decision

	local newLevel : Types.SuspicionLevel = resolveLevel(profile.suspicion)
	local prevLevel                        = profile.level
	profile.level = newLevel

	local decision : Types.Decision = {
		action    = "NONE",
		reason    = newLevel,
		suspicion = profile.suspicion,
	}

	if newLevel == "CLEAN" or newLevel == "MONITOR" then
		removeRestrict(player)
		player:RemoveTag(SHADOWBAN_TAG)
		return decision
	end

	if newLevel == "ALERT" then
		removeRestrict(player)
		player:RemoveTag(SHADOWBAN_TAG)
		decision.action = "WARN"

	elseif newLevel == "RESTRICT" then
		applyRestrict(player)
		player:RemoveTag(SHADOWBAN_TAG)
		decision.action = "RESTRICT"

	elseif newLevel == "SHADOWBAN" then
		applyRestrict(player)
		player:AddTag(SHADOWBAN_TAG)
		decision.action = "SHADOWBAN"

	elseif newLevel == "REMOVE" then
		player:Kick("Removed for suspicious behaviour.")
		decision.action = "REMOVE"
	end

	return decision
end

return DecisionEngine
