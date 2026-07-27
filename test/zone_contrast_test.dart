// Legibility guard for the HR-zone ramp on the live session screen.
//
// The live workout screen paints on AppColors.night/nightAlt regardless of the
// user's theme, so its zone colours cannot come from the ACTIVE palette. Two
// real bugs came out of that:
//
//   1. In light mode the ramp handed back hues tuned for a white background
//      and painted them on near-black.
//   2. Even on the dark palette, Z0 mapped to `cool` — a SURFACE token, not an
//      ink. As a foreground it measured 1.03:1 against nightAlt: invisible.
//      Z0 is the RESTING zone, so it is what is on screen at the start of
//      every workout and whenever heart rate is low or absent.
//
// These assert the fix numerically rather than by eye, so a palette edit can't
// silently reintroduce an unreadable zone.

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/theme/tokens.dart';

/// WCAG 2.1 relative luminance.
double _luminance(Color c) {
  double channel(double v) {
    final s = v / 255.0;
    return s <= 0.03928 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  return 0.2126 * channel((c.r * 255).roundToDouble()) +
      0.7152 * channel((c.g * 255).roundToDouble()) +
      0.0722 * channel((c.b * 255).roundToDouble());
}

/// WCAG 2.1 contrast ratio, 1.0 (identical) … 21.0 (black on white).
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // 3:1 is the WCAG AA floor for large text and non-text UI components, which
  // is what these are: big tabular figures and coloured indicators.
  const minRatio = 3.0;

  group('zoneOnDark is legible on the session surface', () {
    for (final surface in <String, Color>{
      'night': AppColors.night,
      'nightAlt': AppColors.nightAlt,
    }.entries) {
      for (var z = 0; z <= 5; z++) {
        test('Z$z on ${surface.key} clears $minRatio:1', () {
          final ratio = _contrast(AppColors.zoneOnDark(z), surface.value);
          expect(
            ratio,
            greaterThanOrEqualTo(minRatio),
            reason: 'Z$z renders at ${ratio.toStringAsFixed(2)}:1 on '
                '${surface.key} — unreadable. Zone colours on the live '
                'session screen must be inks, not surface tokens.',
          );
        });
      }
    }

    test('Z0 specifically — the regression that shipped', () {
      // `cool` is what Z0 used to resolve to. Pin the old value as a failing
      // reference so the intent of the fix stays legible.
      final broken = _contrast(kDarkPalette.cool, AppColors.nightAlt);
      final fixed = _contrast(AppColors.zoneOnDark(0), AppColors.nightAlt);
      expect(broken, lessThan(1.5), reason: 'the old Z0 was invisible');
      expect(fixed, greaterThan(6.0), reason: 'the new Z0 is clearly legible');
    });
  });

  test('the ramp is independent of the ACTIVE palette', () {
    // The live screen is always dark; flipping the app theme must not change
    // a single zone colour on it.
    AppColors.active = kLightPalette;
    final inLight = [for (var z = 0; z <= 5; z++) AppColors.zoneOnDark(z)];
    AppColors.active = kDarkPalette;
    final inDark = [for (var z = 0; z <= 5; z++) AppColors.zoneOnDark(z)];
    addTearDown(() => AppColors.active = kLightPalette);
    expect(inLight, equals(inDark));
  });
}
