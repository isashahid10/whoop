@Tags(['render'])
library;

// UI render harness - writes real PNGs of the screens so the design can be
// LOOKED AT rather than argued about from source.
//
// Run with:  fvm flutter test test/ui_render_test.dart --update-goldens --run-skipped
// Output:    test/goldens/*.png
//
// TAGGED `render` AND EXCLUDED FROM THE DEFAULT RUN (see dart_test.yaml).
// matchesGoldenFile IS an assertion, so left untagged these would fail the
// whole suite on every deliberate design change - a tax on exactly the work
// they exist to support. The value here is the PNGs, not a pass/fail: change a
// token, re-render, look at the image, compare it against the reference
// screenshots.

import 'package:openstrap_edge/ui/readiness/readiness_detail_screen.dart';
import 'package:openstrap_edge/compute/readiness_service.dart';
import 'dart:convert';
import 'package:openstrap_edge/ui/sleep/nap_content.dart';
import 'package:openstrap_edge/compute/nap_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/models/payloads.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/design/domains.dart';
import 'package:openstrap_edge/ui/design/bento.dart';
import 'package:openstrap_edge/ui/design/big_stat.dart';
import 'package:openstrap_edge/ui/design/controls.dart';
import 'package:openstrap_edge/ui/design/nav_pill.dart';
import 'package:openstrap_edge/ui/design/surface.dart';
import 'package:openstrap_edge/ui/kit/os_icons.dart';
import 'package:openstrap_edge/ui/today/score_trio.dart';
import 'package:openstrap_edge/ui/today/today_screen.dart' show TodayVitals;

Widget _host(Widget child, {Palette palette = kDarkPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(
      backgroundColor: palette.bg,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: child,
        ),
      ),
    ),
  );
}

/// A 390 x [height] LOGICAL-point phone.
///
/// `physicalSize` is in PHYSICAL pixels, so it has to be scaled by the pixel
/// ratio - setting it to 390 at 3x renders a 130 pt viewport and every layout
/// comes out cramped and overflowing, which looks like a design fault rather
/// than a harness one.
void _phone(WidgetTester t, {double height = 844}) {
  const dpr = 3.0;
  t.view.devicePixelRatio = dpr;
  t.view.physicalSize = Size(390 * dpr, height * dpr);
  addTearDown(t.view.reset);
}

Map<String, dynamic> _sample() => {
      'daily': {
        'readiness': {'value': 82, 'confidence': 0.9},
        'strain': {'value': 12.4, 'confidence': 0.8},
        'resting_hr': {'value': 52, 'confidence': 0.9},
        'resting_hr_delta': {'value': -2.0, 'confidence': 0.9},
        'calories': {'value': 640, 'confidence': 0.6, 'tier': 'estimate'},
        'steps': {'value': 8412, 'confidence': 0.5},
        'wear_min': {'value': 1380, 'confidence': 1.0},
      },
      'sleep': {
        'duration_min': {'value': 462, 'confidence': 0.9},
        'need_min': {'value': 480, 'confidence': 0.9},
        'efficiency': {'value': 92, 'confidence': 0.9},
        'score': {'value': 74, 'confidence': 0.9},
        'score_coverage': 1.0,
        'score_basis': 'All 5 components measured.',
      },
      'stress': {'score': 34},
      'status': {'overnight_state': 'ready', 'today_day': '2026-07-28'},
    };

