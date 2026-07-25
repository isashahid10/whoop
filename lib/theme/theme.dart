// OpenStrap theme — TWO type voices, ember-coral on paper (day) or char
// (night). `AppText` is the type scale; every numeric/metric style carries
// tabular figures so big numbers align and count-ups don't jitter. Text colours
// resolve through the live `AppColors` getters, so the type scale follows the
// active mode for free.
//
// Why two voices: a hero number (Readiness, Strain, Sleep score) and a
// plain-language sentence (an AI briefing, an insight caption) are two
// different KINDS of information and should read that way.
//  - `hero`/`display`/`metric`/`metricSm` (the big tabular figures) use
//    Barlow Condensed at heavy weight + slight tracking — confident and
//    kinetic, athletic-brand register.
//  - Everything else (`h1`/`h2`/`title`/`body`/`bodySoft`/`label`/`caption`/
//    `overline`) stays Manrope — a calmer, more humane sans for prose,
//    labels and headings, reading like a person talking rather than a data
//    readout.
// Both are Google Fonts already wired through the `google_fonts` package
// (no new asset pipeline) — adding Barlow Condensed alongside Manrope is a
// one-line change per style, not a new dependency.
//
// `buildOpenStrapTheme(palette)` builds a full ThemeData from an explicit
// [Palette] (not the live getters) so the light + dark ThemeData objects are
// each internally consistent regardless of which mode is currently active.

import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'page_transitions.dart';
import 'tokens.dart';

/// Type scale — one family (Manrope). Numerics carry tabular figures.
/// Colours come from the live [AppColors] getters → they track the active mode.
class AppText {
  AppText._();

  static const _tnum = [FontFeature.tabularFigures()];

  // ── Display / numerics — Barlow Condensed: heavy, tight, tabular, kinetic ──
  static TextStyle get hero => GoogleFonts.barlowCondensed(
    fontSize: 68,
    fontWeight: FontWeight.w800,
    height: 0.96,
    letterSpacing: -0.4,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get display => GoogleFonts.barlowCondensed(
    fontSize: 47,
    fontWeight: FontWeight.w800,
    height: 1.0,
    letterSpacing: -0.2,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get metric => GoogleFonts.barlowCondensed(
    fontSize: 32,
    fontWeight: FontWeight.w800,
    height: 1.0,
    letterSpacing: -0.1,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );
  static TextStyle get metricSm => GoogleFonts.barlowCondensed(
    fontSize: 23,
    fontWeight: FontWeight.w700,
    height: 1.0,
    letterSpacing: 0,
    color: AppColors.ink,
    fontFeatures: _tnum,
  );

  // ── Headings ──
  static TextStyle get h1 => GoogleFonts.manrope(
    fontSize: 28,
    fontWeight: FontWeight.w800,
    height: 1.05,
    letterSpacing: -0.7,
    color: AppColors.ink,
  );
  static TextStyle get h2 => GoogleFonts.manrope(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    height: 1.1,
    letterSpacing: -0.35,
    color: AppColors.ink,
  );

  // ── Body / labels ──
  static TextStyle get title => GoogleFonts.manrope(
    fontSize: 16,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.15,
    color: AppColors.ink,
  );
  static TextStyle get body => GoogleFonts.manrope(
    fontSize: 14.5,
    fontWeight: FontWeight.w500,
    height: 1.45,
    color: AppColors.ink,
  );
  static TextStyle get bodySoft => GoogleFonts.manrope(
    fontSize: 14.5,
    fontWeight: FontWeight.w500,
    height: 1.45,
    color: AppColors.inkSoft,
  );
  static TextStyle get label => GoogleFonts.manrope(
    fontSize: 13,
    fontWeight: FontWeight.w700,
    color: AppColors.inkSoft,
    letterSpacing: 0.1,
  );
  static TextStyle get caption => GoogleFonts.manrope(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.inkSoft,
  );
  static TextStyle get captionMuted => GoogleFonts.manrope(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: AppColors.inkMuted,
  );
  static TextStyle get overline => GoogleFonts.manrope(
    fontSize: 11,
    fontWeight: FontWeight.w800,
    letterSpacing: 1.5,
    color: AppColors.inkMuted,
  );
}

/// Build the full theme from an explicit [Palette] so light/dark are each
/// self-consistent. Call with [kLightPalette] / [kDarkPalette].
ThemeData buildOpenStrapTheme(Palette p) {
  // Material's `primary` drives every routine/non-evaluative default (Switch,
  // ProgressIndicator, FilledButton, focus rings, splash) — that's brand
  // identity territory, not alert territory, so it seeds from `p.brand` (calm
  // cyan/teal), never `p.coral` (reserved for genuinely low/urgent states).
  final scheme =
      ColorScheme.fromSeed(
        seedColor: p.brand,
        brightness: p.brightness,
      ).copyWith(
        surface: p.surface,
        onSurface: p.ink,
        primary: p.brand,
        onPrimary: Colors.white,
        secondary: p.brandDeep,
      );

  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    dividerColor: p.divider,
    splashColor: p.brand.withValues(alpha: 0.08),
    highlightColor: p.brand.withValues(alpha: 0.05),
    textTheme: GoogleFonts.manropeTextTheme().apply(
      bodyColor: p.ink,
      displayColor: p.ink,
    ),
    // Page transitions live HERE (not in a custom PageRouteBuilder) so pushed
    // routes stay MaterialPageRoutes: iOS keeps the native slide transition
    // AND the interactive edge-swipe-back gesture; Android-likes get the
    // app's shared-axis fade-through. See page_transitions.dart.
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.fuchsia: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.linux: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.windows: SharedAxisPageTransitionsBuilder(),
        TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
      },
    ),
  );

  return base.copyWith(
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      foregroundColor: p.ink,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: GoogleFonts.manrope(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.1,
        letterSpacing: -0.35,
        color: p.ink,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Sp.x5,
        vertical: Sp.x4,
      ),
      hintStyle: GoogleFonts.manrope(
        fontSize: 14.5,
        fontWeight: FontWeight.w500,
        color: p.inkMuted,
      ),
      labelStyle: GoogleFonts.manrope(
        fontSize: 14.5,
        fontWeight: FontWeight.w500,
        color: p.inkSoft,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: BorderSide(color: p.divider),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: BorderSide(color: p.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(R.cardSm),
        borderSide: BorderSide(color: p.brand, width: 2),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        // Default FilledButton = the routine primary-action colour (brand
        // teal). Genuinely destructive actions override this explicitly with
        // AppColors.critical at the call site (see profile_screen's confirm
        // dialog) — that pattern is unaffected by this change.
        backgroundColor: p.brand,
        foregroundColor: Colors.white,
        disabledBackgroundColor: p.inkMuted.withValues(alpha: 0.35),
        minimumSize: const Size(0, 56),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(R.pill),
        ),
        textStyle: GoogleFonts.manrope(
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        minimumSize: const Size(0, 56),
        side: BorderSide(color: p.divider, width: 1.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(R.pill),
        ),
        textStyle: GoogleFonts.manrope(
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.brandDeep,
        textStyle: GoogleFonts.manrope(
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.isDark ? p.surfaceAlt : AppColors.night,
      contentTextStyle: GoogleFonts.manrope(color: AppColors.onNight),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(R.chip),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
      ),
    ),
  );
}
