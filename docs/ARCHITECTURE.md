# Architecture

How data moves from the band to a number on screen, and where new code belongs.

For upstream's internals, [`AGENTS.md`](../AGENTS.md) is the authoritative document and
supersedes this one on anything it covers.

---

## The three-repo rule

Upstream splits the system into three packages and enforces the boundary strictly. This
fork respects it, because it is the single thing that keeps rebasing onto an actively
developed upstream tractable.

| Repo | Owns | Never contains |
|---|---|---|
| [`OpenStrap/protocol`](https://github.com/OpenStrap/protocol) | **Bytes.** GATT, framing, CRC, opcodes, record decode | Metrics, UI, storage |
| [`OpenStrap/analytics`](https://github.com/OpenStrap/analytics) | **Metrics.** HRV, sleep staging, readiness, strain, correlations | I/O, clocks, randomness, UI |
| [`OpenStrap/edge`](https://github.com/OpenStrap/edge) | **Flows.** BLE link management, storage, UI | Metric definitions |

### Where does my code go?

```
New opcode or record shape?        → protocol
New metric or statistical method?  → analytics
New screen, table, or sync flow?   → edge
```

A metric implemented inside `edge/lib/compute` is in the wrong place **unless it is pure
orchestration** — loading rows, calling analytics, and handing the result to the UI.
`lib/compute/*_service.dart` files in this fork are deliberately thin for that reason:
the judgement about *which* relationships are worth testing lives in edge, the
statistics live in analytics.

`analytics` is pure: `dart:math` only, no I/O, no clock reads, no randomness. That is
what makes its results reproducible and its tests meaningful.

---

## Data flow

```
   WHOOP 4.0 band
        │  BLE GATT, notifications
        ▼
   ble_engine.dart                    state machine, reconnect, chunk ledger
        │  raw frames
        ▼
   openstrap_protocol                 decode, CRC, opcode dispatch
        │
        ├──────────────► raw_archive          NEVER pruned. Unknown and
        │                                     undecodable records kept forever.
        ▼
   decoded_onehz  (1 Hz samples, UNIQUE(rec_ts))
   decoded_rr     (beat-to-beat intervals)
   events / band_events
        │
        ▼
   derivation_engine.dart             orchestration, versioned by kAlgoVersion
        │  calls
        ▼
   openstrap_analytics                the actual maths
        │
        ▼
   day_result      PK (day_id, algo_version)   IMMUTABLE
   metric_series   PK (date, key)              replace
        │
        ▼
   local_repository_impl.dart         shapes bundles for screens
        │
        ▼
   UI  /  coach views (v_*)
```

### Why `day_result` is immutable

Rows are keyed `(day_id, algo_version)` and never updated in place. A better algorithm
does not mutate history — it bumps `kAlgoVersion`, and every affected day is recomputed
from the preserved raw samples.

This has a practical consequence worth knowing: **adding a field to a derived bundle
does nothing to existing days until the version is bumped.** A new field with no version
bump reads as absent forever, which looks exactly like a broken feature.

### Why `raw_archive` is never pruned

Parts of the protocol are still educated guesses. Event semantics are provisional.
Keeping every raw record — including ones that could not be decoded at the time — means
a future decoder improvement can be applied retroactively to data already collected.
Derived tables are disposable; samples are not.

---

## Storage model

| Table | Contents | Notes |
|---|---|---|
| `raw_records` | Replay/debug ledger | Upgrade fallback |
| `raw_archive` | Undecodable and unknown-version records | **Never pruned** |
| `decoded_onehz` | 1 Hz samples | `UNIQUE(rec_ts)`, insert-or-replace |
| `decoded_rr` | Beat-to-beat RR intervals | Cascades on eviction |
| `events` / `band_events` | Band lifecycle events | Semantics provisional |
| `day_result` | Derived daily bundle | Versioned, **immutable** |
| `metric_series` | Flat `(date, key) → value` | Replace |
| `hevy_set` | One row per logged set | Fork addition |
| `caffeine_log` | Timestamped intake | Fork addition |

SQLite runs in **WAL mode**. The main `.db` file under-reports actual size — any backup
or copy must include the `-wal` and `-shm` sidecars or it will be silently incomplete.

---

## What this fork adds

Additive only, in clearly separated files, so upstream rebases stay clean.

### In `analytics` (metrics)

| Module | Purpose |
|---|---|
| `workout/strength.dart` | e1RM, progression, weekly volume |
| `workout/bulk_quality.dart` | Weight trend vs strength trend |
| `workout/overreaching.dart` | Functional overreaching detection |
| `sleep/sleep_score.dart` | Composite sleep score |
| `sleep/caffeine.dart` | Half-life decay, last-safe-dose time |
| `sleep/cpc.dart` → `cpcWindowed()` | Sleep stability as a time series |
| `wellness/correlations.dart` | Spearman + Benjamini-Hochberg FDR |

### In `edge` (flows and UI)

| Module | Purpose |
|---|---|
| `integrations/hevy_client.dart` | Set-level training log |
| `integrations/weather_client.dart` | Open-Meteo, no API key |
| `integrations/calendar_client.dart` | EventKit, counts only |
| `compute/*_service.dart` | Thin orchestration over analytics |
| `notify/prayer_times.dart` | On-device prayer times |
| `notify/ramadan.dart` | Fasting days, excluded from correlations |
| `data/backup_service.dart` | Local snapshots, WAL-aware |
| `data/drive_backup.dart` | Opt-in off-device backup |

---

## The coach's data surface

The coach runs **read-only SQL over allow-listed `v_*` views**, behind a deny-list guard.

```sql
v_daily          resting_hr, hrv, readiness, strain, sleep_*,
                 protein_g, calories_in, carbs_g, fat_g, weight_kg,
                 temp_max_c, humidity_pct, cal_events, cal_busy_min
v_lifts          one row per SET: exercise, weight, reps, RPE, muscle group
v_lift_sessions  one row per WORKOUT: volume, duration, muscles hit
v_baseline_trust how much history each baseline actually has
```

> [!IMPORTANT]
> **Adding coach data means adding a view, never widening the guard.** The guard is the
> boundary; a view is a deliberate, reviewable hole in it.

`postChat` fail-closes on request size — it refuses rather than truncating, so a runaway
tool loop cannot ship the health database to a third party. That is the single most
important line of defence in the app and must not be softened.

---

## Bug-density hotspots

Files with the highest fix-commit churn upstream. Treat diffs here with extra scrutiny:

- `state/app_state.dart`
- `data/db.dart`
- `compute/derivation_engine.dart`
- `data/local_repository_impl.dart`
- `ble/ble_engine.dart`

---

## Invariants

Things that are load-bearing and have each broken at least once:

1. **`db.dart`'s `_open(version:)` must be bound to `schemaVersion`.** It was once
   hardcoded separately, so bumping the constant did not run `onUpgrade`.
2. **`coach_engine` must append `tool_calls` verbatim.** Rebuilding the list drops
   Gemini's `thought_signature` and the agentic loop dies on the *second* turn — a
   failure a shallow test never sees.
3. **The Apple Health importer must drop own-source points**, or it re-imports the app's
   own exports and double-counts.
4. **Hevy rotates its refresh token on every refresh.** Persist the new one or the next
   sync 401s.
5. **Phone step counts must not have live band steps added to them.** Apple Health
   already includes the walk in progress; adding the band's live count double-counts it.
6. **Backups must include the WAL sidecars.** The main `.db` alone is incomplete.

---

## Testing philosophy

- Anything touching stored data gets a **migration test**.
- Anything computing a health number gets a test pinning the **method**, not merely the
  output — including tests asserting what the code deliberately *refuses* to claim.
- Analytics is pure, so its tests are exact rather than approximate.
- UI gets **rendered goldens**, so design is looked at rather than argued about.

See [METHODOLOGY.md](METHODOLOGY.md) for what each metric can and cannot support.
