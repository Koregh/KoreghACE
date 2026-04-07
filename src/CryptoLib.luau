--!strict
--!optimize 2
--!native

local CryptoLib = {}

-- Fast non-cryptographic hash for integrity checking.
-- Collision resistance is sufficient for anti-cheat (not crypto).
@inline
local function fmix32(h: number): number
	-- Luau numbers are f64; mask to 32-bit after each step.
	local MASK32 : number = 0xFFFFFFFF
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = bit32.band(h * 0x85EBCA6B, MASK32)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = bit32.band(h * 0xC2B2AE35, MASK32)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

-- Produces one pseudo-random byte from (key, nonce, position).
-- key   : { number } — 16 bytes
-- nonce : u32
-- pos   : byte position in stream (0-based)
-- Returns byte in [0, 255].
@inline
local function keystreamByte(key: { number }, nonce: number, pos: number): number
	-- Mix nonce, position, and two key bytes for this position.
	-- Using fmix32 keeps it non-linear without table lookups.
	local ki  : number = (pos % 16) + 1
	local ki2 : number = ((pos + 7) % 16) + 1
	local h   : number = bit32.bxor(nonce, pos * 0x9E3779B9)
	h = bit32.bxor(h, key[ki]  * 0x00010001)
	h = bit32.bxor(h, key[ki2] * 0x01000001)
	return bit32.band(fmix32(h), 0xFF)
end

-- Generates a 128-bit session key as 16 random bytes.
-- math.random on Roblox Server is seeded from OS entropy (CSPRNG).
function CryptoLib.generateKey(): { number }
	local k : { number } = table.create(16, 0)
	for i = 1, 16 do
		k[i] = math.random(0, 255)
	end
	return k
end

-- plainBytes : array of u8
-- key        : 16-byte key from profile.sessionKey
-- nonce      : monotonic counter (increment before calling)
-- Returns { nonce, cs, data } — the wire packet.
function CryptoLib.encode(
	plainBytes : { number },
	key        : { number },
	nonce      : number
): { nonce: number, cs: number, data: { number } }
	local n    : number   = #plainBytes
	local data : { number } = table.create(n, 0)

	-- XOR each byte with keystream
	local cs : number = nonce   -- seed checksum with nonce
	for i = 1, n do
		local kb   : number = keystreamByte(key, nonce, i - 1)
		local enc  : number = bit32.bxor(plainBytes[i], kb)
		data[i] = enc
		cs = bit32.bxor(cs, enc * (i * 0x9E3779B9))
	end
	cs = fmix32(cs)

	return { nonce = nonce, cs = cs, data = data }
end

-- Returns plainBytes on success, nil on tamper/replay.
-- lastNonce: the last accepted nonce for this player (from profile).
function CryptoLib.decode(
	packet    : { nonce: number, cs: number, data: { number } },
	key       : { number },
	lastNonce : number
): { number }?
	local nonce : number = packet.nonce
	local cs    : number = packet.cs
	local data  : { number } = packet.data

	-- Replay / reorder rejection
	if nonce <= lastNonce then return nil end

	local n     : number   = #data
	local plain : { number } = table.create(n, 0)

	-- Recompute checksum over wire data
	local csCheck : number = nonce
	for i = 1, n do
		csCheck = bit32.bxor(csCheck, data[i] * (i * 0x9E3779B9))
	end
	csCheck = fmix32(csCheck)

	-- Reject on checksum mismatch (tampered payload)
	if csCheck ~= cs then return nil end

	-- Decrypt
	for i = 1, n do
		plain[i] = bit32.bxor(data[i], keystreamByte(key, nonce, i - 1))
	end

	return plain
end

-- Roblox RemoteEvents do not send raw byte arrays efficiently,
-- so we pack small integer payloads as Luau number arrays.
-- These helpers let callers convert their data before encoding.

-- Pack a u8 array from a table of integers (clamped to [0,255]).
function CryptoLib.packInts(values: { number }): { number }
	local out : { number } = table.create(#values, 0)
	for i, v in values do
		out[i] = bit32.band(math.floor(v), 0xFF)
	end
	return out
end

-- Pack a single u32 as 4 bytes (little-endian).
function CryptoLib.packU32(v: number): { number }
	v = bit32.band(math.floor(v), 0xFFFFFFFF)
	return {
		bit32.band(v,              0xFF),
		bit32.band(bit32.rshift(v,  8), 0xFF),
		bit32.band(bit32.rshift(v, 16), 0xFF),
		bit32.band(bit32.rshift(v, 24), 0xFF),
	}
end

-- Unpack 4 bytes (little-endian) to u32.
function CryptoLib.unpackU32(b: { number }, offset: number): number
	local o : number = offset or 1
	return b[o]
		+ bit32.lshift(b[o + 1], 8)
		+ bit32.lshift(b[o + 2], 16)
		+ bit32.lshift(b[o + 3], 24)
end

return CryptoLib
