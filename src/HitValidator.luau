--!strict
--!optimize 2
--!native

-- ============================================================
--  HitValidator.luau  v2.0
--  Server-authoritative hit validation.
--  Checks: range, geometry (raycast), rate limiting.
--  The client sends hit requests; the server decides if valid.
--
--  Key insight from devforum research:
--    DO NOT do frame-perfect position checks — use time-window
--    averages with ping compensation to avoid false positives.
--    Instantaneous checks are unreliable on Roblox's network.
-- ============================================================

local Players     = game:GetService("Players")
local Workspace   = game:GetService("Workspace")

local Types   = require(script.Parent.Parent.Shared.Types)
local MathLib = require(script.Parent.Parent.Shared.MathLib)

-- ── Config ───────────────────────────────────────────────────
local CFG = {
	-- Extra lenience added on top of ping compensation (studs).
	-- Accounts for Roblox physics jitter & replication lag.
	POSITION_ERROR_MARGIN   : number = 4.0,

	-- Max hits per second per player (global, all targets).
	MAX_HIT_RATE            : number = 10,

	-- If a player's claimed hit position is farther than
	-- weaponRange * this factor from the server-known victim
	-- position, the hit is rejected.
	RANGE_SLACK_FACTOR      : number = 1.25,

	-- Raycast ignore list: add parts that should not block hits.
	-- Populated at runtime via HitValidator.addIgnore().
	-- IgnoreList is always in sync with Workspace.
}

local HitValidator = {}

-- Runtime ignore list for raycasts (e.g. friendly hitboxes)
local _ignoreList : { Instance } = {}
local _ignoreParams : RaycastParams = RaycastParams.new()
_ignoreParams.FilterDescendantsInstances = _ignoreList
_ignoreParams.FilterType = Enum.RaycastFilterType.Exclude

function HitValidator.addIgnore(instance: Instance): ()
	_ignoreList[#_ignoreList + 1] = instance
	_ignoreParams.FilterDescendantsInstances = _ignoreList
end

-- ── Rate limiter ──────────────────────────────────────────────
-- Uses a token-bucket-style sliding window per player.
local function checkHitRate(profile: Types.PlayerProfile): boolean
	local now : number = os.clock()

	if now - profile.hitWindow > 1.0 then
		profile.hitWindow = now
		profile.hitCount  = 1
		return true
	end

	profile.hitCount += 1
	return profile.hitCount <= CFG.MAX_HIT_RATE
end

-- ── Geometry validation ───────────────────────────────────────
-- Casts a ray from attacker's server position to victim's server
-- position. If something solid is in between, the hit is
-- geometrically impossible (wallbang without penetration).
local function checkGeometry(
	attackerPos : Vector3,
	victimPos   : Vector3
): boolean
	local dir    : Vector3 = victimPos - attackerPos
	local dist   : number  = dir.Magnitude
	if dist < 0.1 then return true end   -- point-blank, always valid

	local result : RaycastResult? = Workspace:Raycast(
		attackerPos,
		dir.Unit * dist,
		_ignoreParams
	)

	-- If raycast hit something, it might be blocking the shot.
	-- We check if the hit instance is NOT the victim's character.
	-- This is a soft check — solid hits count as blocked.
	if result then
		local hitInst : Instance = result.Instance
		-- Walk up to check if it belongs to any player's character
		local char : Instance? = hitInst.Parent
		local isVictimChar : boolean = false
		for _, p in Players:GetPlayers() do
			if p.Character == char then
				isVictimChar = true
				break
			end
		end
		-- If the obstacle is not a character, the ray is blocked
		return isVictimChar
	end

	return true   -- clear line of sight
end

-- ── Range validation (ping-compensated) ───────────────────────
-- Compares the attacker's claimed client position at hit time
-- against the server's last known position of the victim,
-- accounting for network latency.
local function checkRange(
	attackerProfile  : Types.PlayerProfile,
	victimProfile    : Types.PlayerProfile,
	clientHitPos     : Vector3,
	weaponRange      : number
): boolean
	-- Effective max distance = weapon range + ping-based leniency
	local attackerPing : number = attackerProfile.buffer[
		((attackerProfile.bufHead - 2) % 256) + 1
	].ping

	local victimPing : number = victimProfile.buffer[
		((victimProfile.bufHead - 2) % 256) + 1
	].ping

	-- Combined latency budget = sum of both pings (one-way each)
	local totalPing : number = math.clamp(
		attackerPing + victimPing, 0.05, 1.0
	)

	-- Victim may have moved this far since server snapshot
	local victimSpeed : number = MathLib.speed(
		victimProfile.buffer[((victimProfile.bufHead - 2) % 256) + 1].vel
	)
	local posThresh : number = MathLib.positionThreshold(
		victimSpeed, totalPing, CFG.POSITION_ERROR_MARGIN
	)

	local victimServerPos : Vector3 = victimProfile.lastServerPos
	local distToVictim    : number  = (clientHitPos - victimServerPos).Magnitude
	local maxAllowed      : number  = weaponRange * CFG.RANGE_SLACK_FACTOR + posThresh

	return distToVictim <= maxAllowed
end

-- ── Main validation entry point ───────────────────────────────
--[[
	Call this from your combat RemoteEvent handler.
	Returns HitResult { valid, rejectCode }.

	Example usage in your weapon script:
	  local result = HitValidator.validate(attackerProfile, req, victimProfile)
	  if not result.valid then return end
	  -- apply damage
]]
function HitValidator.validate(
	attackerProfile : Types.PlayerProfile,
	req             : Types.HitRequest,
	victimProfile   : Types.PlayerProfile
): Types.HitResult

	-- 1. Rate limit
	if not checkHitRate(attackerProfile) then
		return { valid = false, rejectCode = "RATE" }
	end

	-- 2. Range check (ping-compensated)
	if not checkRange(attackerProfile, victimProfile, req.clientPos, req.weaponRange) then
		return { valid = false, rejectCode = "RANGE" }
	end

	-- 3. Geometry (raycast line-of-sight)
	local attackerPos : Vector3 = attackerProfile.lastServerPos
	local victimPos   : Vector3 = victimProfile.lastServerPos

	if not checkGeometry(attackerPos, victimPos) then
		return { valid = false, rejectCode = "GEOMETRY" }
	end

	return { valid = true, rejectCode = nil }
end

-- Expose config for runtime tuning
HitValidator.CFG = CFG

return HitValidator
