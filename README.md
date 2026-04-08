> [!WARNING]
> **KoreghACE is a behavioural anomaly detector, NOT a kernel-level anti-cheat.**
> It detects suspicious patterns and applies graduated enforcement.
> A determined cheater who understands the system can reduce their signature.
> Use it as one layer of defence among many — never as the only one.

>[!NOTE]
> This project used artificial intelligence to extract online data from CS2 and generate an accurate sample report intended for developers.

> [!TIP]
> Special thanks to Professor Fernando Mori for his guidance and dedication throughout the semester. His teachings in Computational Mathematics and fundamental mathematical concepts were essential to the development of this project, providing both theoretical foundation and practical insight. His support and knowledge greatly contributed to our learning and growth.
---

# KoreghACE — Koregh Behavior Validation System (KBVS)

**Server-authoritative behavioural analysis engine for Roblox games.**
Statistical anomaly detection, Markov behaviour modelling, cryptographic payload integrity, and graduated enforcement — running entirely server-side.

[![Roblox](https://img.shields.io/badge/Roblox-Compatible-00A2FF?style=for-the-badge&logo=roblox)](https://www.roblox.com)
[![Luau](https://img.shields.io/badge/Luau-Strict_Mode-00A2FF?style=for-the-badge)](https://luau-lang.org/)
[![License](https://img.shields.io/badge/License-MIT-green?style=for-the-badge)](LICENSE)

---

## Table of Contents

1. [What this system IS and IS NOT](#what-this-system-is-and-is-not)
2. [Architecture](#architecture)
3. [Folder structure](#folder-structure)
4. [Installation](#installation)
5. [Quickstart](#quickstart)
6. [Configuration reference](#configuration-reference)
7. [Suspicion model](#suspicion-model)
8. [Detectors](#detectors)
9. [Security hardening](#security-hardening)
10. [Health monitoring](#health-monitoring)
11. [API reference](#api-reference)
12. [Critical analysis & known limitations](#critical-analysis--known-limitations)
13. [Advanced improvements](#advanced-improvements)
14. [FAQ](#faq)

---

## What this system IS and IS NOT

### What KBVS IS

| Property | Detail |
|---|---|
| **Behavioural validator** | Detects statistical outliers in player behaviour (speed, reaction, accuracy, aim patterns) |
| **Server-authoritative** | All analysis runs on the server. The client is a thin data reporter only |
| **Probabilistic** | Uses z-scores, Markov chains, and population percentiles — not binary rule matching |
| **Graduated** | Five reversible enforcement levels. No instant bans without escalation |
| **Adaptive** | Per-player baselines. A high-sensitivity player is judged against their own history, not global constants |
| **Anti-replay** | XOR stream cipher with monotonic nonce prevents replaying captured packets |

### What KBVS IS NOT

| Claim | Reality |
|---|---|
| **Kernel-level anti-cheat** | KBVS cannot inspect the client process, memory, or loaded modules. Compare: Riot Vanguard (kernel driver), EasyAntiCheat |
| **Guaranteed to stop cheaters** | A cheater who knows the thresholds can stay under them |
| **A replacement for game design** | Server-side validation of game rules (damage caps, speed limits) must exist independently |
| **A legal/compliance tool** | Do not use suspicion scores as grounds for permanent account bans without human review |

### Conceptual comparison

```
Kernel anti-cheat (Vanguard, EAC):
  Detects: memory injection, DLL hooks, driver-level hacks
  Scope: the player's entire machine
  KBVS cannot do this.

Behavioural anti-cheat (VAC-style, KBVS):
  Detects: impossible statistics, scripted patterns, replay attacks
  Scope: server-observable behaviour only
  This is what KBVS does.
```

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  CLIENT                                                          │
│  ActionReporter (LocalScript)                                    │
│    • Handshake → receives 128-bit session key                    │
│    • XOR-encodes every event with key + monotonic nonce          │
│    • Reports: actions, stimuli (for reaction timing), hit claims │
└───────────────────────┬──────────────────────────────────────────┘
                        │ RemoteEvent (encrypted bytes)
┌───────────────────────▼──────────────────────────────────────────┐
│  SERVER                                                          │
│                                                                  │
│  AntiCheatService (entry point)                                  │
│    ├── InputGuard       validates ALL incoming data              │
│    ├── CryptoLib        decodes + verifies packet integrity      │
│    ├── DataCollector    20 Hz telemetry → per-player profile     │
│    ├── StatsEngine      z-scores for each metric                 │
│    ├── AnomalyDetector  12 independent detectors → suspicion     │
│    ├── DecisionEngine   state machine → enforcement action       │
│    ├── HitValidator     server-side hit geometry + range check   │
│    ├── Logger           ring buffer + async DataStore flush      │
│    └── HealthMonitor    latency / EPS / memory / status          │
└──────────────────────────────────────────────────────────────────┘
```

**Key design principle:** The client cannot affect the detection outcome by sending different data — it can only delay flagging, not prevent it. Position, velocity, and CFrame are sampled directly by the server at 20 Hz from `HumanoidRootPart`. The client only reports events that the server cannot observe directly (clicks, reaction stimuli, hit claims).

---

## Folder structure

```
ServerScriptService/
└── AntiCheatService.luau          ← entry point (Script)
    ├── Server/
    │   ├── DataCollector.luau     telemetry collection (ModuleScript)
    │   ├── StatsEngine.luau       statistical primitives (ModuleScript)
    │   ├── AnomalyDetector.luau   all detectors (ModuleScript)
    │   ├── DecisionEngine.luau    enforcement state machine (ModuleScript)
    │   ├── HitValidator.luau      server-side hit validation (ModuleScript)
    │   └── Logger.luau            in-memory ring + DataStore (ModuleScript)
    ├── Shared/
    │   ├── Types.luau             type definitions (ModuleScript)
    │   ├── MathLib.luau           math primitives (ModuleScript)
    │   ├── CryptoLib.luau         XOR cipher + checksum (ModuleScript)
    │   └── PopulationConfig.luau  population baseline tiers (ModuleScript)
    ├── Security/
    │   └── InputGuard.luau        input validation + sanitisation (ModuleScript)
    └── Metrics/
        └── HealthMonitor.luau     system health + metrics (ModuleScript)

StarterPlayerScripts/
└── ActionReporter.luau            thin client reporter (LocalScript)
```

---

## Installation

**Manual (recommended):**
1. Copy `AntiCheatService.luau` and its child folder structure into `ServerScriptService`
2. Copy `ActionReporter.luau` into `StarterPlayerScripts`
3. Ensure `CryptoLib.luau` is in `ReplicatedStorage.Shared` (referenced by the client)

**Wally:**
```toml
[dependencies]
KoreghACE = "yourname/koreghace@4.0.0"
```

---

## Quickstart

### Minimal integration (combat game)

```lua
-- In your weapon hit handler (Server)
local AntiCheatService = require(game.ServerScriptService.AntiCheatService)

-- 1. Validate the hit before applying damage
local isValid = AntiCheatService.validateHit(
    attacker,        -- Player
    victim.UserId,   -- number
    clientHitPos,    -- Vector3 (where client claims the hit happened)
    weaponRange,     -- studs
    damageAmount,    -- number
    isHeadshot       -- boolean
)
if not isValid then return end

-- 2. Apply damage
victim.Character.Humanoid:TakeDamage(damageAmount)

-- 3. Report the kill
AntiCheatService.reportKill(attacker, isHeadshot, killTimeSec, killDistStuds)
```

### Gate interactions behind shadow ban

```lua
if AntiCheatService.isShadowBanned(player) then
    return  -- silently ignore the request
end
```

### Register a physics event (explosion, knockback, dash)

```lua
-- Call BEFORE applying the force
AntiCheatService.registerPhysicsEvent(
    player,
    2.0,   -- leniency duration in seconds
    300    -- max speed override in studs/s during this window
)
-- Now apply your explosive force...
```

### Register weapon recoil pattern (for recoil-compensation detection)

```lua
-- Pattern = array of expected angular velocities (rad/s) per shot
AntiCheatService.setRecoilPattern("AK47", {0.8, 0.9, 1.1, 1.0, 0.85, 0.9, 1.0})
AntiCheatService.setPlayerWeapon(player, "AK47")
```

---

## Configuration reference

All fields live in `AnomalyDetector.CFG`. Patch at runtime via `AntiCheatService.patchConfig`.

### Z-score thresholds (statistical detectors)

| Field | Default | Description |
|---|---|---|
| `Z_REACTION` | `3.5` | Reaction time z-score threshold (|z| > this = flagged) |
| `Z_CPS` | `3.5` | Clicks-per-second z-score threshold |
| `Z_ACCURACY` | `3.0` | Accuracy z-score threshold |
| `Z_SPEED` | `4.0` | Speed z-score threshold (higher = fewer false positives) |
| `Z_IET` | `3.0` | Inter-event timing z-score |
| `Z_CFRAME` | `3.5` | Aim angular velocity z-score vs own baseline |

### Absolute human limits

| Field | Default | Description |
|---|---|---|
| `MIN_REACTION_MS` | `70` | Below this AND below FPS floor = superhuman reaction |
| `MAX_CPS` | `16` | Clicks/sec above this = mechanical (butterfly click exempt if expected) |
| `ACCURACY_CEIL` | `0.97` | Sustained accuracy above this (n ≥ 30) = aimbot suspected |
| `MAX_SPEED_STUDS` | `50` | Speed above this (studs/s) = physics violation |

### Teleport detection

| Field | Default | Description |
|---|---|---|
| `TELEPORT_MAX_STUDS_PER_SEC` | `80` | Max position delta per second (above = teleport flag) |
| `TELEPORT_MIN_SAMPLES` | `5` | Minimum samples before teleport check activates |

### Recoil detection

| Field | Default | Description |
|---|---|---|
| `RECOIL_PEARSON_THRESHOLD` | `0.96` | Pearson |r| above this = scripted recoil compensation |
| `RECOIL_MIN_SAMPLES` | `20` | Pattern length required for recoil check |

### Session / account checks

| Field | Default | Description |
|---|---|---|
| `SESSION_HS_RATE_CEIL` | `0.75` | Headshot rate above this (over N kills) = suspicious |
| `SESSION_HS_MIN_KILLS` | `20` | Minimum kills before headshot rate is evaluated |
| `ACCOUNT_AGE_DAYS` | `30` | Accounts younger than this with high accuracy = smurf flag |
| `SMURF_ACCURACY` | `0.70` | Accuracy threshold for smurf detection |

### Markov behaviour model

| Field | Default | Description |
|---|---|---|
| `MARKOV_RARE_PROB` | `0.01` | Transition probability below this = rare sequence flag |
| `MARKOV_ENTROPY_LOW` | `0.15` | Normalised entropy below this = scripted macro suspected |
| `MARKOV_MIN_EDGES` | `50` | Edges required before Markov activates |
| `VOCAB_SIZE` | `32` | Number of distinct action IDs |

### Suspicion dynamics

| Field | Default | Description |
|---|---|---|
| `DELTA_SCALE` | `8.0` | Max suspicion points added per analysis tick |
| `HALF_LIFE` | `60.0` | Seconds for suspicion to halve (exponential decay) |

### Detector weights (must sum to ≤ 1.0)

| Field | Default | Detector |
|---|---|---|
| `W_REACTION` | `0.12` | Reaction time |
| `W_CPS` | `0.14` | Clicks per second |
| `W_ACCURACY` | `0.12` | Accuracy |
| `W_SPEED` | `0.10` | Movement speed |
| `W_IET` | `0.12` | Inter-event timing |
| `W_CFRAME` | `0.10` | Aim trajectory |
| `W_TELEPORT` | `0.10` | Position jumps |
| `W_MARKOV` | `0.08` | Behaviour sequence |
| `W_POPULATION` | `0.05` | Population outlier |
| `W_SESSION` | `0.03` | Session headshot rate |
| `W_ACCOUNT` | `0.02` | Account integrity |
| `W_RECOIL` | `0.02` | Recoil pattern correlation |

---

## Suspicion model

Suspicion is a score from 0 to 100 that decays exponentially with a configurable half-life.

```
suspicion(t) = suspicion(t₀) × e^(−ln2 / halfLife × Δt)
```

Each anomaly detection call adds a delta:
```
delta = severity × weight × DELTA_SCALE
suspicion = clamp(suspicion + delta, 0, 100)
```

### Enforcement levels

| Score | Level | Action |
|---|---|---|
| 0–29 | `CLEAN` | None |
| 30–59 | `MONITOR` | Internal logging only |
| 60–79 | `ALERT` | Logged + flagged for human review |
| 80–94 | `RESTRICT` | WalkSpeed soft-capped to 8 studs/s |
| 95–99 | `SHADOWBAN` | Interactions silently dropped |
| 100 | `REMOVE` | Player kicked (generic message, no internal detail) |

All levels below `REMOVE` are **fully reversible** if suspicion decays below the threshold.

---

## Detectors

| Detector | Method | Absolute bound | Statistical signal |
|---|---|---|---|
| **Reaction time** | Stimulus→action latency | < 70ms AND < FPS frame time | z > 3.5 vs own history |
| **CPS** | Click rate (1s sliding window) | > 16 CPS | z > 3.5 |
| **Accuracy** | Hit / total shots | > 97% sustained (n≥30) | z > 3.0 |
| **Speed** | HRootPart velocity magnitude | > 50 studs/s (FPS-scaled) | z > 4.0 |
| **IET** | Inter-event timing variance | CV < 0.05 (too regular) | — |
| **Aim trajectory** | Camera angular velocity | > 25 rad/s hard snap | z > 3.5 vs own baseline |
| **Teleport** | Position delta vs time | > 80 studs/s | — |
| **Markov** | Action transition probability | P < 0.01 | entropy < 0.15 |
| **Population outlier** | vs tier percentile bands | — | > p95 for reaction/CPS/accuracy |
| **Session headshot rate** | HS kills / kills | > 75% (over 20 kills) | — |
| **Account integrity** | Age + accuracy combo | New account + high accuracy | — |
| **Recoil correlation** | Pearson r vs weapon pattern | abs(r) > 0.96 | — |
| **Replay attack** | Crypto nonce ordering | nonce ≤ last seen | — |
| **Hit geometry** | Server raycast | Solid obstacle in path | — |
| **Hit range** | Ping-compensated distance | > range × 1.25 + lag budget | — |

---

## Security hardening

### What KBVS does to resist bypass

1. **InputGuard pre-validation** — every RemoteEvent payload is structurally validated (type, range, NaN/inf, table depth, recursive table detection) before any decryption or profile lookup.

2. **Anti-replay nonce** — each encoded packet carries a monotonic 32-bit nonce. The server rejects any packet with `nonce ≤ lastNonce`. Replaying a captured valid packet fails.

3. **Per-session XOR cipher** — each player gets a 16-byte random session key on handshake. A forged packet requires knowledge of that key. A plain re-fire of a captured RemoteEvent will fail the checksum.

4. **Server-sampled telemetry** — position, velocity, and CFrame are read directly from `HumanoidRootPart` by the server at 20 Hz. A client cannot fake these values.

5. **Rate limiting** — ActionEvent is capped at 30 calls/second per player. Excess calls are silently dropped before any detector sees them.

6. **patchConfig validation** — runtime config changes validate key existence, type, and numeric bounds. Invalid patches are rejected with a warning.

### What KBVS does NOT protect against

- A cheater who knows exact thresholds and deliberately stays under them
- Speed hacks that operate within the `MAX_SPEED_STUDS` threshold
- Aim assistance that keeps angular velocity within the player's own z-score range (requires more samples to detect)
- Client-side memory manipulation of non-replicated values

### Best practices

- **Never trust any client value for gameplay outcomes.** All damage application, hit registration, and kill attribution must be server-authoritative. KBVS validates, it does not replace your combat system.
- **Run HitValidator.validate() on every hit claim.** Don't skip it because the player "seems clean."
- **Tune PopulationConfig** with real player data from your game. Default tiers are illustrative.
- **Review logs for `ALERT` and above** periodically. KBVS generates signals; humans make final decisions.
- **Keep kick messages generic.** Do not expose suspicion scores or anomaly details to the client — this helps cheaters calibrate.

---

## Health monitoring

KBVS v4 includes a built-in health subsystem. Query it from an admin command or a server-side monitoring script.

```lua
local health = AntiCheatService.getHealthSnapshot()
--[[
{
  status          = "OK",        -- "OK" | "DEGRADED" | "FAIL"
  uptimeSeconds   = 3600,
  activePlayers   = 12,
  eventsPerSecond = 45.2,
  analysisHz      = 4.97,        -- should be ~5.0
  latencyAvgMs    = 1.2,
  latencyP95Ms    = 3.1,
  latencyP99Ms    = 8.4,
  estimatedMemKB  = 288,
  totalFlagsLast60s = 7,
  highRiskPlayers   = 1,
}
--]]
```

| Status | Meaning |
|---|---|
| `OK` | Average latency < 20ms, analysis running at target rate |
| `DEGRADED` | Average > 20ms or p99 > 100ms — consider reducing player count or analysis frequency |
| `FAIL` | Average > 50ms or analysis Hz < 2.0 or p99 > 250ms — system not operating correctly |

Per-player metrics:

```lua
local m = AntiCheatService.getPlayerMetrics(player)
--[[
{
  playerId      = 12345678,
  suspicion     = 47,
  riskScore     = 52,        -- blend of suspicion + anomaly density
  anomalyCount  = 3,         -- flags in the last 60 seconds
  level         = "MONITOR",
  topAnomalies  = {"Z_SCORE_SPIKE", "VELOCITY_IMPOSSIBLE"},
  fps           = 60,
  ping          = 82,        -- ms
}
--]]
```

---

## API reference

### `AntiCheatService` (server)

```lua
-- Detection
AntiCheatService.isShadowBanned(player: Player): boolean
AntiCheatService.getSuspicion(player: Player): number          -- [0, 100]

-- Combat hooks
AntiCheatService.reportShot(player: Player, hit: boolean): ()
AntiCheatService.reportAccuracy(player: Player, acc: number): ()  -- [0, 1]
AntiCheatService.reportKill(player, isHeadshot, killTimeSec?, killDistStuds?): ()
AntiCheatService.reportDeath(player: Player): ()
AntiCheatService.validateHit(attacker, victimId, clientPos, range, damage, headshot): boolean

-- Physics events
AntiCheatService.registerPhysicsEvent(player, duration, maxSpeed): ()

-- Weapon tracking
AntiCheatService.setPlayerWeapon(player: Player, weaponName: string?): ()
AntiCheatService.setRecoilPattern(weaponName: string, pattern: {number}): ()

-- Config
AntiCheatService.patchConfig(patch: {[string]: number | boolean}): ()
AntiCheatService.addHitIgnore(instance: Instance): ()

-- Introspection
AntiCheatService.dumpSessionStats(player: Player): SessionStats?
AntiCheatService.getPlayerLogs(player: Player, limit: number): {LogEntry}
AntiCheatService.getHealthSnapshot(): HealthSnapshot
AntiCheatService.getPlayerMetrics(player: Player): PlayerMetrics?
```

### `ActionReporter` (client)

```lua
ActionReporter.fireAction(actionId: number): ()      -- [0, 31]
ActionReporter.onStimulus(): ()                       -- starts reaction timer
ActionReporter.submitHit(victimId, clientPos, range, damage, isHeadshot): ()
```

---

## Critical analysis & known limitations

### Strengths

- **Zero allocations in hot path.** Pre-allocated ring buffers, Welford accumulators, and in-place Markov updates mean no GC pressure at runtime.
- **FPS-adaptive thresholds.** A player at 20 fps gets scaled margins to prevent false positives from large physics steps.
- **Individual baselines.** CFrame detection uses the player's own first N samples as a baseline, neutralising mouse sensitivity and DPI differences.
- **Layered signals.** No single detector drives a ban. All 12 detectors contribute weighted signals. One anomaly alone cannot reach REMOVE.
- **Graceful decay.** Legitimate lag spikes, burst clicks, or momentary accuracy peaks decay without permanent consequence.

### Known failure modes

| Scenario | Risk | Mitigation |
|---|---|---|
| **Low sample count** | Statistical detectors need ≥ 30 samples. A cheater who disconnects frequently resets their baseline | Persist baselines to DataStore; penalise frequent disconnects |
| **Calibrated cheating** | A cheater who reads this README can tune their cheat to stay under thresholds | Randomise thresholds slightly per-player; keep thresholds private |
| **High-latency players** | Generous ping compensation can mask teleport or hit range violations | Set a `MAX_ACCEPTABLE_PING` above which players are flagged for review |
| **Butterfly/jitter clicking** | Legitimate players using hardware techniques can exceed CPS limits | Increase `MAX_CPS` for games where this is expected; add per-game exceptions |
| **Professional players** | Top-tier players may trigger accuracy and reaction detectors legitimately | `PopulationConfig` tiers help; `W_POPULATION` weight is intentionally low |
| **FPS spoofing** | Client reports FPS; a cheater could report 10 FPS to widen speed/reaction margins | The Welford average dampens single bad reports; monitor `wFps.mean` trend |
| **Crypto strength** | XOR + Murmur3 is obfuscation, not encryption. Does not protect against a motivated reverser | Sufficient to stop script-kiddie refire; not sufficient against dedicated RE |

### False positive rate

Expected at default thresholds: **< 0.5% of legitimate player sessions reach `ALERT`** (z > 3.0 means ~0.26% of a normal distribution). The exponential decay further reduces the chance of a legitimate spike resulting in enforcement.

### False negative rate

KBVS will miss: very subtle aimbots that match the player's own movement profile, wall hacks (server cannot see what the client sees), and speed hacks that stay within the scaled threshold.

### Comparison to real anti-cheats

| Feature | KBVS | VAC | Vanguard |
|---|---|---|---|
| Kernel driver | ❌ | ❌ | ✅ |
| Memory scan | ❌ | ✅ (partial) | ✅ |
| DLL inspection | ❌ | ✅ | ✅ |
| Behavioural stats | ✅ | ✅ | ✅ |
| Server-side validation | ✅ | Depends on game | Depends on game |
| Roblox compatible | ✅ | ❌ | ❌ |

---

## Advanced improvements

### 1. Lightweight ML (online logistic regression)

Replace the fixed-weight combination with an online-trained model. After each confirmed ban (verified by human review), treat the feature vector at time of detection as a positive training sample. Legitimate players who were never actioned provide negative samples.

```lua
-- Conceptual sketch
local features = {
    zReaction, zCps, zAccuracy, zSpeed,
    iet_cv, cframe_z, pearson_r, markov_entropy
}
local logit = dot(features, learned_weights) + bias
local p = 1 / (1 + math.exp(-logit))
```

This requires a persistent weight store (DataStore) and a review pipeline.

### 2. Dynamic trust score

Separate from suspicion (a risk signal), maintain a trust score that increases with legitimate gameplay over time. Long-tenured players with clean histories get wider thresholds automatically.

```lua
-- Trust score concept
trustScore = clamp(trustScore + 0.01 * dt, 0, 1)   -- grows over time
thresholdMultiplier = 1.0 + 0.5 * trustScore         -- wider window for trusted players
```

### 3. Cross-player correlation

Anomalies that appear simultaneously across multiple players with similar patterns (e.g. all players in a server spike at the same time) suggest a coordinated exploit or a server-side physics event — not individual cheating. Correlating anomaly timestamps across the player set would reduce false positives from map-wide events.

### 4. Behavioural profile persistence

Currently, profiles reset on disconnect. Persisting the Welford accumulators and Markov model to DataStore allows the system to build better baselines over multiple sessions, making statistical detection more accurate.

### 5. Anomaly confidence intervals

Rather than a single z-score threshold, use Bayesian updating. Start with a weak prior and strengthen it as more evidence accumulates. This reduces the impact of early-session false positives.

---

## Performance notes

- `--!native` and `--!optimize 2` on all hot-path modules (`MathLib`, `DataCollector`, `AnomalyDetector`, `CryptoLib`)
- Ring buffers pre-allocated with `table.create` at registration — zero allocations per sample
- Welford: O(1) per sample, no history retained
- CPS ring: O(1) push, O(64) query (bounded by `CPS_CAP`)
- Analysis runs at **5 Hz** (every 200ms); sampling runs at **20 Hz**
- DataStore writes are async (`task.spawn`), batched every 30 seconds

---

## FAQ

**How many players can this handle?**
At 5 Hz analysis with 12 detectors per player, benchmarks show ~1.5ms per 50-player server on a standard Roblox 2-core instance. The health monitor will report `DEGRADED` if this grows.

**Can cheaters bypass the crypto?**
The XOR cipher prevents replay attacks and casual refire, but is not cryptographically secure against a motivated reverser. It raises the cost of spoofing significantly; it does not make spoofing impossible.

**Why is `REMOVE` instant at 100?**
Reaching 100 suspicion requires sustained anomalies across multiple detectors over time. The exponential decay makes it very difficult to reach 100 by accident. However, if you prefer a manual review step, change the `REMOVE` logic in `DecisionEngine` to log instead of kick.

**What about mobile players with high latency?**
The hit validator uses ping-compensated margins. All speed and reaction detectors apply FPS scaling. Mobile players at 20 FPS with 200ms ping are explicitly handled.

**The Markov detector isn't firing.**
It requires `totalEdges ≥ 50`. In short sessions (< 2 minutes of combat) this will not activate — by design. Consider reducing `MARKOV_MIN_EDGES` for longer sessions or increasing it for short rounds.

**Can I use this for a non-shooter game?**
Yes. Disable the hit validator, set weapon-related weights to 0, and rely on the speed, teleport, Markov, and IET detectors. These apply to any game with movement and input.

---

## License

MIT © KoreghACE Contributors — see [LICENSE](LICENSE) for terms.
