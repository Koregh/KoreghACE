-- (ModuleScript)
return function()
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local src        = ReplicatedStorage.Shared
	local MathLib    = require(src.MathLib)
	local CryptoLib  = require(src.CryptoLib)
	local InputGuard = require(src.Security.InputGuard)
	local HealthMon  = require(src.HealthMonitor)

	local function near(a, b, tol, msg)
		if math.abs(a - b) > tol then
			error(string.format("%s — got %.10g, want %.10g (tol %g)",
				msg or "near", a, b, tol), 2)
		end
	end

	describe("MathLib", function()
		describe("welford", function()
			it("single push sets mean", function()
				local n, m, M2 = MathLib.welfordPush(0, 0, 0, 42)
				expect(n).to.equal(1)
				expect(m).to.equal(42)
				expect(M2).to.equal(0)
			end)
			it("two pushes: mean is average", function()
				local n, m, M2 = MathLib.welfordPush(0, 0, 0, 10)
				n, m, M2 = MathLib.welfordPush(n, m, M2, 20)
				near(m, 15, 1e-9)
			end)
			it("variance of constant series is 0", function()
				local n, m, M2 = 0, 0.0, 0.0
				for _ = 1, 50 do n, m, M2 = MathLib.welfordPush(n, m, M2, 7) end
				near(MathLib.welfordVariance(n, M2), 0, 1e-9)
			end)
			it("variance of {1,2,3,4,5} = 2 (population)", function()
				local n, m, M2 = 0, 0.0, 0.0
				for _, v in {1,2,3,4,5} do n, m, M2 = MathLib.welfordPush(n, m, M2, v) end
				near(MathLib.welfordVariance(n, M2), 2.0, 1e-9)
			end)
			it("stddev of {1,2,3,4,5} = sqrt(2)", function()
				local n, m, M2 = 0, 0.0, 0.0
				for _, v in {1,2,3,4,5} do n, m, M2 = MathLib.welfordPush(n, m, M2, v) end
				near(MathLib.welfordStddev(n, M2), math.sqrt(2), 1e-9)
			end)
			it("n < 2 returns variance = 0", function()
				expect(MathLib.welfordVariance(0, 0)).to.equal(0.0)
				expect(MathLib.welfordVariance(1, 0)).to.equal(0.0)
			end)
		end)

		describe("zScore", function()
			it("zero stddev returns 0",   function() expect(MathLib.zScore(999, 0, 0)).to.equal(0.0) end)
			it("value == mean returns 0", function() expect(MathLib.zScore(5, 5, 1)).to.equal(0.0) end)
			it("+1 stddev → z = 1",       function() expect(MathLib.zScore(6, 5, 1)).to.equal(1.0) end)
			it("-1 stddev → z = -1",      function() expect(MathLib.zScore(4, 5, 1)).to.equal(-1.0) end)
		end)

		describe("normalCDF", function()
			it("CDF(0) = 0.5",        function() near(MathLib.normalCDF(0),     0.5,   1e-6) end)
			it("CDF(1.96) = 0.975",   function() near(MathLib.normalCDF(1.96),  0.975, 5e-4) end)
			it("CDF(-1.96) = 0.025",  function() near(MathLib.normalCDF(-1.96), 0.025, 5e-4) end)
			it("CDF(6) ~ 1.0",        function() near(MathLib.normalCDF(6),     1.0,   1e-6) end)
			it("pValue(0) = 1.0",     function() near(MathLib.pValue(0),        1.0,   1e-6) end)
			it("pValue(1.96) ~ 0.05", function() near(MathLib.pValue(1.96),     0.05,  5e-3) end)
		end)

		describe("pearson", function()
			it("r=1 for perfectly correlated",  function() near(MathLib.pearson({1,2,3,4,5}, {2,4,6,8,10}),  1.0, 1e-9) end)
			it("r=-1 for anti-correlated",      function() near(MathLib.pearson({1,2,3,4,5}, {10,8,6,4,2}), -1.0, 1e-9) end)
			it("r=0 for constant Y",            function() expect(MathLib.pearson({1,2,3,4,5}, {3,3,3,3,3})).to.equal(0.0) end)
			it("n < 2 returns 0", function()
				expect(MathLib.pearson({1}, {1})).to.equal(0.0)
				expect(MathLib.pearson({}, {})).to.equal(0.0)
			end)
		end)

		describe("fpsScaleFactor", function()
			it("60fps = 1.0",        function() near(MathLib.fpsScaleFactor(60), 1.0, 1e-9) end)
			it("15fps = 2.0 (sqrt)", function() near(MathLib.fpsScaleFactor(15), 2.0, 1e-9) end)
			it("fps < 5 is clamped", function() expect(MathLib.fpsScaleFactor(1)).to.equal(MathLib.fpsScaleFactor(5)) end)
		end)

		describe("reactionFpsFloor", function()
			it("60fps = 33.3ms",  function() near(MathLib.reactionFpsFloor(60),  33.333, 0.001) end)
			it("30fps = 66.6ms",  function() near(MathLib.reactionFpsFloor(30),  66.666, 0.001) end)
			it("120fps = 16.6ms", function() near(MathLib.reactionFpsFloor(120), 16.666, 0.001) end)
		end)

		describe("expDecay", function()
			it("at t=halfLife value halves",     function() near(MathLib.expDecay(100, 1.0, 1.0), 50.0, 0.001) end)
			it("at t=0 value unchanged",         function() expect(MathLib.expDecay(75, 0, 2)).to.equal(75) end)
			it("halfLife <= 0 returns original", function() expect(MathLib.expDecay(42, 1, 0)).to.equal(42) end)
		end)

		describe("markovProbSmoothed", function()
			it("unseen = 1/vocab with alpha=1", function()
				near(MathLib.markovProbSmoothed({}, {}, 1, 5, 1.0, 10), 0.1, 1e-9)
			end)
			it("seen > unseen", function()
				local mat = { [1] = { [2] = 5 } }
				local sc  = { [1] = 5 }
				local pS  = MathLib.markovProbSmoothed(mat, sc, 1, 2, 1.0, 10)
				local pU  = MathLib.markovProbSmoothed(mat, sc, 1, 9, 1.0, 10)
				expect(pS > pU).to.equal(true)
			end)
		end)

		describe("activePhysicsMax", function()
			it("no events returns defaultMax",     function() expect(MathLib.activePhysicsMax({}, 100, 0)).to.equal(100) end)
			it("active event overrides default",   function() expect(MathLib.activePhysicsMax({{ expiresAt=10, maxSpeedStuds=500 }}, 100, 5)).to.equal(500) end)
			it("expired event is ignored",         function() expect(MathLib.activePhysicsMax({{ expiresAt=1,  maxSpeedStuds=500 }}, 100, 5)).to.equal(100) end)
			it("takes highest of multiple active", function()
				local evs = {
					{ expiresAt=10, maxSpeedStuds=200 },
					{ expiresAt=10, maxSpeedStuds=800 },
					{ expiresAt=10, maxSpeedStuds=400 },
				}
				expect(MathLib.activePhysicsMax(evs, 100, 5)).to.equal(800)
			end)
		end)

		describe("purgeExpiredPhysics", function()
			it("removes expired, keeps active", function()
				local evs = {
					{ expiresAt=1,  maxSpeedStuds=500 },
					{ expiresAt=10, maxSpeedStuds=300 },
					{ expiresAt=2,  maxSpeedStuds=200 },
				}
				MathLib.purgeExpiredPhysics(evs, 5)
				expect(#evs).to.equal(1)
				expect(evs[1].maxSpeedStuds).to.equal(300)
			end)
			it("empty list doesn't error", function()
				local evs = {}
				MathLib.purgeExpiredPhysics(evs, 5)
				expect(#evs).to.equal(0)
			end)
		end)

		describe("misc", function()
			it("clamp01 clamps to [0,1]", function()
				expect(MathLib.clamp01(-5)).to.equal(0.0)
				expect(MathLib.clamp01(2)).to.equal(1.0)
				expect(MathLib.clamp01(0.5)).to.equal(0.5)
			end)
			it("clampSusp clamps to [0,100]", function()
				expect(MathLib.clampSusp(-10)).to.equal(0.0)
				expect(MathLib.clampSusp(200)).to.equal(100.0)
			end)
			it("cv = stddev/mean",            function() near(MathLib.cv(10, 2), 0.2, 1e-9) end)
			it("cv near-zero mean returns 0", function() expect(MathLib.cv(0, 5)).to.equal(0.0) end)
			it("speed (0,0,0) = 0",           function() expect(MathLib.speed(Vector3.new(0,0,0))).to.equal(0) end)
			it("speed (3,4,0) = 5",           function() near(MathLib.speed(Vector3.new(3,4,0)), 5, 1e-9) end)
			it("positionThreshold grows with speed+ping", function()
				expect(MathLib.positionThreshold(100, 0.5, 2) > MathLib.positionThreshold(10, 0.05, 2)).to.equal(true)
			end)
		end)
	end)

	-- CryptoLib
	describe("CryptoLib", function()
		describe("generateKey", function()
			it("returns 16 bytes", function() expect(#CryptoLib.generateKey()).to.equal(16) end)
			it("all bytes in [0,255]", function()
				for _, b in CryptoLib.generateKey() do
					expect(b >= 0 and b <= 255).to.equal(true)
				end
			end)
			it("two keys differ", function()
				local k1, k2 = CryptoLib.generateKey(), CryptoLib.generateKey()
				local same = true
				for i = 1, 16 do if k1[i] ~= k2[i] then same = false; break end end
				expect(same).to.equal(false)
			end)
		end)

		describe("encode-decode round-trip", function()
			it("5-byte payload", function()
				local key   = CryptoLib.generateKey()
				local plain = {72, 101, 108, 108, 111}
				local out   = CryptoLib.decode(CryptoLib.encode(plain, key, 1), key, 0)
				expect(out ~= nil).to.equal(true)
				for i = 1, #plain do expect(out[i]).to.equal(plain[i]) end
			end)
			it("1-byte payload", function()
				local key = CryptoLib.generateKey()
				local out = CryptoLib.decode(CryptoLib.encode({255}, key, 1), key, 0)
				expect(out ~= nil and #out == 1 and out[1] == 255).to.equal(true)
			end)
			it("25-byte hit payload", function()
				local key, plain = CryptoLib.generateKey(), {}
				for i = 1, 25 do plain[i] = (i * 7) % 256 end
				local out = CryptoLib.decode(CryptoLib.encode(plain, key, 42), key, 41)
				expect(out ~= nil).to.equal(true)
				for i = 1, 25 do expect(out[i]).to.equal(plain[i]) end
			end)
		end)

		describe("replay + tamper", function()
			it("nonce == lastNonce rejected (replay)", function()
				local key = CryptoLib.generateKey()
				expect(CryptoLib.decode(CryptoLib.encode({1,2,3}, key, 5), key, 5)).to.equal(nil)
			end)
			it("nonce < lastNonce rejected", function()
				local key = CryptoLib.generateKey()
				expect(CryptoLib.decode(CryptoLib.encode({1,2,3}, key, 3), key, 10)).to.equal(nil)
			end)
			it("tampered byte rejected", function()
				local key = CryptoLib.generateKey()
				local pkt = CryptoLib.encode({10, 20, 30}, key, 1)
				pkt.data[2] = bit32.bxor(pkt.data[2], 0xFF)
				expect(CryptoLib.decode(pkt, key, 0)).to.equal(nil)
			end)
			it("wrong key rejected", function()
				local k1, k2 = CryptoLib.generateKey(), CryptoLib.generateKey()
				local out    = CryptoLib.decode(CryptoLib.encode({5,6,7}, k1, 1), k2, 0)
				expect(out == nil or out[1] ~= 5).to.equal(true)
			end)
			it("sequential nonces all succeed", function()
				local key = CryptoLib.generateKey()
				for i = 1, 5 do
					local out = CryptoLib.decode(CryptoLib.encode({i}, key, i), key, i-1)
					expect(out ~= nil and out[1] == i).to.equal(true)
				end
			end)
			it("nonce gap is allowed", function()
				local key = CryptoLib.generateKey()
				local out = CryptoLib.decode(CryptoLib.encode({42}, key, 10), key, 1)
				expect(out ~= nil and out[1] == 42).to.equal(true)
			end)
		end)

		describe("packU32 + unpackU32", function()
			local function rt(v) return CryptoLib.unpackU32(CryptoLib.packU32(v), 1) end
			it("round-trip 0",      function() expect(rt(0)).to.equal(0) end)
			it("round-trip 255",    function() expect(rt(255)).to.equal(255) end)
			it("round-trip 65535",  function() expect(rt(65535)).to.equal(65535) end)
			it("round-trip 2^24-1", function() expect(rt(2^24-1)).to.equal(2^24-1) end)
			it("produces 4 bytes",  function() expect(#CryptoLib.packU32(12345)).to.equal(4) end)
			it("offset works for embedded fields", function()
				local b1, b2 = CryptoLib.packU32(100), CryptoLib.packU32(200)
				local buf = { b1[1],b1[2],b1[3],b1[4], b2[1],b2[2],b2[3],b2[4] }
				expect(CryptoLib.unpackU32(buf, 1)).to.equal(100)
				expect(CryptoLib.unpackU32(buf, 5)).to.equal(200)
			end)
		end)
	end)

	-- InputGuard
	describe("InputGuard", function()
		describe("checkNumber", function()
			it("valid passes",      function() expect(InputGuard.checkNumber(42, 0, 100, "x")).to.equal(true) end)
			it("NaN fails",         function() expect(InputGuard.checkNumber(0/0, 0, 100, "x")).to.equal(false) end)
			it("+inf fails",        function() expect(InputGuard.checkNumber(math.huge, 0, 1e9, "x")).to.equal(false) end)
			it("-inf fails",        function() expect(InputGuard.checkNumber(-math.huge, -1e9, 0, "x")).to.equal(false) end)
			it("below range fails", function() expect(InputGuard.checkNumber(-1, 0, 100, "x")).to.equal(false) end)
			it("above range fails", function() expect(InputGuard.checkNumber(101, 0, 100, "x")).to.equal(false) end)
			it("string fails",      function() expect(InputGuard.checkNumber("42", 0, 100, "x")).to.equal(false) end)
			it("nil fails",         function() expect(InputGuard.checkNumber(nil, 0, 100, "x")).to.equal(false) end)
		end)

		describe("checkString", function()
			it("valid passes",     function() expect(InputGuard.checkString("hello", 128, "s")).to.equal(true) end)
			it("too long fails",   function() expect(InputGuard.checkString(string.rep("a", 200), 128, "s")).to.equal(false) end)
			it("non-string fails", function() expect(InputGuard.checkString(42, 128, "s")).to.equal(false) end)
			it("null byte fails",  function() expect(InputGuard.checkString("hello\0world", 128, "s")).to.equal(false) end)
			it("ctrl char fails",  function() expect(InputGuard.checkString("ab\x01cd", 128, "s")).to.equal(false) end)
			it("\\n is allowed",   function() expect(InputGuard.checkString("line1\nline2", 128, "s")).to.equal(true) end)
		end)

		describe("checkTable", function()
			it("flat table passes",     function() expect(InputGuard.checkTable({1,2,3})).to.equal(true) end)
			it("non-table fails",       function() expect(InputGuard.checkTable("str")).to.equal(false) end)
			it("recursive table fails", function()
				local t = {}; t.self = t
				expect(InputGuard.checkTable(t)).to.equal(false)
			end)
			it("too many keys fails", function()
				local big = {}
				for i = 1, 100 do big[i] = i end
				expect(InputGuard.checkTable(big)).to.equal(false)
			end)
			it("depth 3 passes", function() expect(InputGuard.checkTable({ { { 1 } } })).to.equal(true) end)
			it("depth 4 fails",  function() expect(InputGuard.checkTable({ { { { 1 } } } })).to.equal(false) end)
		end)

		describe("checkByteArray", function()
			it("valid array passes",  function() expect(InputGuard.checkByteArray({0, 128, 255})).to.equal(true) end)
			it("byte 256 fails",      function() expect(InputGuard.checkByteArray({0, 256, 0})).to.equal(false) end)
			it("negative byte fails", function() expect(InputGuard.checkByteArray({-1, 0, 0})).to.equal(false) end)
			it("float byte fails",    function() expect(InputGuard.checkByteArray({1.5, 0, 0})).to.equal(false) end)
			it("below minN fails",    function() expect(InputGuard.checkByteArray({1,2}, 5, 256)).to.equal(false) end)
			it("above maxN fails",    function() expect(InputGuard.checkByteArray(table.create(300, 0), 0, 256)).to.equal(false) end)
			it("non-table fails",     function() expect(InputGuard.checkByteArray("str")).to.equal(false) end)
		end)

		describe("checkPacket", function()
			it("valid packet passes", function()
				local key = CryptoLib.generateKey()
				local pkt = CryptoLib.encode({1,2,3}, key, 1)
				local ok, _err = InputGuard.checkPacket(pkt)
				expect(ok).to.equal(true)
			end)
			it("missing nonce fails",    function() expect(InputGuard.checkPacket({ cs=0, data={1} })).to.equal(false) end)
			it("missing cs fails",       function() expect(InputGuard.checkPacket({ nonce=1, data={1} })).to.equal(false) end)
			it("missing data fails",     function() expect(InputGuard.checkPacket({ nonce=1, cs=0 })).to.equal(false) end)
			it("NaN nonce fails",        function() expect(InputGuard.checkPacket({ nonce=0/0, cs=0, data={1} })).to.equal(false) end)
			it("float nonce fails",      function() expect(InputGuard.checkPacket({ nonce=1.5, cs=0, data={1} })).to.equal(false) end)
			it("bad byte in data fails", function() expect(InputGuard.checkPacket({ nonce=1, cs=0, data={-1} })).to.equal(false) end)
			it("non-table fails",        function() expect(InputGuard.checkPacket("notapacket")).to.equal(false) end)
		end)

		describe("checkFps", function()
			it("60 passes",       function() expect(InputGuard.checkFps(60)).to.equal(true) end)
			it("MIN passes",      function() expect(InputGuard.checkFps(InputGuard.LIMITS.MIN_FPS)).to.equal(true) end)
			it("MAX passes",      function() expect(InputGuard.checkFps(InputGuard.LIMITS.MAX_FPS)).to.equal(true) end)
			it("below MIN fails", function() expect(InputGuard.checkFps(1)).to.equal(false) end)
			it("above MAX fails", function() expect(InputGuard.checkFps(10000)).to.equal(false) end)
		end)
	end)

	-- HealthMonitor
	describe("HealthMonitor", function()
		describe("before init", function()
			it("snapshot activePlayers = 0", function() expect(HealthMon.snapshot().activePlayers).to.equal(0) end)
			it("playerMetrics returns nil",  function() expect(HealthMon.playerMetrics(99999)).to.equal(nil) end)
		end)

		describe("after init", function()
			local fakeProfiles = {}
			local fakePlayers  = {}
			HealthMon.init(
				function(pid) return fakeProfiles[pid] end,
				function()    return fakePlayers end
			)

			it("player count reflects injected list", function()
				fakePlayers = { { UserId=1 }, { UserId=2 } }
				expect(HealthMon.snapshot().activePlayers).to.equal(2)
			end)
			it("highRiskPlayers counts suspicion >= 60", function()
				fakeProfiles[1] = { suspicion=75 }
				fakeProfiles[2] = { suspicion=30 }
				fakePlayers     = { { UserId=1 }, { UserId=2 } }
				expect(HealthMon.snapshot().highRiskPlayers).to.equal(1)
			end)
			it("recordEvent doesn't error", function()
				for _ = 1, 10 do HealthMon.recordEvent() end
				expect(HealthMon.snapshot() ~= nil).to.equal(true)
			end)
			it("recordLatency shows in avg", function()
				HealthMon.recordLatency(5.0)
				HealthMon.recordLatency(15.0)
				expect(HealthMon.snapshot().latencyAvgMs > 0).to.equal(true)
			end)
			it("recordFlags shows in totalFlagsLast60s", function()
				HealthMon.recordFlags(3)
				HealthMon.recordFlags(2)
				expect(HealthMon.snapshot().totalFlagsLast60s >= 5).to.equal(true)
			end)
			it("uptime is non-decreasing", function()
				local s1 = HealthMon.snapshot()
				local s2 = HealthMon.snapshot()
				expect(s2.uptimeSeconds >= s1.uptimeSeconds).to.equal(true)
			end)
		end)

		describe("Bug 3 — public aliases", function()
			it("getHealthSnapshot is exposed", function()
				expect(HealthMon.getHealthSnapshot ~= nil).to.equal(true)
			end)
			it("getPlayerMetrics is exposed", function()
				expect(HealthMon.getPlayerMetrics ~= nil).to.equal(true)
			end)
			it("getHealthSnapshot returns same data as snapshot", function()
				if HealthMon.getHealthSnapshot then
					expect(HealthMon.getHealthSnapshot().activePlayers).to.equal(HealthMon.snapshot().activePlayers)
				end
			end)
		end)
	end)
end
