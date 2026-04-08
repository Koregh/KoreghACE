# KoreghACE Tests

Unit tests for MathLib, CryptoLib, InputGuard, HealthMonitor, and integration
wiring checks (static analysis). No external deps — only stdlib Lua/Luau.

## How to run

### Option 1 — lune (recommended)
```bash
# install: https://lune-org.github.io/docs
lune run tests/run_tests.luau
```

### Option 2 — luau CLI
```bash
# install: https://github.com/luau-lang/luau/releases
luau tests/run_tests.luau
```

### Option 3 — Roblox Studio
1. Copy `tests/run_tests.luau` into a `Script` under `ServerScriptService`
2. Stub the `require()` calls to point at your actual module instances
3. Run in Play mode and check the Output window

## What's tested

| Suite | Tests |
|---|---|
| MathLib / Welford | push, variance, stddev, n<2 edge cases |
| MathLib / zScore | zero stddev, above/below mean |
| MathLib / normalCDF | known values, far tail, pValue |
| MathLib / pearson | r=1, r=-1, constant Y, n<2 |
| MathLib / fpsScaleFactor | 60fps=1.0, low fps > 1, clamp |
| MathLib / reactionFpsFloor | frame math at 60/30/120fps |
| MathLib / expDecay | half-life, t=0, zero halfLife |
| MathLib / markovProbSmoothed | Laplace smoothing, unseen vs seen |
| MathLib / activePhysicsMax | no events, active, expired, multi |
| MathLib / purgeExpiredPhysics | removes expired, keeps active |
| MathLib / misc | clamp01, clampSusp, cv, speed, positionThreshold |
| CryptoLib / generateKey | 16 bytes, all in [0,255], randomness |
| CryptoLib / encode-decode | round-trip 1-byte, 5-byte, 25-byte |
| CryptoLib / replay/tamper | nonce replay, old nonce, tampered byte, wrong key |
| CryptoLib / packU32/unpackU32 | 0, 255, 65535, 2^24-1, 4-byte size, offset |
| InputGuard / checkNumber | valid, NaN, ±inf, out-of-range, wrong type |
| InputGuard / checkString | valid, too long, non-string, null byte, control char |
| InputGuard / checkTable | flat, non-table, recursive, too many keys, depth |
| InputGuard / checkByteArray | valid, 256+, negative, float, min/max N |
| InputGuard / checkPacket | valid full packet, each missing field, NaN nonce |
| InputGuard / checkFps | 60, MIN, MAX, below MIN, above MAX |
| HealthMonitor / before init | zeroed state, nil playerMetrics |
| HealthMonitor / after init | player count, high-risk count, recordEvent/Latency/Flags |
| HealthMonitor / aliases | getHealthSnapshot and getPlayerMetrics exposed (Bug 3) |
| HealthMonitor / status | thresholds, uptime monotonic |
| Types.luau | PhysicsEvent exported, SessionKey exported (Bug 4) |
| AntiCheatService (static) | InputGuard imported + checkPacket called (Bug 1), HealthMonitor.init called (Bug 2) |
| HitValidator (static) | FindFirstAncestorOfClass used, not .Parent |

## Bugs these tests catch

| Bug | Test suite |
|---|---|
| Bug 1 — InputGuard never called | `AntiCheatService — wiring` |
| Bug 2 — HealthMonitor.init never called | `AntiCheatService — wiring` |
| Bug 3 — getHealthSnapshot/getPlayerMetrics not exposed | `HealthMonitor — aliases` |
| Bug 4 — PhysicsEvent/SessionKey missing from Types | `Types.luau — required export types` |
| HitValidator geometry (.Parent vs ancestor walk) | `HitValidator — geometry check` |
