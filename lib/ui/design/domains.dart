// Domain accents — one tasteful accent per health domain (the refs' bento
// cards each carry their own hue; the app stops leaning on a single coral for
// everything). Every colour resolves per-mode so both themes stay premium:
// light gets saturated-but-calm tones on paper, dark gets slightly lifted
// versions that read on char without turning neon.
//
// Use `DomainAccent.sleep` etc. wherever a card/visual belongs to a domain;
// keep `AppColors.accent` (brand cyan/teal) for brand moments. `heart` is a
// deliberate, contained exception: it keeps the ember coral as ITS domain
// identity (distinct from the app-wide brand accent, which moved off orange
// so genuinely low/urgent states stay legible) — every other domain below is
// a non-alert hue so nothing outside Heart/status colours reads as "urgent".

import 'package:flutter/widgets.dart';

import '../../theme/tokens.dart';

class DomainAccent {
  DomainAccent._();

  /// Heart / cardio — the brand ember coral.
  static Color get heart => AppColors.coral;

  /// Recovery / readiness — confident green.
  static Color get recovery => AppColors.good;

  /// Sleep — a PALE blue, deliberately distinct from strain's saturated blue.
  ///
  /// Sleep and strain sit side by side in the headline trio, so they cannot
  /// share a hue at the same saturation: at ring size the eye reads two
  /// identical blues as one repeated metric. Pale-vs-saturated separates them
  /// without introducing a fourth hue into a palette that is meant to stay
  /// small. (Was indigo #9D8CFF, which belonged to the old warm palette.)
  static Color get sleep => AppColors.isDark
      ? const Color(0xFF7BA1BB)
      : const Color(0xFF4A7391);

  /// Strain / training load — saturated blue. Exertion, not alarm; the amber
  /// this replaced read as a warning next to the red/yellow status colours.
  static Color get strain =>
      AppColors.isDark ? const Color(0xFF0093E7) : const Color(0xFF0077BC);

  /// Movement / steps — the same blue as strain.
  ///
  /// Steps ARE exertion, so they share exertion's colour rather than owning a
  /// teal of their own. Every hue that exists has to mean something; a
  /// separate colour for steps only added one more thing to decode.
  static Color get steps => strain;

  /// Energy / calories — exertion blue, not a colour of its own.
  ///
  /// The chartreuse this replaced was decorative: burning calories is not an
  /// evaluative state, so it has no business owning a hue in a palette where
  /// green means recovered and red means don't.
  static Color get calories => strain;

  /// Respiration / oxygen — pale blue, same family as sleep.
  static Color get oxygen => AppColors.loadDetraining;

  /// Stress / arousal — YELLOW, the middle-band colour.
  ///
  /// Was a rose-pink, which sat close enough to the red "don't" colour to be
  /// misread as one at small sizes while meaning something entirely different.
  /// Stress is a middling state, so it takes the middling colour.
  static Color get stress =>
      AppColors.isDark ? const Color(0xFFFFDE00) : const Color(0xFFB58900);

  /// Menstrual cycle — the one domain that keeps a hue of its own, because it
  /// is genuinely orthogonal to the recovered/exerted/alarmed axis the rest of
  /// the palette encodes and would be unreadable folded into it.
  static Color get cycle =>
      AppColors.isDark ? const Color(0xFFE08BC0) : const Color(0xFFB2467F);

  /// Deeper companion for the cycle domain (ovulation/luteal marks).
  static Color get cyclePlum =>
      AppColors.isDark ? const Color(0xFFB48BE0) : const Color(0xFF7C4A9E);

  /// Sleep-stage palette (Awake / REM / Light / Deep).
  ///
  /// One ramp, not four unrelated hues: the stages are ordered by depth, so
  /// they read as a sequence from pale (awake) to saturated (deep) rather than
  /// as four separate categories that have to be looked up in a legend.
  static Color get stageAwake => AppColors.inkMuted;
  static Color get stageRem =>
      AppColors.isDark ? const Color(0xFF9EC5DC) : const Color(0xFF6A93B0);
  static Color get stageLight =>
      AppColors.isDark ? const Color(0xFF4E7FA3) : const Color(0xFF3D6B8C);
  static Color get stageDeep =>
      AppColors.isDark ? const Color(0xFF1E4E70) : const Color(0xFF1B3E59);
}
