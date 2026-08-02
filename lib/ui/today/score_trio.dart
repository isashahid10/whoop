// score_trio.dart — the three headline rings.
//
// This is the one screen element people recognise instantly: three rings in a
// row, each a whole domain reduced to one number. The reason it works is not
// the shape, it is the DISCIPLINE — exactly three, always the same three, in
// the same order, every day. The moment a fourth ring gets added "because it
// matters too", the row stops being a glance and becomes a dashboard.
//
// The three chosen here are the three questions worth asking on waking:
//
//   SLEEP      did last night restore me?      (composite, analytics)
//   READINESS  what does today's body allow?   (HRV ∩ sleep ∩ dip ∩ arousal)
//   STRAIN     what have I spent so far?       (accumulates through the day)
//
// Sleep and Readiness are 0-100 and read as percentages. Strain is NOT — it is
// a 0-21 logarithmic scale, so it is rendered against 21 and never suffixed
// with a percent sign. Showing "14.2%" would be a different, wrong number.
//
// ABSENCE IS RENDERED, NOT HIDDEN. A ring with no data shows a dash and an
// empty track rather than disappearing, so the row keeps its shape and a
// missing night is visibly missing instead of silently absent.

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../design/arc_gauge.dart';
import '../design/pressable.dart';

/// One ring in the trio.
class ScoreRingData {
  final String label;

  /// 0-100 for the scored domains; null when unmeasured.
  final double? value;

  /// What to print in the middle. Kept separate from [value] because Strain
  /// prints "14.2" while filling only 14.2/21 of its ring.
  final String? display;

  /// Fill fraction 0..1. Null when there is nothing to fill.
  final double? fill;

  final Color color;

  /// 0..1 — fades the arc when the underlying figure is uncertain, so a
  /// low-confidence score LOOKS less certain instead of reading as fact.
  final double confidence;

  /// Unit printed after [display] at a smaller size — "%" for the scored
  /// domains. Strain passes null: it is a 0-21 scale, not a percentage.
  final String? unit;

  /// Shown under the ring when the number is absent, e.g. "no sleep recorded".
  final String? absentHint;

  final VoidCallback? onTap;

  const ScoreRingData({
    required this.label,
    required this.color,
    this.value,
    this.display,
    this.fill,
    this.unit,
    this.confidence = 1,
    this.absentHint,
    this.onTap,
  });

  bool get measured => display != null;
}

class ScoreTrio extends StatelessWidget {
  final List<ScoreRingData> rings;

  /// Ring diameter. The default fits three across a 390 pt phone with the
  /// standard screen padding and still leaves the numbers legible.
  final double size;

  const ScoreTrio({super.key, required this.rings, this.size = 104});

  @override
  Widget build(BuildContext context) {
    // Size the rings from the ACTUAL width rather than trusting the 104 pt
    // default. On a narrow phone — or inside a card with its own padding —
    // three fixed rings plus their labels overflow, and an overflow here is a
    // visible red-striped bar across the top of the home screen.
    return LayoutBuilder(
      builder: (context, c) {
        final perRing = c.maxWidth / rings.length;
        final d = size.clamp(64.0, (perRing - 8).clamp(64.0, size));
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final r in rings)
              Expanded(
                child: _Ring(data: r, size: d.toDouble()),
              ),
          ],
        );
      },
    );
  }
}

class _Ring extends StatelessWidget {
  final ScoreRingData data;
  final double size;

  const _Ring({required this.data, required this.size});

  @override
  Widget build(BuildContext context) {
    final measured = data.measured;

    final ring = ArcGauge(
      // NaN is the gauge's own "empty track" signal — deliberately not 0,
      // which would paint a real ring at zero and read as a genuine score of
      // nothing rather than as no measurement at all.
      value: measured ? (data.fill ?? 0).clamp(0.0, 1.0) : double.nan,
      color: measured ? data.color : AppColors.inkMuted,
      size: size,
      stroke: 8,
      // A closed ring, not the 270° arc used elsewhere: three open arcs in a
      // row read as broken, and the gap adds nothing at this size.
      sweepFraction: 1.0,
      endDot: measured,
      confidence: measured ? data.confidence : 1,
      // The number+unit pair is scaled to the ring's inner area rather than
      // laid out freely: "12.4%" at 30 pt is wider than a small ring's bore,
      // and an unconstrained Row inside the gauge overflows instead of
      // shrinking. FittedBox makes the type size follow the ring size, which
      // is also what keeps the trio legible on a narrow phone.
      center: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              data.display ?? '—',
              style: AppText.metricSm.copyWith(
                fontSize: 30,
                color: measured ? AppColors.ink : AppColors.onSurfaceFaint,
              ),
            ),
            if (measured && data.unit != null)
              // A hair of lead so the unit does not collide with the last
              // digit's overhang at these weights.
              Padding(
                padding: const EdgeInsets.only(left: 1.5),
                child: Text(
                  data.unit!,
                  style: AppText.metricSm.copyWith(
                    fontSize: 15,
                    color: measured ? AppColors.ink : AppColors.onSurfaceFaint,
                  ),
                ),
              ),
          ],
        ),
      ),
    );

    // The WHOLE column is the tap target, not just the ring. A 104 pt circle
    // with a caption floating untappable underneath it fails the obvious
    // gesture — tapping the word "SLEEP" — and the label is the part people
    // aim at when the number is a dash.
    return Pressable(
      onTap: data.onTap,
      borderRadius: BorderRadius.circular(R.cardSm),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ring,
          const SizedBox(height: Sp.x2),
          // The label scales down rather than overflowing: "READINESS" is
          // wider than a 104 pt ring at this tracking, and clipping a word is
          // worse than shrinking it a point.
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              data.label.toUpperCase(),
              // NEUTRAL, not tinted with the ring colour. The ring already
              // carries the hue; repeating it in the label doubles the colour
              // load on a row that is meant to be read as three numbers, and it
              // pushes small text below contrast on a saturated hue.
              style: AppText.overline.copyWith(
                color: measured ? AppColors.inkSoft : AppColors.inkMuted,
                letterSpacing: 1.2,
              ),
              maxLines: 1,
            ),
          ),
          if (!measured && data.absentHint != null) ...[
            const SizedBox(height: 2),
            Text(
              data.absentHint!,
              textAlign: TextAlign.center,
              style: AppText.captionMuted.copyWith(fontSize: 10),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}
