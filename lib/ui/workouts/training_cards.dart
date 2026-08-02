// training_cards.dart — bulk quality and overreaching, on screen.
//
// Both analyses exist to tell you something you might not want to hear, so the
// presentation rules matter as much as the maths:
//
//   * THE VERDICT LEADS. One line, plain words. Not a gauge, not a score — the
//     answer to "is this working" is a sentence, and dressing it as a number
//     would imply a precision the inputs do not carry.
//   * THE EVIDENCE IS VISIBLE UNDERNEATH. Weight slope, strength slope, day
//     counts. A verdict you cannot audit is one you cannot argue with, and
//     these are exactly the conclusions worth arguing with.
//   * ABSTENTION RENDERS. When there is not enough data the card says what is
//     missing and how much more is needed, rather than disappearing — "no data
//     yet" is information, and a vanishing card reads as a bug.

import 'package:flutter/material.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;

import '../design/design.dart';

// ── bulk quality ─────────────────────────────────────────────────────────────

class BulkQualityCard extends StatelessWidget {
  final ana.BulkAssessment bulk;
  const BulkQualityCard({super.key, required this.bulk});

  static String _verdictLabel(ana.BulkVerdict v) => switch (v) {
        ana.BulkVerdict.productive => 'Productive',
        ana.BulkVerdict.surplusTooLarge => 'Surplus too large',
        ana.BulkVerdict.recomposition => 'Recomposition',
        ana.BulkVerdict.maintenance => 'Maintenance',
        ana.BulkVerdict.cuttingWell => 'Cutting well',
        ana.BulkVerdict.underfuelled => 'Under-fuelled',
        ana.BulkVerdict.unknown => 'Not enough data',
      };

  /// Colour carries the same meaning it does everywhere else in the app:
  /// green is good, yellow is middling, red is act on this.
  static Color _verdictColor(ana.BulkVerdict v) => switch (v) {
        ana.BulkVerdict.productive ||
        ana.BulkVerdict.recomposition ||
        ana.BulkVerdict.cuttingWell =>
          AppColors.good,
        ana.BulkVerdict.maintenance => AppColors.warn,
        ana.BulkVerdict.surplusTooLarge ||
        ana.BulkVerdict.underfuelled =>
          AppColors.bad,
        ana.BulkVerdict.unknown => AppColors.inkMuted,
      };

  static String _kg(double v) =>
      '${v >= 0 ? '+' : ''}${v.toStringAsFixed(2)} kg';

  @override
  Widget build(BuildContext context) {
    final measured = bulk.measured;
    final color = _verdictColor(bulk.verdict);

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('BODY COMPOSITION',
                  style: AppText.overline
                      .copyWith(color: AppColors.inkSoft, letterSpacing: 1.1)),
              const Spacer(),
              InfoDot(
                title: 'Is the bulk working?',
                body: 'On a surplus the scale always climbs - that alone tells '
                    'you nothing. What separates a productive bulk from an '
                    'expensive one is whether STRENGTH climbs with it.\n\n'
                    'Weight comes from Apple Health; the strength trend is the '
                    'estimated 1RM slope from your logged sets, which is '
                    'directly measured load and reps rather than anything '
                    'inferred from the wrist.\n\n'
                    'The rate band (0.25-0.5% of bodyweight per week) is the '
                    'range every rate-of-gain framework converges on for an '
                    'intermediate lifter. Gaining materially faster than that '
                    'is adding fat, by arithmetic.\n\n'
                    'This deliberately does NOT estimate body-fat percentage - '
                    'that needs a measurement the app does not have.',
                methodNote: bulk.basis,
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Text(
            _verdictLabel(bulk.verdict),
            style: AppText.h2.copyWith(color: color),
          ),
          if (bulk.advice != null) ...[
            const SizedBox(height: 2),
            Text(bulk.advice!, style: AppText.bodySoft),
          ],
          if (!measured) ...[
            const SizedBox(height: Sp.x2),
            Text(bulk.basis, style: AppText.captionMuted),
          ],
          if (measured) ...[
            const SizedBox(height: Sp.x4),
            Row(
              children: [
                _stat(
                  bulk.weightKgPerWeek == null
                      ? '—'
                      : _kg(bulk.weightKgPerWeek!),
                  'per week',
                ),
                _stat(
                  bulk.bodyweightPctPerWeek == null
                      ? '—'
                      : '${bulk.bodyweightPctPerWeek!.toStringAsFixed(2)}%',
                  _rateLabel(bulk.rate),
                  color: _rateColor(bulk.rate),
                ),
                _stat(
                  bulk.strengthKgPerWeek == null
                      ? '—'
                      : _kg(bulk.strengthKgPerWeek!),
                  'strength/wk',
                ),
              ],
            ),
            const SizedBox(height: Sp.x3),
            Text(bulk.basis, style: AppText.captionMuted),
          ],
        ],
      ),
    );
  }

  static String _rateLabel(ana.GainRate r) => switch (r) {
        ana.GainRate.tooFast => 'too fast',
        ana.GainRate.onTarget => 'on target',
        ana.GainRate.tooSlow => 'slow',
        ana.GainRate.losing => 'losing',
        ana.GainRate.unknown => 'of bodyweight',
      };

  static Color? _rateColor(ana.GainRate r) => switch (r) {
        ana.GainRate.tooFast => AppColors.warn,
        ana.GainRate.onTarget => AppColors.good,
        _ => null,
      };

  Widget _stat(String value, String label, {Color? color}) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(value,
                style: AppText.metricSm
                    .copyWith(fontSize: 20, color: color ?? AppColors.ink)),
            Text(label, style: AppText.captionMuted),
          ],
        ),
      );
}

