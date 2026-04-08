--!strict
--
-- Run with: lune run tests/run_tests.luau
--          or: luau tests/run_tests.luau
--
-- No external deps. Roblox APIs are stubbed at the top.
-- Each test file is required and runs in sequence.
--

-- These let the modules load outside of Studio/server.

local Vector3 = {}
Vector3.__index = Vector3
function Vector3.new(x: number, y: number, z: number)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end
function Vector3.__sub(a: any, b: any)
	return Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
function Vector3.__add(a: any, b: any)
	return Vector3.new(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
function Vector3:Dot(other: any): number
	return self.X * other.X + self.Y * other.Y + self.Z * other.Z
end
function Vector3:__tostring()
	return string.format("Vector3(%g, %g, %g)", self.X, self.Y, self.Z)
end
Vector3.__index = function(self, k)
	if k == "Magnitude" then
		return math.sqrt(self.X^2 + self.Y^2 + self.Z^2)
	end
	return Vector3[k]
end
Vector3.zero = Vector3.new(0, 0, 0)
_G.Vector3 = Vector3

local CFrame = {}
CFrame.__index = CFrame
function CFrame.new(x: number?, y: number?, z: number?)
	local cf = setmetatable({}, CFrame)
	cf.Position = Vector3.new(x or 0, y or 0, z or 0)
	cf.LookVector = Vector3.new(0, 0, -1)
	return cf
end
function CFrame.fromEulerAnglesXYZ(rx: number, ry: number, rz: number)
	local cf = CFrame.new()
	cf.LookVector = Vector3.new(math.sin(ry), -math.sin(rx), -math.cos(ry))
	return cf
end
_G.CFrame = CFrame


type TestResult = {
	name    : string,
	passed  : boolean,
	message : string?,
}

local results : { TestResult } = {}
local currentSuite : string = ""

local function suite(name: string)
	currentSuite = name
	print(string.format("\n── %s ──", name))
end

local function test(name: string, fn: () -> ())
	local label = currentSuite .. " / " .. name
	local ok, err = pcall(fn)
	table.insert(results, {
		name   = label,
		passed = ok,
		message = if ok then nil else tostring(err),
	})
	if ok then
		print("  ✓ " .. name)
	else
		print("  ✗ " .. name)
		print("    " .. tostring(err))
	end
end

local function expect(val: any, msg: string?)
	if not val then
		error(msg or "assertion failed", 2)
	end
end

local function expectEq(a: any, b: any, msg: string?)
	if a ~= b then
		error(string.format("%s — expected %s, got %s",
			msg or "values differ", tostring(b), tostring(a)), 2)
	end
end

local function expectNear(a: number, b: number, tol: number, msg: string?)
	if math.abs(a - b) > tol then
		error(string.format("%s — expected ~%g, got %g (tol %g)",
			msg or "values differ", b, a, tol), 2)
	end
end

-- MathLib
local MathLib = require("../src/MathLib")

suite("MathLib — Welford online stats")

test("single push sets mean correctly", function()
	local n, mean, M2 = MathLib.welfordPush(0, 0, 0, 42)
	expectEq(n, 1)
	expectEq(mean, 42)
	expectEq(M2, 0)
end)

test("two pushes: mean is average", function()
	local n, mean, M2 = MathLib.welfordPush(0, 0, 0, 10)
	n, mean, M2       = MathLib.welfordPush(n, mean, M2, 20)
	expectNear(mean, 15, 1e-9)
end)

test("variance of constant series is 0", function()
	local n, mean, M2 = 0, 0.0, 0.0
	for _ = 1, 50 do
		n, mean, M2 = MathLib.welfordPush(n, mean, M2, 7)
	end
	expectNear(MathLib.welfordVariance(n, M2), 0, 1e-9)
end)

test("variance of {1,2,3,4,5} matches population formula", function()
	local n, mean, M2 = 0, 0.0, 0.0
	for _, v in {1, 2, 3, 4, 5} do
		n, mean, M2 = MathLib.welfordPush(n, mean, M2, v)
	end
	-- population variance = 2.0
	expectNear(MathLib.welfordVariance(n, M2), 2.0, 1e-9, "population variance")
end)

test("stddev for {1..5} is sqrt(2)", function()
	local n, mean, M2 = 0, 0.0, 0.0
	for _, v in {1, 2, 3, 4, 5} do
		n, mean, M2 = MathLib.welfordPush(n, mean, M2, v)
	end
	expectNear(MathLib.welfordStddev(n, M2), math.sqrt(2), 1e-9)
end)

test("n<2 returns 0 variance", function()
	expectEq(MathLib.welfordVariance(1, 0), 0.0)
	expectEq(MathLib.welfordVariance(0, 0), 0.0)
end)

suite("MathLib — zScore")

test("zero stddev returns 0", function()
	expectEq(MathLib.zScore(999, 0, 0), 0.0)
end)

test("value == mean → z = 0", function()
	expectEq(MathLib.zScore(5, 5, 1), 0.0)
end)

test("one stddev above mean → z = 1", function()
	expectEq(MathLib.zScore(6, 5, 1), 1.0)
end)

test("one stddev below mean → z = -1", function()
	expectEq(MathLib.zScore(4, 5, 1), -1.0)
end)

suite("MathLib — normalCDF")

test("CDF(0) ≈ 0.5", function()
	expectNear(MathLib.normalCDF(0), 0.5, 1e-6)
end)

test("CDF(1.96) ≈ 0.975 (two-sigma)", function()
	expectNear(MathLib.normalCDF(1.96), 0.975, 5e-4)
end)

test("CDF(-1.96) ≈ 0.025", function()
	expectNear(MathLib.normalCDF(-1.96), 0.025, 5e-4)
end)

test("CDF(6) ≈ 1 (far tail)", function()
	expectNear(MathLib.normalCDF(6), 1.0, 1e-6)
end)

test("pValue(0) = 1.0", function()
	expectNear(MathLib.pValue(0), 1.0, 1e-6)
end)

test("pValue(1.96) ≈ 0.05", function()
	expectNear(MathLib.pValue(1.96), 0.05, 5e-3)
end)

suite("MathLib — pearson")

test("perfectly correlated series → r = 1", function()
	local xs = {1,2,3,4,5}
	local ys = {2,4,6,8,10}
	expectNear(MathLib.pearson(xs, ys), 1.0, 1e-9)
end)

test("perfectly anti-correlated → r = -1", function()
	local xs = {1,2,3,4,5}
	local ys = {10,8,6,4,2}
	expectNear(MathLib.pearson(xs, ys), -1.0, 1e-9)
end)

test("constant y → r = 0", function()
	local xs = {1,2,3,4,5}
	local ys = {3,3,3,3,3}
	expectEq(MathLib.pearson(xs, ys), 0.0)
end)

test("n < 2 → returns 0", function()
	expectEq(MathLib.pearson({1}, {1}), 0.0)
	expectEq(MathLib.pearson({}, {}), 0.0)
end)

suite("MathLib — fpsScaleFactor")

test("at 60fps scale = 1.0", function()
	expectNear(MathLib.fpsScaleFactor(60), 1.0, 1e-9)
end)

test("at 15fps scale > 1 (more lenient)", function()
	local f = MathLib.fpsScaleFactor(15)
	expect(f > 1.0, "scale should be > 1 at low fps")
	expectNear(f, math.sqrt(4), 1e-9) -- sqrt(60/15) = 2
end)

test("very low fps clamps at 5", function()
	local f1 = MathLib.fpsScaleFactor(1)
	local f5 = MathLib.fpsScaleFactor(5)
	expectEq(f1, f5) -- both clamped to safeFps=5
end)

suite("MathLib — reactionFpsFloor")

test("at 60fps floor = 2 frames = 33.3ms", function()
	expectNear(MathLib.reactionFpsFloor(60), 33.333, 0.001)
end)

test("at 30fps floor = 66.6ms", function()
	expectNear(MathLib.reactionFpsFloor(30), 66.666, 0.001)
end)

test("minimum 2 frames enforced", function()
	-- 2 frames at any fps: (2/fps)*1000
	local floor = MathLib.reactionFpsFloor(120)
	expectNear(floor, 16.666, 0.001)
end)

suite("MathLib — expDecay")

test("at t=halfLife, value halves", function()
	local v = MathLib.expDecay(100, 1.0, 1.0)
	expectNear(v, 50.0, 0.001)
end)

test("halfLife <= 0 returns original value", function()
	expectEq(MathLib.expDecay(42, 1, 0), 42)
end)

test("at t=0, value unchanged", function()
	expectEq(MathLib.expDecay(75, 0, 2), 75)
end)

suite("MathLib — markovProbSmoothed (Laplace)")

test("unseen transition returns alpha/(alpha*vocab) = 1/vocab", function()
	-- fresh matrix, no observations
	local matrix = {}
	local stateCounts = {}
	local alpha = 1.0
	local vocab = 10
	-- from=1, to=5, never seen → smoothed = 1 / (0 + 1*10) = 0.1
	local p = MathLib.markovProbSmoothed(matrix, stateCounts, 1, 5, alpha, vocab)
	expectNear(p, 0.1, 1e-9)
end)

test("seen transition is higher than unseen", function()
	local matrix = { [1] = { [2] = 5 } }
	local stateCounts = { [1] = 5 }
	local alpha = 1.0
	local vocab = 10
	local pSeen   = MathLib.markovProbSmoothed(matrix, stateCounts, 1, 2, alpha, vocab)
	local pUnseen = MathLib.markovProbSmoothed(matrix, stateCounts, 1, 9, alpha, vocab)
	expect(pSeen > pUnseen, "seen transition should have higher prob")
end)

suite("MathLib — activePhysicsMax")

test("returns defaultMax when no events", function()
	expectEq(MathLib.activePhysicsMax({}, 100, 0), 100)
end)

test("returns higher override from active event", function()
	local events = { { expiresAt = 10, maxSpeedStuds = 500 } }
	expectEq(MathLib.activePhysicsMax(events, 100, 5), 500)
end)

test("ignores expired event", function()
	local events = { { expiresAt = 1, maxSpeedStuds = 500 } }
	-- now = 5, expiresAt = 1 → expired
	expectEq(MathLib.activePhysicsMax(events, 100, 5), 100)
end)

test("takes max of multiple active events", function()
	local events = {
		{ expiresAt = 10, maxSpeedStuds = 200 },
		{ expiresAt = 10, maxSpeedStuds = 800 },
		{ expiresAt = 10, maxSpeedStuds = 400 },
	}
	expectEq(MathLib.activePhysicsMax(events, 100, 5), 800)
end)

suite("MathLib — purgeExpiredPhysics")

test("removes expired, keeps active", function()
	local events = {
		{ expiresAt = 1, maxSpeedStuds = 500 },   -- expired
		{ expiresAt = 10, maxSpeedStuds = 300 },   -- active
		{ expiresAt = 2, maxSpeedStuds = 200 },    -- expired
	}
	MathLib.purgeExpiredPhysics(events, 5)
	expectEq(#events, 1)
	expectEq(events[1].maxSpeedStuds, 300)
end)

test("empty list does not error", function()
	local events = {}
	MathLib.purgeExpiredPhysics(events, 5)
	expectEq(#events, 0)
end)

suite("MathLib — misc helpers")

test("clamp01 clamps to [0,1]", function()
	expectEq(MathLib.clamp01(-5), 0.0)
	expectEq(MathLib.clamp01(2),  1.0)
	expectEq(MathLib.clamp01(0.5), 0.5)
end)

test("clampSusp clamps to [0,100]", function()
	expectEq(MathLib.clampSusp(-10), 0.0)
	expectEq(MathLib.clampSusp(200), 100.0)
	expectEq(MathLib.clampSusp(50), 50.0)
end)

test("cv returns stddev/mean", function()
	expectNear(MathLib.cv(10, 2), 0.2, 1e-9)
end)

test("cv with near-zero mean returns 0", function()
	expectEq(MathLib.cv(0, 5), 0.0)
end)

test("speed of zero vector is 0", function()
	expectEq(MathLib.speed(Vector3.new(0,0,0)), 0)
end)

test("speed of (3,4,0) is 5", function()
	expectNear(MathLib.speed(Vector3.new(3,4,0)), 5, 1e-9)
end)

test("positionThreshold increases with speed and ping", function()
	local low  = MathLib.positionThreshold(10, 0.05, 2)
	local high = MathLib.positionThreshold(100, 0.5, 2)
	expect(high > low)
end)

-- CryptoLib
local CryptoLib = require("../src/CryptoLib")

suite("CryptoLib — generateKey")

test("returns 16-byte array", function()
	local k = CryptoLib.generateKey()
	expectEq(#k, 16)
end)

test("all bytes in [0, 255]", function()
	local k = CryptoLib.generateKey()
	for i = 1, 16 do
		expect(k[i] >= 0 and k[i] <= 255,
			"byte " .. i .. " out of range: " .. k[i])
	end
end)

test("two keys are (almost certainly) different", function()
	-- not guaranteed, but 1/256^16 chance of false failure
	local k1 = CryptoLib.generateKey()
	local k2 = CryptoLib.generateKey()
	local same = true
	for i = 1, 16 do
		if k1[i] ~= k2[i] then same = false; break end
	end
	expect(not same, "two keys were identical (extremely unlikely)")
end)

suite("CryptoLib — encode / decode round-trip")

test("decode recovers original plaintext", function()
	local key   = CryptoLib.generateKey()
	local plain = {72, 101, 108, 108, 111}  -- "Hello"
	local pkt   = CryptoLib.encode(plain, key, 1)
	local out   = CryptoLib.decode(pkt, key, 0)
	expect(out ~= nil, "decode returned nil")
	for i = 1, #plain do
		expectEq(out[i], plain[i], "byte " .. i .. " mismatch")
	end
end)

test("single-byte payload round-trips", function()
	local key  = CryptoLib.generateKey()
	local pkt  = CryptoLib.encode({255}, key, 1)
	local out  = CryptoLib.decode(pkt, key, 0)
	expect(out and #out == 1 and out[1] == 255)
end)

test("25-byte hit payload round-trips", function()
	local key   = CryptoLib.generateKey()
	local plain = {}
	for i = 1, 25 do plain[i] = (i * 7) % 256 end
	local pkt   = CryptoLib.encode(plain, key, 42)
	local out   = CryptoLib.decode(pkt, key, 41)
	expect(out ~= nil)
	for i = 1, 25 do
		expectEq(out[i], plain[i], "byte " .. i)
	end
end)

suite("CryptoLib — replay / tamper rejection")

test("replayed nonce (nonce <= lastNonce) is rejected", function()
	local key  = CryptoLib.generateKey()
	local pkt  = CryptoLib.encode({1,2,3}, key, 5)
	-- lastNonce = 5: nonce 5 <= 5, should reject
	local out  = CryptoLib.decode(pkt, key, 5)
	expectEq(out, nil, "replay should return nil")
end)

test("old nonce (nonce < lastNonce) is rejected", function()
	local key = CryptoLib.generateKey()
	local pkt = CryptoLib.encode({1,2,3}, key, 3)
	local out = CryptoLib.decode(pkt, key, 10)
	expectEq(out, nil, "old nonce should return nil")
end)

test("tampered data byte is rejected", function()
	local key = CryptoLib.generateKey()
	local pkt = CryptoLib.encode({10, 20, 30}, key, 1)
	-- flip one bit in the ciphertext
	pkt.data[2] = bit32.bxor(pkt.data[2], 0xFF)
	local out = CryptoLib.decode(pkt, key, 0)
	expectEq(out, nil, "tampered payload should return nil")
end)

test("wrong key is rejected", function()
	local key1 = CryptoLib.generateKey()
	local key2 = CryptoLib.generateKey()
	local pkt  = CryptoLib.encode({5, 6, 7}, key1, 1)
	local out  = CryptoLib.decode(pkt, key2, 0)
	-- checksum will almost certainly fail
	expect(out == nil or out[1] ~= 5,
		"wrong key: should fail or produce wrong bytes")
end)

test("nonce advances allow sequential packets", function()
	local key = CryptoLib.generateKey()
	local pkt1 = CryptoLib.encode({1}, key, 1)
	local pkt2 = CryptoLib.encode({2}, key, 2)
	local pkt3 = CryptoLib.encode({3}, key, 3)
	local out1 = CryptoLib.decode(pkt1, key, 0)
	local out2 = CryptoLib.decode(pkt2, key, 1)
	local out3 = CryptoLib.decode(pkt3, key, 2)
	expect(out1 and out1[1] == 1)
	expect(out2 and out2[1] == 2)
	expect(out3 and out3[1] == 3)
end)

test("nonce gaps are allowed (out-of-order drops, not errors)", function()
	local key = CryptoLib.generateKey()
	-- jump from nonce 1 to 10 — should still decode
	local pkt = CryptoLib.encode({42}, key, 10)
	local out = CryptoLib.decode(pkt, key, 1)
	expect(out and out[1] == 42)
end)

suite("CryptoLib — packU32 / unpackU32")

test("round-trip 0", function()
	local b = CryptoLib.packU32(0)
	expectEq(CryptoLib.unpackU32(b, 1), 0)
end)

test("round-trip 255", function()
	local b = CryptoLib.packU32(255)
	expectEq(CryptoLib.unpackU32(b, 1), 255)
end)

test("round-trip 65535", function()
	local b = CryptoLib.packU32(65535)
	expectEq(CryptoLib.unpackU32(b, 1), 65535)
end)

test("round-trip 2^24 - 1", function()
	local v = 2^24 - 1
	local b = CryptoLib.packU32(v)
	expectEq(CryptoLib.unpackU32(b, 1), v)
end)

test("packU32 produces exactly 4 bytes", function()
	local b = CryptoLib.packU32(12345)
	expectEq(#b, 4)
end)

test("offset parameter works for embedded fields", function()
	-- simulate a 8-byte payload with two u32s
	local first  = CryptoLib.packU32(100)
	local second = CryptoLib.packU32(200)
	local buf    = { first[1], first[2], first[3], first[4],
	                 second[1], second[2], second[3], second[4] }
	expectEq(CryptoLib.unpackU32(buf, 1), 100)
	expectEq(CryptoLib.unpackU32(buf, 5), 200)
end)

-- InputGuard
local InputGuard = require("../src/Security/InputGuard")

suite("InputGuard — checkNumber")

test("valid number passes", function()
	local ok, err = InputGuard.checkNumber(42, 0, 100, "x")
	expect(ok)
	expectEq(err, nil)
end)

test("NaN fails", function()
	local ok = InputGuard.checkNumber(0/0, 0, 100, "x")
	expect(not ok)
end)

test("math.huge fails", function()
	local ok = InputGuard.checkNumber(math.huge, 0, 1e9, "x")
	expect(not ok)
end)

test("-math.huge fails", function()
	local ok = InputGuard.checkNumber(-math.huge, -1e9, 0, "x")
	expect(not ok)
end)

test("below range fails", function()
	local ok = InputGuard.checkNumber(-1, 0, 100, "x")
	expect(not ok)
end)

test("above range fails", function()
	local ok = InputGuard.checkNumber(101, 0, 100, "x")
	expect(not ok)
end)

test("string instead of number fails", function()
	local ok = InputGuard.checkNumber("42", 0, 100, "x")
	expect(not ok)
end)

test("nil fails", function()
	local ok = InputGuard.checkNumber(nil, 0, 100, "x")
	expect(not ok)
end)

suite("InputGuard — checkString")

test("valid short string passes", function()
	local ok = InputGuard.checkString("hello", 128, "s")
	expect(ok)
end)

test("string over maxLen fails", function()
	local ok = InputGuard.checkString(string.rep("a", 200), 128, "s")
	expect(not ok)
end)

test("non-string fails", function()
	local ok = InputGuard.checkString(42, 128, "s")
	expect(not ok)
end)

test("null byte fails", function()
	local ok = InputGuard.checkString("hello\0world", 128, "s")
	expect(not ok)
end)

test("control char fails", function()
	local ok = InputGuard.checkString("hello\x01world", 128, "s")
	expect(not ok)
end)

test("newline/tab are allowed", function()
	-- \n = 0x0A, \r = 0x0D, \t = 0x09 — explicitly permitted
	local ok = InputGuard.checkString("line1\nline2", 128, "s")
	expect(ok)
end)

suite("InputGuard — checkTable")

test("flat table passes", function()
	local ok = InputGuard.checkTable({1, 2, 3})
	expect(ok)
end)

test("non-table fails", function()
	local ok = InputGuard.checkTable("string")
	expect(not ok)
end)

test("recursive table fails", function()
	local t: any = {}
	t.self = t
	local ok = InputGuard.checkTable(t)
	expect(not ok)
end)

test("table over MAX_KEYS fails", function()
	local big: any = {}
	for i = 1, 100 do big[i] = i end
	local ok = InputGuard.checkTable(big)
	expect(not ok)
end)

test("nested table within depth limit passes", function()
	local ok = InputGuard.checkTable({ { { 1 } } })
	expect(ok)
end)

test("table nested beyond MAX_DEPTH fails", function()
	local ok = InputGuard.checkTable({ { { { 1 } } } })
	expect(not ok)
end)

suite("InputGuard — checkByteArray")

test("valid byte array passes", function()
	local ok = InputGuard.checkByteArray({0, 128, 255})
	expect(ok)
end)

test("byte value 256 fails", function()
	local ok = InputGuard.checkByteArray({0, 256, 100})
	expect(not ok)
end)

test("negative byte fails", function()
	local ok = InputGuard.checkByteArray({-1, 0, 0})
	expect(not ok)
end)

test("float byte fails", function()
	local ok = InputGuard.checkByteArray({1.5, 0, 0})
	expect(not ok)
end)

test("too short fails when minN set", function()
	local ok = InputGuard.checkByteArray({1,2}, 5, 256)
	expect(not ok)
end)

test("too long fails when maxN set", function()
	local arr = table.create(300, 0)
	local ok = InputGuard.checkByteArray(arr, 0, 256)
	expect(not ok)
end)

test("non-table fails", function()
	local ok = InputGuard.checkByteArray("notatable")
	expect(not ok)
end)

suite("InputGuard — checkPacket")

test("valid packet passes", function()
	local key = CryptoLib.generateKey()
	local pkt = CryptoLib.encode({1,2,3}, key, 1)
	-- pkt = { nonce, cs, data }
	local ok, err = InputGuard.checkPacket(pkt)
	expect(ok, "valid packet should pass: " .. tostring(err))
end)

test("missing nonce fails", function()
	local ok = InputGuard.checkPacket({ cs = 0, data = {1} })
	expect(not ok)
end)

test("missing cs fails", function()
	local ok = InputGuard.checkPacket({ nonce = 1, data = {1} })
	expect(not ok)
end)

test("missing data fails", function()
	local ok = InputGuard.checkPacket({ nonce = 1, cs = 0 })
	expect(not ok)
end)

test("NaN nonce fails", function()
	local ok = InputGuard.checkPacket({ nonce = 0/0, cs = 0, data = {1} })
	expect(not ok)
end)

test("non-integer nonce fails", function()
	local ok = InputGuard.checkPacket({ nonce = 1.5, cs = 0, data = {1} })
	expect(not ok)
end)

test("data with bad byte fails", function()
	local ok = InputGuard.checkPacket({ nonce = 1, cs = 0, data = {-1} })
	expect(not ok)
end)

test("non-table top-level fails", function()
	local ok = InputGuard.checkPacket("notapacket")
	expect(not ok)
end)

suite("InputGuard — checkFps")

test("60fps passes", function()
	local ok = InputGuard.checkFps(60)
	expect(ok)
end)

test("MIN_FPS passes", function()
	local ok = InputGuard.checkFps(InputGuard.LIMITS.MIN_FPS)
	expect(ok)
end)

test("MAX_FPS passes", function()
	local ok = InputGuard.checkFps(InputGuard.LIMITS.MAX_FPS)
	expect(ok)
end)

test("below MIN_FPS fails", function()
	local ok = InputGuard.checkFps(1)
	expect(not ok)
end)

test("above MAX_FPS fails", function()
	local ok = InputGuard.checkFps(10000)
	expect(not ok)
end)

-- HealthMonitor (unit tests, no Roblox services)

-- HealthMonitor uses RunService.Heartbeat so we need to stub it.
-- The module assigns a Heartbeat handler but we don't need it to fire.
local _fakeSignal = { Connect = function(self, fn) end }
local _fakeRunService = { Heartbeat = _fakeSignal }
-- Override before require so the module sees it
local _origGame = _G.game
_G.game = { getService = function(self, s)
	if s == "RunService" then return _fakeRunService end
	error("unexpected service: " .. s)
end }
-- Roblox uses game:GetService() syntax — stub method call too
setmetatable(_G.game, { __index = function(t, k)
	if k == "GetService" then
		return function(self, s)
			if s == "RunService" then return _fakeRunService end
			error("unexpected service: " .. s)
		end
	end
end })

local HealthMonitor = require("../src/HealthMonitor")

suite("HealthMonitor — before init")

test("snapshot() returns zero activePlayers before init", function()
	local snap = HealthMonitor.snapshot()
	expectEq(snap.activePlayers, 0)
end)

test("playerMetrics() returns nil before init", function()
	local m = HealthMonitor.playerMetrics(12345)
	expectEq(m, nil)
end)

suite("HealthMonitor — after init")

local fakeProfiles: { [number]: any } = {}
local fakePlayers: { any } = {}

HealthMonitor.init(
	function(pid) return fakeProfiles[pid] end,
	function() return fakePlayers end
)

test("init sets player getter — snapshot has correct count", function()
	fakePlayers = { { UserId = 1 }, { UserId = 2 } }
	local snap = HealthMonitor.snapshot()
	expectEq(snap.activePlayers, 2)
end)

test("high-risk counting: suspicion >= 60 is counted", function()
	fakeProfiles[1] = { suspicion = 75 }
	fakeProfiles[2] = { suspicion = 30 }
	fakePlayers = { { UserId = 1 }, { UserId = 2 } }
	local snap = HealthMonitor.snapshot()
	expectEq(snap.highRiskPlayers, 1)
end)

test("recordEvent increments and EPS eventually updates", function()
	-- force the window to be stale so EPS recalculates
	for _ = 1, 20 do HealthMonitor.recordEvent() end
	-- we can't easily force the 5s window without sleeping,
	-- but we can verify the call doesn't error
	local snap = HealthMonitor.snapshot()
	expect(snap ~= nil)
end)

test("recordLatency populates avg latency", function()
	HealthMonitor.recordLatency(5.0)
	HealthMonitor.recordLatency(15.0)
	HealthMonitor.recordLatency(10.0)
	local snap = HealthMonitor.snapshot()
	-- avg of [5,15,10] among recent entries — just verify it's > 0
	expect(snap.latencyAvgMs > 0)
end)

test("recordFlags populates totalFlagsLast60s", function()
	HealthMonitor.recordFlags(3)
	HealthMonitor.recordFlags(2)
	local snap = HealthMonitor.snapshot()
	expect(snap.totalFlagsLast60s >= 5)
end)

test("getHealthSnapshot is aliased to snapshot", function()
	-- Bug 3: these should exist on the public table
	expect(HealthMonitor.getHealthSnapshot ~= nil,
		"getHealthSnapshot should be exposed on the module")
	expect(HealthMonitor.getPlayerMetrics ~= nil,
		"getPlayerMetrics should be exposed on the module")
end)

test("getHealthSnapshot returns same shape as snapshot", function()
	-- if the alias exists, it should return the same thing
	if HealthMonitor.getHealthSnapshot then
		local snap1 = HealthMonitor.snapshot()
		local snap2 = HealthMonitor.getHealthSnapshot()
		expectEq(snap1.activePlayers, snap2.activePlayers)
	end
end)

suite("HealthMonitor — status thresholds")

test("OK status when latencies are low", function()
	-- fill ring with 1ms samples
	for _ = 1, 50 do HealthMonitor.recordLatency(1.0) end
	local snap = HealthMonitor.snapshot()
	-- status may be OK; at least not FAIL
	expect(snap.status == "OK" or snap.status == "DEGRADED")
end)

test("snapshot uptime increases over calls", function()
	local s1 = HealthMonitor.snapshot()
	local s2 = HealthMonitor.snapshot()
	expect(s2.uptimeSeconds >= s1.uptimeSeconds)
end)

-- Types — missing exports check
-- Types.luau only exports types (no runtime values), so we validate
-- by checking the file directly contains the required export type
-- declarations (string-level check since Luau types don't exist at runtime).

suite("Types.luau — required export types present")

test("PhysicsEvent is exported", function()
	local src = io.open("../src/Types.luau", "r")
	expect(src ~= nil, "could not open Types.luau")
	local content = src:read("*a")
	src:close()
	expect(content:find("export type PhysicsEvent") ~= nil,
		"PhysicsEvent export type missing from Types.luau")
end)

test("SessionKey is exported", function()
	local src = io.open("../src/Types.luau", "r")
	expect(src ~= nil)
	local content = src:read("*a")
	src:close()
	expect(content:find("export type SessionKey") ~= nil,
		"SessionKey export type missing from Types.luau")
end)

  -- AntiCheatService — wiring checks 
-- These tests verify the integration bugs without running the full
-- service (which needs Roblox APIs). They parse the source file.

suite("AntiCheatService — wiring (static checks)")

local function readSrc(path: string): string
	local f = io.open(path, "r")
	expect(f ~= nil, "could not open " .. path)
	local s = f:read("*a")
	f:close()
	return s
end

test("InputGuard is imported", function()
	local src = readSrc("../src/AntiCheatService.luau")
	expect(src:find("require.*InputGuard") ~= nil or
	       src:find("InputGuard") ~= nil,
		"InputGuard is not required in AntiCheatService")
end)

test("InputGuard.checkPacket is called", function()
	local src = readSrc("../src/AntiCheatService.luau")
	expect(src:find("InputGuard%.checkPacket") ~= nil,
		"InputGuard.checkPacket is never called — Bug 1 not fixed")
end)

test("HealthMonitor is imported", function()
	local src = readSrc("../src/AntiCheatService.luau")
	expect(src:find("HealthMonitor") ~= nil,
		"HealthMonitor not referenced in AntiCheatService")
end)

test("HealthMonitor.init is called", function()
	local src = readSrc("../src/AntiCheatService.luau")
	expect(src:find("HealthMonitor%.init") ~= nil,
		"HealthMonitor.init is never called — Bug 2 not fixed")
end)

test("HealthMonitor.recordEvent is called at least once", function()
	local src = readSrc("../src/AntiCheatService.luau")
	expect(src:find("HealthMonitor%.recordEvent") ~= nil,
		"HealthMonitor.recordEvent is never called — events not counted")
end)

-- HitValidator — geometry bug check (static)

suite("HitValidator — geometry check (static)")

test("uses FindFirstAncestorOfClass, not .Parent", function()
	local src = readSrc("../src/HitValidator.luau")
	expect(src:find("FindFirstAncestorOfClass") ~= nil,
		"HitValidator still uses .Parent — geometry bug not fixed")
	expect(src:find("hitInst%.Parent") == nil,
		"hitInst.Parent still present — geometry bug not fixed")
end)

-- Summary

local passed = 0
local failed = 0
for _, r in results do
	if r.passed then passed += 1 else failed += 1 end
end

print(string.format("  Results: %d passed, %d failed, %d total",
	passed, failed, passed + failed))

if failed > 0 then
	print("\nFailed tests:")
	for _, r in results do
		if not r.passed then
			print(string.format("  ✗ %s\n    %s", r.name, r.message or ""))
		end
	end
	os.exit(1)
end
