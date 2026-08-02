# Methodology

What each number means, what it is derived from, and — most importantly — **what it
cannot support**.

The organising principle of this project is *abstain over fabricate*. A metric that
cannot be computed honestly reports absent and says what it is waiting for. It never
substitutes a population average and presents it as yours.

---

## Contents

- [Readiness](#readiness)
- [Sleep score](#sleep-score)
- [Deep sleep](#deep-sleep) ← the most important section here
- [Naps](#naps)
- [Steps](#steps)
- [Strength](#strength)
- [Bulk quality](#bulk-quality)
- [Overreaching](#overreaching)
- [Correlations](#correlations)
- [Caffeine](#caffeine)
- [What is deliberately absent](#what-is-deliberately-absent)

---

## Readiness

**Method.** Four inputs, each converted to a robust z-score (median + MAD) against its
own trailing personal baseline, oriented so positive always means better, weighted, and
renormalised over whichever inputs were present.

| Input | Weight | Direction |
|---|---|---|
| Heart rate variability | 0.40 | higher is better |
| Resting heart rate | 0.30 | lower is better |
| Breathing rate | 0.20 | lower is better |
| Skin temperature | 0.10 | lower is better |

The composite z is mapped to 0–100 by a logistic, and gated by the smallest worthwhile
change: a composite inside your own normal variation is reported as **flat**, not as a
small change.

**What it can support.** "Today is unusually far from your normal, and resting heart
rate is the largest part of that."

**What it cannot support.** *Causation.* Contributions sum to the composite z **by
construction**, so they are a decomposition of a formula, not an explanation. The UI
says "contributed most", never "caused".

**When it abstains.** Baselines shorter than the minimum window. It never falls back to
population norms.

---

## Sleep score

Blends duration against need, efficiency, timing consistency, and accumulated debt.

Sleep need uses the highest-quality source available, in order:

1. Observed sleep duration on free nights (no alarm, no early obligation)
2. Blended personal/population estimate
3. Population prior

**Coverage is shown, not hidden.** A score built from half a night renders visibly less
certain rather than sitting beside an unread caveat.

---

## Deep sleep

**Read this section before trusting the deep number.** It is the least reliable figure
in the app, and this fork investigated it directly rather than shipping it quietly.

### The short version

Read **Light and Deep together as non-REM**. That total is sound. The split between them
is not.

### What was measured

Deep was reporting **2–3% of total sleep time** on real nights (8–24 minutes against
7.5-hour nights), versus a normal adult range of roughly 13–23%. An instrumented run of
the real stager over a real exported night ([`tool/deep_probe.dart`](https://github.com/isashahid10/analytics)
in the analytics repo) found:

```
NREM epochs:            615
  passed all 3 tests:   153  (24.9%)   ← physiologically normal
  after 3-minute merge:  29  ( 4.7%)   ← 81% deleted
```

The classifier is fine. A rule requiring **three unbroken minutes** before a deep bout
counts then removes four-fifths of what it found.

### Why the rule was not simply relaxed

Because it was tested, on two real nights, one of which has Apple Watch staging as a
reference (true deep = 38 min):

| Minimum run | Reference night | A later night |
|---|---|---|
| **180 s** (shipped) | 58 min — already 53% high | 15 min (3.1%) |
| 90 s | 94 min | 45 min |
| 60 s | **107 min — ~3× truth** | 55 min (11.8%) |

Loosening the threshold makes the under-reporting night look plausible while pushing the
one night that can actually be checked to nearly triple its true value. **Tuning a global
constant against a single ground-truth night is overfitting, not measurement.** The
constant was left alone.

### The cardiopulmonary coupling experiment

Thomas et al. (2005) established **high-frequency coupling (0.1–0.4 Hz)** as the signal
biomarker of *stable NREM sleep* — physiologically what "deep" is trying to name. This
pipeline already computed CPC every night and never used it for staging, so it was
tested two ways:

| Mode | Reference night (truth 38 min) | A later night |
|---|---|---|
| off (shipped) | 58 min | 15 min |
| **relax** — CPC allows shorter bouts | 89 min — much worse | 27 min |
| **gate** — CPC required for deep | **53 min — best** | **0 min — collapses** |

The gate moves the validated night meaningfully toward truth, then reports **zero**
minutes of deep on a night where the cardiac classifier flags a perfectly normal ~25% of
NREM. The two signal paths genuinely disagree there, and resolving that disagreement by
picking whichever answer suits is not measurement.

**So neither was shipped.** Staging is byte-for-byte unchanged. What ships instead is
the disagreement itself: on a night whose coupling is low-frequency dominant while deep
is non-zero, the UI says so.

### Context: this is not unique to this app

Real WHOOP hardware running WHOOP's own validated algorithm **underestimates slow-wave
sleep by 15.5 minutes** against polysomnography, with four-stage agreement of only 63%
(versus 86% for simple sleep/wake). In wearable staging models generally, deep sleep has
the **lowest sensitivity of any stage**.

Under-reporting deep is characteristic of the hardware class, not a defect introduced
here.

**References**
- [WHOOP validation vs PSG](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8226553/)
- [Fitbit / Garmin / WHOOP vs PSG, systematic review](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC11004611/)
- [CPC spectrogram as a biomarker of sleep stability](https://academic.oup.com/sleep/article/41/2/zsx196/4718136)
- [Stable vs unstable NREM](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC7744633/)

---

## Naps

Detected from sustained wrist immobility plus a heart-rate dip (van Hees-style), bounded
to 20 minutes – 3 hours, with the main sleep excluded so a night can never be counted
twice.

**Nap minutes are never added to nocturnal sleep.** Two reasons, and they push in
opposite directions:

- Short naps are overwhelmingly light sleep, so they are not equivalent minutes
- A nap *discharges* some of the homeostatic pressure driving the following night

Summing them would overstate both. They are reported alongside the night, never inside
it.

Stages are shown for naps over an hour and withheld below it — the stager derives its
within-sleep references partly from the session itself, and a 25-minute nap estimates
them from too few epochs for the split to mean anything.

---

## Steps

**Phone first, never summed.** Apple Health's count comes from the iPhone's dedicated
pedometer hardware and is a real measurement. The band's figure is used only when Health
has nothing for that day.

The band's number is **not a step count and physically cannot be**. Its always-on stream
is 1 Hz; human walking cadence is 1.4–2.5 Hz. By Nyquist, individual steps are
information-theoretically unrecoverable from that data — at 2.0 Hz cadence the gait
signal aliases exactly to DC. No algorithm can fix this.

So the band path measures what *is* resolvable at 1 Hz — **ambulatory minutes** — and
multiplies by a published free-living cadence band (Tudor-Locke 2011, ~100–130 steps/min)
to produce a **range**. While the app is open and streaming at ~100 Hz it counts real
steps (AN-2554, calibrated against a ground-truth walk).

A phone-sourced count is not badged as an estimate, because it is not one.

---

## Strength

All computed from logged sets. No wrist signal involved — load and reps are **directly
measured**, making this some of the highest-quality data in the app.

| Metric | Method | Confidence |
|---|---|---|
| Estimated 1RM | Epley (1985) and Brzycki (1993), averaged | Solid at low reps |
| RPE correction | Reps-in-reserve = 10 − RPE (Zourdos 2016) | Solid where RPE is logged honestly |
| Progression | Theil-Sen slope of e1RM (~29% breakdown point) | Describes direction, not a forecast |
| Weekly sets/muscle | Graded against Schoenfeld 2017 strata (<5, 5–9, 10+) | Group-level dose-response, not a personal prescription |

**Hard abstain above 12 reps.** Validation (LeSuer 1997) shows error growing with rep
count; past ~12 the estimate describes muscular endurance rather than maximal strength.

**Acute:chronic tonnage is reported as description only.** The ACWR injury-risk framing
(Gabbett 2016) has been seriously challenged on methodological grounds — mathematical
coupling and spurious correlation (Lolli 2019; Impellizzeri 2020) — and was developed for
team-sport GPS load, not barbell tonnage. The ratio is computed; no risk verdict is
attached to it.

---

## Bulk quality

Compares body-weight trend against strength trend to answer whether a surplus is
building muscle or just mass.

| Verdict | Condition |
|---|---|
| Productive | Weight up, strength up |
| Surplus too large | Weight up, strength flat or down |
| **Unknown** | **Strength trend unavailable** |

That last row is the load-bearing one. Without a strength trend the question is
unanswerable, and the code returns `unknown` rather than inferring from weight alone.

Needs 10 weigh-ins minimum. Rate bands at 0.25 and 0.5 %bw/week.

---

## Overreaching

Flags functional overreaching from **performance first**, corroborated by HRV
suppression (≥10%) and resting-HR elevation (≥3 bpm) against a 7-day baseline, sustained
across at least 4 consecutive days.

Performance is the **defining** criterion. HRV and resting HR alone describe a stressed
night; without a performance decrement there is no overreaching to report.

---

## Correlations

**Spearman rank correlation** (monotonic, robust to outliers and non-normal
distributions), with **Benjamini-Hochberg** false-discovery-rate control at q = 0.10.

**The hypothesis set is deliberately small.** With ~20 metrics, testing everything
against everything is 400 pairs, and FDR correction would then demand p-values so small
that a genuine moderate effect over 30 days could never clear the bar. Multiple-comparison
correction protects against false positives by making true positives harder to find, so
the family is kept deliberate: each pair needs a plausible physiological mechanism *and*
an actionable answer.

"Does protein move recovery" earns a slot. "Does humidity correlate with step count"
does not, however easy it would be to add.

**Lag encodes the causal story.** A predictor is tested against the *following* day's
outcome wherever the mechanism is overnight — protein eaten today cannot be caused by
tomorrow's recovery. Same-day pairs are used only where the mechanism is simultaneous,
and are labelled associations with no direction claimed.

**Fasted days are excluded.** Ramadan shifts eating, sleep and training at once, so
mixing those days in does not add statistical power — it adds a confounder correlated
with nearly every variable simultaneously.

Minimum 14 paired days. Below that, no result is reported.

---

## Caffeine

Exponential decay with a **5-hour half-life** — a reasonable population midpoint;
individual variation is large and genuine (CYP1A2 genotype, oral contraceptives,
smoking).

"Last safe coffee" solves `T × log₂(mg / target)` for the time at which the remaining
dose falls below a negligible threshold.

This is a **model**, not a measurement. There is no caffeine sensor in a wrist band.

---

## What is deliberately absent

Things that were considered and rejected, with reasons.

**Blood pressure estimation.** Cuffless PPG blood pressure requires cuff calibration to
be meaningful. WHOOP's own implementation requires it, and their feature drew an FDA
warning letter in July 2025. Without a cuff, any number here would be invention.

**Muscle-balance injury ratios.** The literature behind hamstring:quadriceps and similar
ratios uses **isokinetic dynamometry**, not gym set counts. Inferring one from the other
is unfounded. Volume distribution is reported as a plain description with no injury
claim attached.

**A single "sleep quality" verdict that hides its inputs.** Every composite in this app
shows its components.

**Population averages presented as personal baselines.** If your baseline is not
established, the app says so. It does not quietly substitute someone else's.

---

## A closing note on tiers

Analytics labels every metric with a confidence tier, and those labels are meant
literally:

| Tier | Meaning |
|---|---|
| `HIGH` | Directly measured, or derived by a well-validated method |
| `ESTIMATE` | A wrist estimate. Real, useful, not clinical |
| `absent` | Not enough data. Says what it is waiting for |

Nothing in this app is a medical device. Every number is an estimate from a
consumer-grade optical sensor on a wrist, and the ones that are shakier than the rest say
so on the screen where they appear.