// ── overreaching ─────────────────────────────────────────────────────────────

class OverreachingCard extends StatelessWidget {
  final ana.OverreachingSignal signal;
  const OverreachingCard({super.key, required this.signal});

  static String _label(ana.TrainingStatus s) => switch (s) {
        ana.TrainingStatus.ok => 'Absorbing the load',
        ana.TrainingStatus.watch => 'Worth watching',
        ana.TrainingStatus.overreached => 'Deload',
        ana.TrainingStatus.unknown => 'Still learning you',
      };

  static Color _color(ana.TrainingStatus s) => switch (s) {
        ana.TrainingStatus.ok => AppColors.good,
        ana.TrainingStatus.watch => AppColors.warn,
        ana.TrainingStatus.overreached => AppColors.bad,
        ana.TrainingStatus.unknown => AppColors.inkMuted,
      };

  @override
  Widget build(BuildContext context) {
    final color = _color(signal.status);
    final known = signal.status != ana.TrainingStatus.unknown;

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('TRAINING STATUS',
                  style: AppText.overline
                      .copyWith(color: AppColors.inkSoft, letterSpacing: 1.1)),
              const Spacer(),
              InfoDot(
                title: 'Overreaching',
                body: 'Three markers, and all three have to agree:\n\n'
                    '• strength stalling or falling\n'
                    '• HRV suppressed against your own baseline\n'
                    '• resting heart rate elevated against it\n\n'
                    'Any one alone is noise - HRV drops after a late meal, '
                    'resting HR rises in a warm room, and a bad session is '
                    'just a bad session. Acting on one marker produces an app '
                    'that cries wolf, and one that cries wolf gets ignored '
                    'exactly when it is right.\n\n'
                    'Falling performance is REQUIRED: without it, suppressed '
                    'HRV and raised resting HR are a rough week of sleep, not '
                    'overreaching.\n\n'
                    'This says "back off". It cannot diagnose overtraining '
                    'syndrome - that needs performance testing over weeks and '
                    'the exclusion of medical causes.',
                methodNote: signal.basis,
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          Text(_label(signal.status), style: AppText.h2.copyWith(color: color)),
          if (signal.advice != null) ...[
            const SizedBox(height: 2),
            Text(signal.advice!, style: AppText.bodySoft),
          ],
          const SizedBox(height: Sp.x4),
          // The three markers, always all three — showing only the ones that
          // are firing would hide the fact that the others were checked.
          _marker('Strength', signal.performanceDown,
              signal.strengthKgPerWeek == null
                  ? 'no clear trend'
                  : '${signal.strengthKgPerWeek! >= 0 ? '+' : ''}'
                      '${signal.strengthKgPerWeek!.toStringAsFixed(2)} kg/wk'),
          _marker('HRV', signal.hrvSuppressed,
              signal.hrvDeltaPct == null
                  ? 'no baseline yet'
                  : '${signal.hrvDeltaPct! >= 0 ? '+' : ''}'
                      '${signal.hrvDeltaPct!.round()}% vs baseline'),
          _marker('Resting HR', signal.rhrElevated,
              signal.rhrDeltaBpm == null
                  ? 'no baseline yet'
                  : '${signal.rhrDeltaBpm! >= 0 ? '+' : ''}'
                      '${signal.rhrDeltaBpm!.toStringAsFixed(1)} bpm'),
          if (!known) ...[
            const SizedBox(height: Sp.x2),
            Text(signal.basis, style: AppText.captionMuted),
          ],
        ],
      ),
    );
  }

  Widget _marker(String label, bool firing, String detail) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
              firing ? Icons.error_outline_rounded : Icons.check_circle_outline,
              size: 16,
              color: firing ? AppColors.warn : AppColors.inkMuted,
            ),
            const SizedBox(width: Sp.x3),
            Expanded(child: Text(label, style: AppText.body)),
            Text(detail, style: AppText.captionMuted),
          ],
        ),
      );
}
