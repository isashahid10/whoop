# Changelog

Changes in this fork, on top of [OpenStrap Edge](https://github.com/OpenStrap/edge).
Upstream's own history is in its repository.

This project has no release cadence — it is a personal fork. Entries are grouped by the
schema and algorithm versions that gate them, because those are what actually determine
what a given build computes.

---

## Unreleased

`schemaVersion 29` · `kAlgoVersion 52`

### Added — training

- **Hevy sync** at set level (exercise, load, reps, RPE) without a Pro subscription
- **Strength analysis**: e1RM via Epley/Brzycki with RPE reps-in-reserve correction,
  per-lift Theil-Sen progression, weekly sets per muscle against Schoenfeld 2017 strata
- **Overreaching detector** — performance-first, corroborated by HRV and resting HR
- **Bulk quality** — weight trend against strength trend, abstaining when strength is unknown
- **HR-recovery rest timer** targeting 40% of heart-rate reserve, using the user's own
  median resting HR rather than a population default

### Added — context

- **Weather** via Open-Meteo (no API key)
- **Calendar** via EventKit — counts and busy minutes only, never event contents
- **Nutrition** through an Apple Health *read* path (upstream was write-only)
- **Caffeine logging** with a 5-hour half-life model and a last-safe-dose time

### Added — sleep

- **Composite sleep score** over duration, efficiency, timing and debt
- **Naps**, surfaced for the first time — detection existed since `kAlgoVersion 20` but
  no screen ever read it. Reported separately from the night and never summed into it.
- **Nap staging**. `detectNaps` already ran the full cardio stager and discarded the
  hypnogram, keeping only the duration. Stages are now plumbed through, withheld below
  one hour where the stager's within-sleep references are estimated from too few epochs.
- **`cpcWindowed()`** in analytics — Thomas (2005) cardiopulmonary coupling as a time
  series rather than a single whole-night figure
- **Deep-sleep uncertainty surfaced.** Where the cardiac and respiratory paths disagree,
  the UI now says so instead of silently presenting one of them.

### Added — life

- **Prayer times** from geolocation, with repeat reminders until marked done
- **Ramadan mode**, with fasted days excluded from correlation pairs
- **Simultaneous band and phone alarms**, surviving Do Not Disturb via AlarmKit
- **Google Drive backup** (opt-in, `drive.file` scope) so data survives app deletion
- **Local snapshot backups**, WAL-aware

### Added — insight

- **Cross-domain correlations**: Spearman with Benjamini-Hochberg FDR control at q=0.10,
  over a deliberately small hypothesis set
- **Readiness breakdown screen**. The glass-box decomposition was computed and persisted
  all along under `clinical.readiness_composite`; tapping the ring opened a coach screen
  instead. Now shows each input's signed contribution and the z-score behind it.

### Changed

- **UI retheme to match WHOOP**: neutral near-black ground, colour used only where it
  carries information, flat edge-to-edge nav, underline tabs, solid arcs, bundled fonts
- App icon generated from measured geometry at all 21 iOS sizes (`tool/make_icon.py`)
- Em dashes removed from every user-facing string (retained as the absent-value marker,
  which is real typography rather than prose)

### Fixed

- **Coach was blind to lifting data** — `v_lifts` and `v_lift_sessions` were undocumented
  in the prompt, so the fork's core question silently could not be answered
- **Weather and calendar had never once run.** Both syncs lived inside `healthSyncNow()`,
  behind a toggle defaulting to off. Moved to an independent 3-hourly pass.
- **Calendar permission was unreachable.** `requestCalendarAccess()` existed and nothing
  called it.
- **Weather silently gave up after being granted location.** `getLastKnownPosition()`
  returns null immediately after a grant and there was no fallback to an actual fix.
- **Steps disagreed between screens** — the detail screen read the raw band key,
  bypassing the phone-first resolver, so one day showed two different numbers
- **Live band steps were added on top of Apple Health totals**, double-counting every
  step of a walk in progress
- **`db.dart` `_open(version:)` was hardcoded separately from `schemaVersion`**, so
  bumping the constant did not run `onUpgrade`
- Migration ladder runtime: 12 min → 4.8 s

### Investigated, deliberately not changed

- **Deep-sleep under-reporting.** Instrumented against real nights: the classifier flags
  a normal ~25% of NREM, then a 3-unbroken-minute rule deletes 81% of it. Both loosening
  that rule and gating deep on CPC stability were measured against an Apple Watch
  ground-truth night; each fixed one night while badly breaking the other. Staging is
  unchanged and the disagreement is surfaced instead. Full data in
  [docs/METHODOLOGY.md](docs/METHODOLOGY.md#deep-sleep).
- **Blood pressure estimation.** Requires cuff calibration to mean anything; without a
  cuff any number would be invention.
- **Naps in strain and stress.** Verified correct as-is: stress is computed from the main
  sleep's RR only, and a nap's near-resting heart rate contributes negligibly to TRIMP.

### Infrastructure

- Fork CI covering both `analytics` and `edge`, plus a secret scan over full history
- Upstream workflows requiring secrets guarded so they no-op on forks
- Golden render harness writing real PNGs of screens
- `tool/deep_probe.dart` in analytics — runs the real stager over an exported night and
  reports which condition is binding, so this investigation is one command to repeat
