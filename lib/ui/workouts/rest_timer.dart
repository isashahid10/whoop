// rest_timer.dart — rest until RECOVERED, not until a fixed clock runs out.
//
// A fixed three-minute timer is a proxy for the thing you actually care about:
// whether your cardiovascular system has come back down enough to produce a
// quality next set. Some days that takes 90 seconds, some days it takes four
// minutes, and the timer cannot tell the difference. The band can.
//
// THE TARGET is a percentage of heart-rate reserve rather than a raw bpm, so
// it means the same thing to any user and at any fitness level:
//
//     HRR% = (HR - resting) / (max - resting)
//
// Karvonen's formula, and the reason the target is expressed this way: a raw
// "rest until 110 bpm" is a completely different ask for someone with a
// resting HR of 45 than for someone at 70.
//
// WHY ~40% HRR. Between-set recovery guidance for strength work centres on
// returning near the pre-set state; the practical convention used by HR-guided
// interval work is a return toward roughly 30-40% of reserve before the next
// hard effort. This is a heuristic, not a validated protocol, and the UI says
// so — the honest claim is "your HR has come back down", not "you are
// physiologically ready".
//
// A FLOOR AND A CEILING both matter. Too short and the timer fires while you
// are still racking the bar; too long and a band that has lost contact leaves
// you waiting forever. Both are bounded.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/db.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

/// Fraction of heart-rate reserve to drop to before the set is "ready".
const double kRestTargetHrr = 0.40;

/// Never fire before this — racking the bar and getting set takes time
/// regardless of what the heart is doing.
const Duration kRestMin = Duration(seconds: 45);

/// Always fire by this, whatever the HR says. A band that has lost skin
/// contact reports a stale or absent HR, and an honest timeout beats waiting
/// on a number that is never going to arrive.
const Duration kRestMax = Duration(minutes: 5);

class RestTimerSheet extends StatefulWidget {
  /// Resting HR, from the user's own baseline. Null falls back to a stated
  /// default rather than silently assuming one.
  final int? restingHr;

  /// Age-predicted or measured max HR.
  final int? maxHr;

  const RestTimerSheet({super.key, this.restingHr, this.maxHr});

  @override
  State<RestTimerSheet> createState() => _RestTimerSheetState();
}

class _RestTimerSheetState extends State<RestTimerSheet> {
  Timer? _tick;
  late final DateTime _start;
  bool _ready = false;

