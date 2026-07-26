// live_coverage_policy.dart — pure, I/O-free policy for the 100 Hz step
// COVERAGE WINDOW. Nothing here touches BLE, the DB, Flutter or the clock:
// callers hand in the facts they observed for one live-pedometer session and
// read back the window to persist. Every branch is unit-testable.
//
// WHY THE WINDOW EXISTS
// `live_coverage` rows say "over THIS wall period the live 100 Hz pedometer
// counted real steps". The derivation pass adds those real steps to the day and
// EXCLUDES the minutes the window covers from the 1 Hz estimate, so a minute is
// counted by 100 Hz or estimated by 1 Hz — never both. A window is therefore a
// measurement, not a label: get its extent wrong and either minutes get counted
// twice (window too short) or real minutes lose their estimate (too long).
//
// WHICH FAILURE WE PREFER
// Too short fabricates steps that never happened (the same minute counted by
// both paths). Too long drops an estimate for minutes we may not have covered —
// an UNDER-report of something we genuinely did not measure at 100 Hz. Under
// the honesty contract the under-report wins, so when the evidence is
// ambiguous these rules lean toward the WIDER window.

import 'dart:math' as math;

/// Sample rate of the live accel stream the pedometer runs on.
const double kLiveSampleRateHz = 100.0;

/// Fraction of the session's wall-clock hull that must actually be sampled
/// before we treat the hull as the covered period.
///
/// The streamed time is a UNION of intervals; a `live_coverage` row can only
/// store its convex HULL. At/above this duty cycle the union dominates its own
/// hull (dropouts are the exception), so the hull is the better model of the
/// counting period and, per the preference above, the safer one. Below it the
/// session was mostly NOT streaming — a link that woke for a few seconds an
/// hour — and claiming the hull would silently delete hours of 1 Hz estimate
/// for a handful of real steps. There we fall back to the only quantity we
/// actually measured: the sampled duration.
const double kCoverageDutyFloor = 0.5;

/// Cadence ceiling used to derive a LOWER BOUND on elapsed time from a step
/// count. Elite sprint cadence tops out near 220 spm; 240 leaves headroom so
/// the bound is never tighter than physiology allows. This is a bound, never an
/// estimate: N steps cannot have happened in less than N / (240/60) seconds.
const double kMaxPlausibleCadenceSpm = 240.0;

/// A persisted 100 Hz coverage window, in the SAME epoch-second base as
/// `decoded_onehz.rec_ts` (see [deriveLiveCoverageWindow]).
class LiveCoverageWindow {
  const LiveCoverageWindow(this.startTs, this.endTs);
  final int startTs;
  final int endTs;
  int get seconds => endTs - startTs;

  @override
  String toString() => 'LiveCoverageWindow($startTs..$endTs, ${seconds}s)';
}

/// The shortest elapsed time [steps] could physically span, in whole seconds.
/// 0 for a non-positive count. See [kMaxPlausibleCadenceSpm].
int minCoverageSecondsForSteps(int steps) =>
    steps <= 0 ? 0 : (steps * 60 / kMaxPlausibleCadenceSpm).ceil();

