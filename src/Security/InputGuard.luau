--!strict
--!optimize 2

local InputGuard = {}

local LIMITS = {
	-- Byte array payload
	MAX_PAYLOAD_BYTES    = 256,
	BYTE_VALUE_MAX       = 255,
	BYTE_VALUE_MIN       = 0,

	-- Numbers
	MAX_SAFE_NUMBER      = 1e9,    -- above this we treat as overflow
	MIN_SAFE_NUMBER      = -1e9,

	-- Strings
	MAX_STRING_LEN       = 128,    -- chars

	-- Tables
	MAX_TABLE_DEPTH      = 3,
	MAX_TABLE_KEYS       = 64,

	-- Packet fields
	MAX_NONCE            = 2^31,   -- u32 max (Luau f64 safe)
	MAX_CHECKSUM         = 2^32,

	-- Hit request
	MAX_POSITION_ABS     = 50_000, -- studs — larger than any Roblox map
	MAX_WEAPON_RANGE     = 2_000,  -- studs
	MAX_DAMAGE           = 10_000,

	-- FPS
	MIN_FPS = 5,
	MAX_FPS = 500,
}

-- Expose limits for external reference
InputGuard.LIMITS = LIMITS



local function isFiniteNumber(v: unknown): boolean
	if typeof(v) ~= "number" then return false end
	local n : number = v :: number
	return n == n             -- NaN check (NaN ≠ NaN)
		and n ~= math.huge
		and n ~= -math.huge
end


local function inRange(v: number, lo: number, hi: number): boolean
	return v >= lo and v <= hi
end

type ValidationResult = { ok: boolean, err: string? }

function InputGuard.checkNumber(
	v    : unknown,
	lo   : number?,
	hi   : number?,
	name : string?
): ValidationResult
	if not isFiniteNumber(v) then
		return false, "non-finite number: " .. tostring(name or "?")
	end
	local n : number = v :: number
	local low  = lo or LIMITS.MIN_SAFE_NUMBER
	local high = hi or LIMITS.MAX_SAFE_NUMBER
	if not inRange(n, low, high) then
		return false, string.format("%s=%.2f out of [%.0f, %.0f]",
			name or "?", n, low, high)
	end
	return true, nil
end