  /// The highest HR seen since the sheet opened — the peak of the set just
  /// finished, used to show how far you have come down.
  int? _peak;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => _evaluate());
    _loadResting();
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  /// Resting HR, loaded from the user's own recent nights.
  int? _restingFromBaseline;

  /// The user's measured resting HR when one exists, else a STATED default.
  ///
  /// 60 bpm is a population figure, and using it silently for a trained
  /// individual whose true resting HR is 48 would put the target ~7 bpm too
  /// high — the timer would fire early, every set.
  int get _resting => widget.restingHr ?? _restingFromBaseline ?? 60;
  int get _max => widget.maxHr ?? 190;

  /// Median resting HR over the last fortnight — median rather than latest so
  /// one bad night cannot move the target.
  Future<void> _loadResting() async {
    if (widget.restingHr != null) return;
    try {
      final db = await LocalDb.instance;
      final rows = await db.query(
        'metric_series',
        columns: ['value'],
        where: 'key = ?',
        whereArgs: ['rhr'],
        orderBy: 'date DESC',
        limit: 14,
      );
      final xs = <double>[
        for (final r in rows) ?(r['value'] as num?)?.toDouble(),
      ]..sort();
      if (xs.isEmpty || !mounted) return;
      setState(() => _restingFromBaseline = xs[xs.length ~/ 2].round());
    } catch (_) {
      // Falls back to the stated default.
    }
  }

  /// The bpm that corresponds to the target reserve fraction.
  int get _targetBpm =>
      (_resting + (_max - _resting) * kRestTargetHrr).round();

  void _evaluate() {
    if (!mounted || _ready) return;
    final hr = context.read<AppState>().device.liveHr;
    if (hr != null && hr > 0 && (_peak == null || hr > _peak!)) _peak = hr;

    final elapsed = DateTime.now().difference(_start);
    if (elapsed < kRestMin) {
      setState(() {});
      return;
    }
    // Either the heart has come back down, or the ceiling has been reached.
    final recovered = hr != null && hr > 0 && hr <= _targetBpm;
    if (recovered || elapsed >= kRestMax) {
      _tick?.cancel();
      setState(() => _ready = true);
      // A short haptic rather than a sound: this fires in a gym, where a tone
      // is either inaudible or embarrassing.
      Feedback.forTap(context);
    } else {
      setState(() {});
    }
  }

  String _mmss(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final hr = context.select<AppState, int?>((a) => a.device.liveHr);
    final elapsed = DateTime.now().difference(_start);
    final hasHr = hr != null && hr > 0;

    // Progress from the set's peak down to the target, which is what the user
    // is actually waiting on — elapsed time is the wrong axis here.
    double? progress;
    if (hasHr && _peak != null && _peak! > _targetBpm) {
      final span = (_peak! - _targetBpm).toDouble();
      progress = ((_peak! - hr) / span).clamp(0.0, 1.0);
    }

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x4, Sp.screen, Sp.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _ready ? 'Ready' : 'Recovering',
              style: AppText.h1.copyWith(
                color: _ready ? AppColors.good : AppColors.ink,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Sp.x2),
            Text(
              _ready
                  ? (hasHr && hr <= _targetBpm
                      ? 'Heart rate is back down.'
                      : 'Rest ceiling reached.')
                  : (hasHr
                      ? 'Waiting for $_targetBpm bpm'
                      : 'Waiting for the band…'),
              style: AppText.captionMuted,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: Sp.x5),
            Center(
              child: ArcGauge(
                value: progress ?? double.nan,
                color: _ready ? AppColors.good : DomainAccent.heart,
                size: 168,
                stroke: 12,
                sweepFraction: 0.75,
                endDot: progress != null,
                valueText: hasHr ? '$hr' : '—',
                label: 'bpm',
              ),
            ),
            const SizedBox(height: Sp.x5),
            Row(
              children: [
                _stat(_mmss(elapsed), 'elapsed'),
                _stat(_peak == null ? '—' : '$_peak', 'set peak'),
                _stat('$_targetBpm', 'target'),
              ],
            ),
            const SizedBox(height: Sp.x5),
            Pressable(
              onTap: () => Navigator.of(context).pop(),
              borderRadius: BorderRadius.circular(R.pill),
              child: Container(
                alignment: Alignment.center,
                padding: const EdgeInsets.symmetric(vertical: 13),
                decoration: BoxDecoration(
                  color: AppColors.tonalFill(
                      _ready ? AppColors.good : AppColors.inkMuted),
                  borderRadius: BorderRadius.circular(R.pill),
                ),
                child: Text(
                  _ready ? 'Next set' : 'Skip rest',
                  style: AppText.label.copyWith(
                    color: _ready ? AppColors.good : AppColors.inkSoft,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
            const SizedBox(height: Sp.x3),
            Text(
              'Rest ends when your heart rate returns to '
              '${(kRestTargetHrr * 100).round()}% of reserve, or after '
              '${kRestMax.inMinutes} minutes. A guide, not a protocol.',
              style: AppText.captionMuted.copyWith(fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String v, String label) => Expanded(
        child: Column(
          children: [
            Text(v, style: AppText.metricSm.copyWith(fontSize: 20)),
            Text(label, style: AppText.captionMuted),
          ],
        ),
      );
}

/// Open the rest timer.
Future<void> showRestTimer(
  BuildContext context, {
  int? restingHr,
  int? maxHr,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    // Not dismissible by tapping away: the whole point is that it runs until
    // recovered, and an accidental tap mid-set would lose it.
    isDismissible: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
    ),
    builder: (_) => RestTimerSheet(restingHr: restingHr, maxHr: maxHr),
  );
}