/// Decide the coverage window for one live-pedometer session, or null when
/// there is nothing defensible to record.
///
/// TIME BASE. The window is compared against `decoded_onehz.rec_ts` by
/// `LocalDb.coverageWindowsOverlapping`, so it must stay in the BAND's record
/// time base. That is why the window is ANCHORED on [bandStartTs] — the record
/// timestamp carried by the first live frame — whenever the band supplied one,
/// and only falls back to the phone clock ([firstIngestMs]) when it never did.
/// The engine SET_CLOCKs the band to phone time on connect, so the two bases
/// agree to within the drift it already corrects, but we do not rely on that:
/// the ANCHOR comes from the band and only the DURATION comes from measurement,
/// and a duration is the same number in either base.
///
/// DURATION. Three observations bound the covered period:
///   * [samples100Hz] / [kLiveSampleRateHz] — the time we can PROVE we sampled
///     (each 100 Hz sample is 10 ms of covered signal). A lower bound.
///   * the wall-clock hull [firstIngestMs] … [lastIngestMs] — the outer extent
///     of the counting period, dropouts included. An upper bound.
///   * [bandStartTs] … [bandEndTs] — the same hull in band time, used only when
///     the phone timestamps are missing, because in practice the band repeats
///     one record timestamp for a whole live session (span 0) and cannot be
///     trusted to carry the duration.
/// The duty cycle between the first two picks which one models the session —
/// see [kCoverageDutyFloor]. The result is then raised to
/// [minCoverageSecondsForSteps] if the claimed [steps] could not physically fit
/// in it, and is never zero.
LiveCoverageWindow? deriveLiveCoverageWindow({
  required int steps,
  required int samples100Hz,
  int? bandStartTs,
  int bandEndTs = 0,
  int? firstIngestMs,
  int? lastIngestMs,
}) {
  // No real steps → nothing to exclude from the 1 Hz estimate, nothing to store.
  if (steps <= 0) return null;

  final int? anchor = (bandStartTs != null && bandStartTs > 0)
      ? bandStartTs
      : (firstIngestMs != null && firstIngestMs > 0
          ? firstIngestMs ~/ 1000
          : null);
  // Steps with no timestamp at all from either clock: we cannot place the
  // window on any timeline, and a misplaced window would exclude the WRONG
  // minutes. Drop it rather than invent a position.
  if (anchor == null) return null;

  final sampledS = samples100Hz <= 0 ? 0.0 : samples100Hz / kLiveSampleRateHz;

  double hullS = 0;
  if (firstIngestMs != null &&
      lastIngestMs != null &&
      lastIngestMs > firstIngestMs) {
    hullS = (lastIngestMs - firstIngestMs) / 1000.0;
  } else if (bandStartTs != null && bandEndTs > bandStartTs) {
    hullS = (bandEndTs - bandStartTs).toDouble();
  }

  double coveredS;
  if (hullS <= 0) {
    coveredS = sampledS; // no hull observed — the sampled time is all we have
  } else if (sampledS <= 0) {
    coveredS = hullS; // steps without sample accounting — hull is the evidence
  } else {
    final duty = sampledS / hullS;
    coveredS = duty >= kCoverageDutyFloor ? hullS : sampledS;
    // The sampled time can exceed the hull (duplicate/backlogged frames). The
    // hull is wall truth, so it also acts as the ceiling.
    if (coveredS > hullS) coveredS = hullS;
  }

  // Physiological floor — a true lower bound, applied last so a broken duration
  // measurement can never produce a window the steps could not fit into.
  var secs = coveredS.ceil();
  secs = math.max(secs, minCoverageSecondsForSteps(steps));
  // A window claiming steps is never zero-width: that silently disables the
  // no-double-count exclusion it exists to drive.
  if (secs < 1) secs = 1;
  return LiveCoverageWindow(anchor, anchor + secs);
}

/// Persistence-boundary guard: normalise a window before it reaches the
/// `live_coverage` table, or null when it must not be stored at all.
///
/// This is defence in depth behind [deriveLiveCoverageWindow] — an upstream
/// regression that stops advancing its clock must not be able to write a
/// zero-width window again without being repaired here.
///
/// REPAIR, NOT REJECT. Dropping the row would throw away a REAL 100 Hz step
/// count (the one measurement on the day that is not an estimate) and hand
/// those minutes back to the 1 Hz estimator. Widening the window to the
/// physically implied minimum ([minCoverageSecondsForSteps]) keeps the steps,
/// restores a non-degenerate exclusion, and claims only what a bound supports.
/// The one case that IS rejected is an inverted window (`endTs < startTs`):
/// that is incoherent rather than merely imprecise, and there is no defensible
/// way to decide which end was meant.
LiveCoverageWindow? sanitizeCoverageWindow(int startTs, int endTs, int steps) {
  if (steps <= 0) return null;
  if (endTs < startTs) return null;
  final minS = math.max(1, minCoverageSecondsForSteps(steps));
  if (endTs - startTs < minS) return LiveCoverageWindow(startTs, startTs + minS);
  return LiveCoverageWindow(startTs, endTs);
}
