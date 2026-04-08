--!strict
--!optimize 2
--!native

local CryptoLib = {}

local HEADER1 = 0xAA
local HEADER2 = 0xBB

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
	local h = bit32.bxor(nonce, bit32.band(pos * 0x9E3779B9, 0xFFFFFFFF))
	for i = 1, 16 do
		h = bit32.bxor(h, key[i] * (i * 0x01010101))
		h = fmix32(h)
	end
	return bit32.band(h, 0xFF)
end

function CryptoLib.generateKey(): { number }
	local rng = Random.new()
	local k = table.create(16, 0)
	for i = 1, 16 do
		k[i] = rng:NextInteger(0, 255)
	end
	local allZero = true
	for i = 1, 16 do if k[i] ~= 0 then allZero = false break end end
	if allZero then
		k[1] = 1
		k[2] = 2
	end
	return k
end

function CryptoLib.encode(
	plainBytes : { number },
	key        : { number },
	nonce      : number
): { nonce: number, cs: number, data: { number } }
	-- Insere cabeçalho fixo no início do payload
	local withHeader = table.create(#plainBytes + 2, 0)
	withHeader[1] = HEADER1
	withHeader[2] = HEADER2
	for i = 1, #plainBytes do
		withHeader[i + 2] = plainBytes[i]
	end

	local n = #withHeader
	local data = table.create(n, 0)

	local cs = nonce
	for i = 1, n do
		local kb = keystreamByte(key, nonce, i - 1)
		local enc = bit32.bxor(withHeader[i], kb)
		data[i] = enc
		cs = bit32.bxor(cs, bit32.band(enc * bit32.band(i * 0x9E3779B9, 0xFFFFFFFF), 0xFFFFFFFF))
	end
	cs = fmix32(cs)

	for i = 1, 16 do
		cs = bit32.bxor(cs, key[i])
		cs = fmix32(cs)
	end

	return { nonce = nonce, cs = cs, data = data }
end

function CryptoLib.decode(
	packet    : { nonce: number, cs: number, data: { number } },
	key       : { number },
	lastNonce : number
): { number }?
	local nonce = packet.nonce
	local cs    = packet.cs
	local data  = packet.data

	if nonce <= lastNonce then return nil end

	local n = #data
	local plain = table.create(n, 0)

	local csCheck = nonce
	for i = 1, n do
		csCheck = bit32.bxor(csCheck, bit32.band(data[i] * bit32.band(i * 0x9E3779B9, 0xFFFFFFFF), 0xFFFFFFFF))
	end
	csCheck = fmix32(csCheck)

	for i = 1, 16 do
		csCheck = bit32.bxor(csCheck, key[i])
		csCheck = fmix32(csCheck)
	end

	if csCheck ~= cs then return nil end

	for i = 1, n do
		plain[i] = bit32.bxor(data[i], keystreamByte(key, nonce, i - 1))
	end

	-- Verifica o cabeçalho fixo
	if n < 2 or plain[1] ~= HEADER1 or plain[2] ~= HEADER2 then
		return nil
	end

	-- Remove o cabeçalho e retorna o payload original
	local result = table.create(n - 2, 0)
	for i = 3, n do
		result[i - 2] = plain[i]
	end
	return result
end

function CryptoLib.packInts(values: { number }): { number }
	local out = table.create(#values, 0)
	for i, v in values do
		out[i] = bit32.band(math.floor(v), 0xFF)
	end
	return out
end

function CryptoLib.packU32(v: number): { number }
	v = bit32.band(math.floor(v), 0xFFFFFFFF)
	return {
		bit32.band(v, 0xFF),
		bit32.band(bit32.rshift(v, 8), 0xFF),
		bit32.band(bit32.rshift(v, 16), 0xFF),
		bit32.band(bit32.rshift(v, 24), 0xFF),
	}
end

function CryptoLib.unpackU32(b: { number }, offset: number): number
	local o = offset or 1
	return b[o]
		+ bit32.lshift(b[o + 1], 8)
		+ bit32.lshift(b[o + 2], 16)
		+ bit32.lshift(b[o + 3], 24)
end

return CryptoLib