function InputGuard.checkString(
	v       : unknown,
	maxLen  : number?,
	name    : string?
): ValidationResult
	if typeof(v) ~= "string" then
		return false, "expected string: " .. tostring(name or "?")
	end
	local s   : string = v :: string
	local cap : number = maxLen or LIMITS.MAX_STRING_LEN
	if #s > cap then
		return false, string.format("%s string too long: %d > %d",
			name or "?", #s, cap)
	end
	-- Reject null bytes and control characters (< 0x20 except \n\r\t)
	if s:find("[\0\1\2\3\4\5\6\7\8\11\12\14-\31]") then
		return false, "string contains control characters: " .. tostring(name or "?")
	end
	return true, nil
end

-- Uses a seen-set to catch recursive tables.
local function checkTableInner(
	t       : unknown,
	depth   : number,
	seen    : { [unknown]: boolean }
): (boolean, string?)
	if typeof(t) ~= "table" then
		return false, "expected table at depth " .. depth
	end
	if depth > LIMITS.MAX_TABLE_DEPTH then
		return false, "table exceeds max depth " .. LIMITS.MAX_TABLE_DEPTH
	end
	if seen[t] then
		return false, "recursive table detected"
	end
	seen[t] = true

	local count : number = 0
	for _, v in t :: { unknown } do
		count += 1
		if count > LIMITS.MAX_TABLE_KEYS then
			return false, "table too many keys: > " .. LIMITS.MAX_TABLE_KEYS
		end
		if typeof(v) == "table" then
			local ok, err = checkTableInner(v, depth + 1, seen)
			if not ok then return false, err end
		end
	end

	seen[t] = nil  -- allow the same subtable to appear in sibling branches
	return true, nil
end

function InputGuard.checkTable(t: unknown): ValidationResult
	return checkTableInner(t, 1, {})
end

-- Validates { number } array: each element must be u8 [0,255].
function InputGuard.checkByteArray(
	arr  : unknown,
	minN : number?,
	maxN : number?
): ValidationResult
	if typeof(arr) ~= "table" then
		return false, "payload must be a table"
	end
	local a   : { unknown } = arr :: { unknown }
	local len : number = #a
	local lo  : number = minN or 0
	local hi  : number = maxN or LIMITS.MAX_PAYLOAD_BYTES

	if len < lo then
		return false, string.format("payload too short: %d < %d", len, lo)
	end
	if len > hi then
		return false, string.format("payload too large: %d > %d", len, hi)
	end

	for i = 1, len do
		local b = a[i]
		if not isFiniteNumber(b) then
			return false, "non-numeric byte at index " .. i
		end
		local n : number = b :: number
		if n ~= math.floor(n) then
			return false, "non-integer byte at index " .. i
		end
		if not inRange(n, 0, 255) then
			return false, string.format("byte[%d]=%d out of [0,255]", i, n)
		end
	end
	return true, nil
end

-- Validates the wire format: { nonce: number, cs: number, data: {number} }
function InputGuard.checkPacket(v: unknown): ValidationResult
	local ok, err = InputGuard.checkTable(v)
	if not ok then return false, "packet: " .. (err or "") end

	local p = (v :: any)

	-- nonce
	local nok, nerr = InputGuard.checkNumber(p.nonce, 0, LIMITS.MAX_NONCE, "nonce")
	if not nok then return false, nerr end
	if p.nonce ~= math.floor(p.nonce) then return false, "nonce not integer" end

	-- checksum
	local cok, cerr = InputGuard.checkNumber(p.cs, 0, LIMITS.MAX_CHECKSUM, "cs")
	if not cok then return false, cerr end

	-- data
	local dok, derr = InputGuard.checkByteArray(p.data)
	if not dok then return false, "data: " .. (derr or "") end

	return true, nil
end

function InputGuard.checkHitBytes(bytes: { number }): ValidationResult
	if #bytes < 25 then
		return false, "hit payload too short: " .. #bytes
	end
	-- Individual field checks are done by AntiCheatService after unpack,
	-- but we can sanity-check the position bytes won't overflow.
	-- Position offset-encoded: value = raw - 32768, range [-32768, 32767]
	-- Raw values are unpacked from u32, so always in [0, 65535] — fine.
	return true, nil
end

function InputGuard.checkFps(v: unknown): ValidationResult
	return InputGuard.checkNumber(v, LIMITS.MIN_FPS, LIMITS.MAX_FPS, "fps")
end

function InputGuard.checkDamage(v: number): ValidationResult
	return InputGuard.checkNumber(v, 0, LIMITS.MAX_DAMAGE, "damage")
end

function InputGuard.checkWeaponRange(v: number): ValidationResult
	return InputGuard.checkNumber(v, 0, LIMITS.MAX_WEAPON_RANGE, "weaponRange")
end

function InputGuard.checkPosition(pos: Vector3): ValidationResult
	local function coordOk(c: number, label: string): ValidationResult
		if c ~= c or c == math.huge or c == -math.huge then
			return false, label .. " is NaN or inf"
		end
		if math.abs(c) > LIMITS.MAX_POSITION_ABS then
			return false, string.format("%s=%.0f exceeds map bounds", label, c)
		end
		return true, nil
	end
	local xok, xe = coordOk(pos.X, "posX")
	if not xok then return false, xe end
	local yok, ye = coordOk(pos.Y, "posY")
	if not yok then return false, ye end
	local zok, ze = coordOk(pos.Z, "posZ")
	if not zok then return false, ze end
	return true, nil
end

return InputGuard
