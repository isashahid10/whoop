// OrbitScore — the whole-health hero: one radial score, and nothing else
// competing with it. The center carries the label, the big number, and the
// status chip. Restrained by design: no glow by default, no particles —
// presence comes from scale and negative space.
//
// It used to float up-to-four tappable domain "satellites" on concentric
// orbits around the core. Those were cut from the Today hero (that data
// already lives one tap away on its own tab, and at near-equal visual weight
// they fought the score), and with no caller left the whole orbit/satellite
// layer went with them.
//
//   OrbitScore(
//     score: 82,                        // null → honest baseline/empty center
//     word: 'Push', wordIcon: OsIcon.intensity,   // rendered as a state chip
//     color: AppColors.scoreColor(0.82),
//   )

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/theme.dart';
import '../../theme/tokens.dart';
import '../kit/kit.dart' show OsIcon;
import 'arc_gauge.dart';
import 'motion.dart';
import 'pressable.dart';
import 'state_chips.dart';

class OrbitScore extends StatelessWidget {
  /// 0–100 score. Null renders [center] (the honest building/empty state).
  final int? score;

  /// Status word under the number ('Push', 'Focus', 'Recover'). Rendered as a
  /// calm [StateChipView] pill tinted with [color], so the ring's verdict
  /// reads as a state you're *in* rather than a loose caption.
  final String? word;

  /// Optional glyph for the [word] chip. Null renders the word alone.
  final OsIcon? wordIcon;

  /// Whispered overline above the number ('READINESS').
  final String? label;

  final Color? color;

  /// Ring confidence (dashed < 0.4, fades when low) — same contract as
  /// [ArcGauge].
  final double confidence;

  /// Replaces the score center when [score] is null (e.g. a nights-to-go
  /// baseline gauge).
  final Widget? center;

  /// Ring fill override for the null-score state — e.g. baseline progress
  /// (2 of 5 nights = 0.4) while the honest center explains it.
  final double? ringFill;

  /// Tap on the score core itself.
  final VoidCallback? onTap;

  final double height;

  /// Static glow layer behind the core arc — see [ArcGauge.glow]. Off by
  /// default (mini/gallery uses); the Today readiness hero turns it on.
  final bool glow;

  const OrbitScore({
    super.key,
    required this.score,
    this.word,
    this.wordIcon,
    this.label,
    this.color,
    this.confidence = 1.0,
    this.center,
    this.ringFill,
    this.onTap,
    this.height = 280,
    this.glow = false,
  });

  @override
  Widget build(BuildContext context) {
    final c = color ?? AppColors.accent;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return SizedBox(
      height: height,
      child: LayoutBuilder(
        builder: (context, box) {
          final w = box.maxWidth;
          final side = math.min(w, height);
          // The ring IS the composition — let it fill most of the shorter
          // side and give it generous surrounding negative space.
          final coreSize = (side * 0.72).clamp(160.0, 224.0);

          Widget core = ArcGauge(
            value: score == null
                ? (ringFill ?? double.nan)
                : (score! / 100).clamp(0.0, 1.0),
            color: c,
            size: coreSize,
            stroke: 13,
            sweepFraction: 0.78,
            confidence: confidence,
            glow: glow,
            // The entrance pop (animatedCore, below) already skips itself
            // under reduced motion; ArcGauge's own internal fill-sweep
            // reveal needs the same treatment, or the arc still visibly
            // sweeps in even with system animations disabled.
            animate: !reduceMotion,
            center:
                center ??
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (label != null)
                      Text(
                        label!.toUpperCase(),
                        style: AppText.overline.copyWith(
                          fontSize: (coreSize * 0.062).clamp(8.0, 11.0),
                        ),
                      ),
                    Text(
                      score == null ? '—' : '$score',
                      style: AppText.display.copyWith(
                        fontSize: coreSize * 0.32,
                        color: score == null ? AppColors.inkMuted : null,
                      ),
                    ),
                    if (word != null) ...[
                      const SizedBox(height: Sp.x1),
                      StateChipView(
                        StateChip(word!, icon: wordIcon),
                        selected: true,
                        accent: c,
                        dense: true,
                      ),
                    ],
                  ],
                ),
          );
          if (onTap != null) {
            core = Pressable(pressedScale: 0.96, onTap: onTap, child: core);
          }

          // Spring-physics entrance: a slight overshoot pop on first build,
          // never on rebuild (AnimatedContainer-free TweenAnimationBuilder,
          // 0.85 → 1.0). Skipped entirely under reduced-motion — the ring
          // just renders at its final scale, no animation to reduce.
          Widget animatedCore = core;
          if (!reduceMotion) {
            animatedCore = TweenAnimationBuilder<double>(
              tween: Tween(begin: 0.85, end: 1.0),
              duration: Motion.ring,
              curve: Curves.easeOutBack,
              builder: (_, scale, child) =>
                  Transform.scale(scale: scale, child: child),
              child: core,
            );
          }

          return Center(child: animatedCore.dsEnter());
        },
      ),
    );
  }

}


