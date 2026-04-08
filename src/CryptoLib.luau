--!strict
--!optimize 2
--!native

local CryptoLib = {}

local function fmix32(h: number): number
	local MASK32 : number = 0xFFFFFFFF
	h = bit32.bxor(h, bit32.rshift(h, 16))
	h = bit32.band(h * 0x85EBCA6B, MASK32)
	h = bit32.bxor(h, bit32.rshift(h, 13))
	h = bit32.band(h * 0xC2B2AE35, MASK32)
	h = bit32.bxor(h, bit32.rshift(h, 16))
	return h
end

local function keystreamByte(key: { number }, nonce: number, pos: number): number
	local ki  : number = (pos % 16) + 1
	local ki2 : number = ((pos + 7) % 16) + 1
	local h   : number = bit32.bxor(nonce, bit32.band(pos * 0x9E3779B9, 0xFFFFFFFF))
	h = bit32.bxor(h, key[ki]  * 0x00010001)
	h = bit32.bxor(h, key[ki2] * 0x01000001)
	return bit32.band(fmix32(h), 0xFF)
end

function CryptoLib.generateKey(): { number }
	local k : { number } = table.create(16, 0)
	for i = 1, 16 do
		k[i] = math.random(0, 255)
	end
	return k
end

function CryptoLib.encode(
	plainBytes : { number },
	key        : { number },
	nonce      : number
): { nonce: number, cs: number, data: { number } }
	local n    : number     = #plainBytes
	local data : { number } = table.create(n, 0)

	local cs : number = nonce
	for i = 1, n do
		local kb  : number = keystreamByte(key, nonce, i - 1)
		local enc : number = bit32.bxor(plainBytes[i], kb)
		data[i] = enc
		-- FIX: mask i * multiplier to 32 bits before xor to avoid f64 precision loss
		cs = bit32.bxor(cs, bit32.band(enc * bit32.band(i * 0x9E3779B9, 0xFFFFFFFF), 0xFFFFFFFF))
	end
	cs = fmix32(cs)

	return { nonce = nonce, cs = cs, data = data }
end

function CryptoLib.decode(
	packet    : { nonce: number, cs: number, data: { number } },
	key       : { number },
	lastNonce : number
): { number }?
	local nonce : number     = packet.nonce
	local cs    : number     = packet.cs
	local data  : { number } = packet.data

	if nonce <= lastNonce then return nil end

	local n     : number     = #data
	local plain : { number } = table.create(n, 0)

	-- FIX: use the same masked formula as encode
	local csCheck : number = nonce
	for i = 1, n do
		csCheck = bit32.bxor(csCheck, bit32.band(data[i] * bit32.band(i * 0x9E3779B9, 0xFFFFFFFF), 0xFFFFFFFF))
	end
	csCheck = fmix32(csCheck)

	if csCheck ~= cs then return nil end

	for i = 1, n do
		plain[i] = bit32.bxor(data[i], keystreamByte(key, nonce, i - 1))
	end

	return plain
end

function CryptoLib.packInts(values: { number }): { number }
	local out : { number } = table.create(#values, 0)
	for i, v in values do
		out[i] = bit32.band(math.floor(v), 0xFF)
	end
	return out
end

function CryptoLib.packU32(v: number): { number }
	v = bit32.band(math.floor(v), 0xFFFFFFFF)
	return {
		bit32.band(v,              0xFF),
		bit32.band(bit32.rshift(v,  8), 0xFF),
		bit32.band(bit32.rshift(v, 16), 0xFF),
		bit32.band(bit32.rshift(v, 24), 0xFF),
	}
end

function CryptoLib.unpackU32(b: { number }, offset: number): number
	local o : number = offset or 1
	return b[o]
		+ bit32.lshift(b[o + 1], 8)
		+ bit32.lshift(b[o + 2], 16)
		+ bit32.lshift(b[o + 3], 24)
end

return CryptoLib