/// Load the app's own bundled faces into the test binding.
///
/// Declaring fonts in pubspec makes them available to the APP, but
/// flutter_test still defaults to its placeholder face - which draws every
/// glyph as a filled rectangle, so a render is unreadable and a design cannot
/// be judged from it. Pulling the same assets through rootBundle gives the
/// test the real typography the device gets.
Future<void> _loadFonts() async {
  const faces = <String, List<String>>{
    'Manrope': ['assets/fonts/Manrope/Manrope-Variable.ttf'],
    'Barlow Condensed': [
      'assets/fonts/BarlowCondensed/BarlowCondensed-Bold.ttf',
      'assets/fonts/BarlowCondensed/BarlowCondensed-ExtraBold.ttf',
    ],
  };
  for (final e in faces.entries) {
    final loader = FontLoader(e.key);
    for (final path in e.value) {
      loader.addFont(rootBundle.load(path));
    }
    await loader.load();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The day cards read prefs (supplements taken, prayer enabled); without a
  // mock store every one throws MissingPluginException and the render aborts.
  SharedPreferences.setMockInitialValues({});
  setUpAll(_loadFonts);

  testWidgets('render: score trio', (t) async {
    _phone(t, height: 300);
    // Swap the palette BEFORE building the widget tree. Colour tokens are
    // resolved eagerly as constructor arguments, so reading AppColors.* inside
    // the _host(...) call would capture the PREVIOUS palette and the render
    // would quietly show the wrong colours.
    AppColors.active = kDarkPalette;
    await t.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 24),
          child: ScoreTrio(
            rings: [
              ScoreRingData(
                label: 'Sleep',
                color: DomainAccent.sleep,
                display: '74',
                unit: '%',
                fill: 0.74,
              ),
              ScoreRingData(
                label: 'Recovery',
                color: AppColors.good,
                display: '82',
                unit: '%',
                fill: 0.82,
              ),
              ScoreRingData(
                label: 'Strain',
                color: DomainAccent.strain,
                display: '12.4',
                fill: 12.4 / 21,
              ),
            ],
          ),
        ),
      ),
    );
    // Entrance animations stagger opacity from 0, so a single delayed pump can
    // capture a frame where everything is still transparent - which renders as
    // a blank page and looks like a build failure.
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/score_trio.png'),
    );
  });

  testWidgets('render: today screen', (t) async {
    _phone(t, height: 1400);
    AppColors.active = kDarkPalette;
    await t.pumpWidget(
      _host(TodayVitals(t: TodayData.fromJson(_sample()), onOpen: (_) {})),
    );
    // Entrance animations stagger opacity from 0, so a single delayed pump can
    // capture a frame where everything is still transparent - which renders as
    // a blank page and looks like a build failure.
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/today.png'),
    );
  });

  testWidgets('render: bottom nav', (t) async {
    _phone(t, height: 160);
    AppColors.active = kDarkPalette;
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildOpenStrapTheme(kDarkPalette),
        home: Scaffold(
          backgroundColor: kDarkPalette.bg,
          body: const SizedBox.expand(),
          bottomNavigationBar: FloatingNavPill(
            items: const [
              NavPillItem(OsIcon.today, 'Today'),
              NavPillItem(OsIcon.sleep, 'Sleep'),
              NavPillItem(OsIcon.heart, 'Heart'),
              NavPillItem(OsIcon.bodyStrain, 'Body'),
              NavPillItem(OsIcon.workouts, 'Workouts'),
            ],
            index: 0,
            onSelect: (_) {},
          ),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/nav.png'),
    );
  });

  testWidgets('render: components', (t) async {
    _phone(t, height: 1000);
    AppColors.active = kDarkPalette;
    var seg = 1;
    await t.pumpWidget(
      _host(
        StatefulBuilder(
          builder: (context, setState) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Text('Sleep', style: AppText.h1),
              const SizedBox(height: 16),
              SegmentedControl(
                options: const ['Today', 'Week', 'Month', '3M'],
                index: seg,
                expanded: true,
                onChanged: (i) => setState(() => seg = i),
              ),
              const SizedBox(height: 20),
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('SLEEP · 7 DAYS',
                        style: AppText.overline
                            .copyWith(color: AppColors.inkSoft)),
                    const SizedBox(height: 12),
                    Text('7h 42m', style: AppText.hero),
                    Text('average', style: AppText.captionMuted),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              BentoColumns(
                left: [
                  BentoTile(
                    tone: BentoTone.soft,
                    accent: DomainAccent.sleep,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const TileHeader('Efficiency'),
                        const SizedBox(height: 8),
                        const BigStat(value: '92', unit: '%'),
                      ],
                    ),
                  ),
                ],
                right: [
                  BentoTile(
                    tone: BentoTone.ink,
                    accent: DomainAccent.strain,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const TileHeader('Strain'),
                        const SizedBox(height: 8),
                        const BigStat(value: '12.4'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/components.png'),
    );
  });


  // The nap tab, rendered with the REAL 94-minute nap from 2026-07-29 so the
  // design is judged against data that actually exists rather than a
  // flattering invention.
  testWidgets('render: nap tab', (t) async {
    _phone(t, height: 900);
    AppColors.active = kDarkPalette;
    final start = DateTime(2026, 7, 29, 13, 48);
    await t.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedControl(
                options: const ['Night', 'Nap 1h 34m'],
                index: 1,
                onChanged: (_) {},
                expanded: true,
              ),
              const SizedBox(height: 20),
              NapContent(
                naps: [
                  Nap(
                    start: start,
                    end: start.add(const Duration(minutes: 94)),
                    minutes: 94,
                    confidence: 0.82,
                    tstMin: 88,
                    lightMin: 61,
                    deepMin: 9,
                    remMin: 18,
                    stagingReliable: true,
                  ),
                ],
                nightMinutes: 438,
              ),
            ],
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/nap_tab.png'),
    );
  });

  // Readiness breakdown, rendered with the REAL 2026-08-02 decomposition so the
  // design is judged against data that exists.
  testWidgets('render: readiness breakdown', (t) async {
    _phone(t, height: 1100);
    AppColors.active = kDarkPalette;
    await t.pumpWidget(
      _host(
        Padding(
          padding: const EdgeInsets.all(20),
          child: ReadinessBreakdownContent(
            breakdown: ReadinessService.parse({
              'payload_json': jsonEncode({
                'clinical': {
                  'readiness_composite': {
                    'value': {
                      'score': 25.037188,
                      'composite_z': -1.09663,
                      'meaningful': true,
                    },
                    'confidence': 0.9,
                    'inputs_used': ['HRV', 'RHR', 'RR', 'temp'],
                    'drivers': [
                      {
                        'label': 'RHR',
                        'contribution': -0.900333,
                        'detail': 'oriented robust-z (median+MAD)=-3.001111',
                      },
                      {
                        'label': 'HRV',
                        'contribution': -0.514371,
                        'detail': 'oriented robust-z (median+MAD)=-1.285928',
                      },
                      {
                        'label': 'RR',
                        'contribution': 0.312401,
                        'detail': 'oriented robust-z (median+MAD)=1.562006',
                      },
                      {
                        'label': 'temp',
                        'contribution': 0.005674,
                        'detail': 'oriented robust-z (median+MAD)=0.056735',
                      },
                    ],
                  },
                },
              }),
            })!,
          ),
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 200));
    }
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/readiness_breakdown.png'),
    );
  });
}
