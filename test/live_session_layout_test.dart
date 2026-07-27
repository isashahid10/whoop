// Layout regressions for the live activity screen (run / ride / walk).
//
// The screen used to be one flat Stack of absolutely-positioned layers with no
// layout relationship between them, and they collided on real devices:
//
//   • the map's re-centre button was pinned `bottom: 96` while the control
//     panel is far taller than that — so it rendered UNDERNEATH the panel;
//   • the centred "Recording" pill ran under the 44 px map toggle;
//   • the ring-mode core was a fixed 270 px in a Center, with the session
//     clock absolutely positioned above it and the panel below, so all three
//     collided on a shorter phone.
//
// The fix is structural: a bounded hero and a metric sheet as SIBLINGS in a
// Column. These tests assert that property directly at several real device
// sizes, so a future "just Positioned it" change fails loudly.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/data/db.dart';
import 'package:openstrap_edge/state/app_state.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/activity/live_session_screen.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Real handset sizes, smallest first — the small ones are where the old
/// fixed-size layers collided.
const _sizes = <String, Size>{
  'iPhone SE': Size(375, 667),
  'iPhone 15': Size(393, 852),
  'Pixel 7': Size(412, 915),
};

Widget _host(Widget child, AppState app) => MultiProvider(
      providers: [
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<UnitsController>.value(
          value: UnitsController.seed(UnitSystem.metric),
        ),
      ],
      child: MaterialApp(
        theme: buildOpenStrapTheme(kDarkPalette),
        home: child,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_live_session_layout_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    AppColors.active = kDarkPalette;
  });

  AppState liveApp({required int hr, String type = 'run'}) {
    final app = AppState.forTesting();
    app.activeWorkout = LiveWorkoutState(
      startTime: DateTime.now().subtract(const Duration(minutes: 24)),
      targetKcal: 300,
      workoutId: 'live-1',
      type: type,
    )..currentHr = hr;
    return app;
  }

  for (final entry in _sizes.entries) {
    testWidgets('${entry.key}: hero and metric sheet never overlap',
        (t) async {
      t.view.physicalSize = entry.value;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final app = liveApp(hr: 148);
      addTearDown(app.dispose);

      await t.pumpWidget(_host(const LiveSessionScreen(), app));
      await t.pump(const Duration(milliseconds: 300));

      // Assert against the BOTTOM-MOST hero element, not the clock at the
      // top — the clock clears the sheet even in the broken layout, so
      // asserting on it would pass vacuously (it did; that is why this
      // compares the zone label instead).
      //
      // The zone name is the last thing in the hero column. If the sheet ever
      // goes back to floating over the hero, this is what it covers first.
      final sheetTop = t.getRect(find.text('HOLD TO FINISH')).top;
      final zoneLabel = t.getRect(find.textContaining('·').first);
      expect(
        zoneLabel.bottom,
        lessThanOrEqualTo(sheetTop),
        reason: 'hero content must not be painted underneath the sheet',
      );
      // And the hero's own hard-anchored overlay (the top rail) must not be
      // pushed off-screen by a hero that grew past its bounds.
      expect(t.takeException(), isNull,
          reason: 'no overflow at ${entry.key} (${entry.value})');
    });
  }

  testWidgets('the top rail keeps its contents inside the viewport',
      (t) async {
    t.view.physicalSize = _sizes['iPhone SE']!;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final app = liveApp(hr: 132);
    addTearDown(app.dispose);

    await t.pumpWidget(_host(const LiveSessionScreen(), app));
    await t.pump(const Duration(milliseconds: 300));

    // The view toggle moved OUT of the top rail and into the sheet, so with no
    // location issue the rail is empty by design. What must hold is that
    // anything it does show stays on screen rather than under the notch.
    final chip = find.textContaining('Location off');
    if (chip.evaluate().isNotEmpty) {
      final r = t.getRect(chip);
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.right, lessThanOrEqualTo(_sizes['iPhone SE']!.width));
    }
    expect(t.takeException(), isNull);
  });

  testWidgets('heart mode shows the clock and BPM ONCE, in the hero only',
      (t) async {
    t.view.physicalSize = _sizes['iPhone 15']!;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final app = liveApp(hr: 148);
    addTearDown(app.dispose);

    await t.pumpWidget(_host(const LiveSessionScreen(), app));
    await t.pump(const Duration(milliseconds: 300));

    // The hero already carries the session clock at 40 px and the BPM at ring
    // scale with its zone name. The sheet used to repeat both, printing the
    // same number twice on one screen.
    expect(find.text('DURATION'), findsOneWidget);
    expect(find.text('ELAPSED'), findsNothing,
        reason: 'the sheet must not repeat the clock in heart mode');
    expect(find.text('BPM'), findsOneWidget);
    expect(find.text('148'), findsOneWidget,
        reason: 'heart rate belongs to the hero, not also the sheet');
    // The stats that are NOT duplicated still show.
    expect(find.text('KCAL'), findsOneWidget);
    expect(find.text('STRAIN'), findsOneWidget);
    expect(find.text('STEPS'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('the hero clock stays legible at an extreme duration',
      (t) async {
    t.view.physicalSize = _sizes['iPhone SE']!;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final app = liveApp(hr: 195);
    app.activeWorkout = LiveWorkoutState(
      startTime: DateTime.now().subtract(const Duration(hours: 12, minutes: 3)),
      targetKcal: 300,
      workoutId: 'ultra',
      type: 'run',
    )..currentHr = 195;
    addTearDown(app.dispose);

    await t.pumpWidget(_host(const LiveSessionScreen(), app));
    await t.pump(const Duration(milliseconds: 300));

    // A 12-hour clock is the widest the primary figure ever gets; it must
    // scale down rather than overflow its row.
    expect(t.takeException(), isNull);
  });

  testWidgets('the almost-there nudge interpolates its values', (t) async {
    t.view.physicalSize = _sizes['iPhone 15']!;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    // The nudge only appears within 5 bpm of the next zone, which is why no
    // test ever hit it — and an escaped `\$` in the template shipped, rendering
    // the literal text `$gapBpm bpm to ${_zones[zone + 1].label} — push` to the
    // athlete. Default maxHr is 190 (age 30), Z4 starts at 0.8 => 152 bpm, so
    // 148 sits 4 bpm short of it.
    final app = liveApp(hr: 148);
    addTearDown(app.dispose);

    await t.pumpWidget(_host(const LiveSessionScreen(), app));
    await t.pump(const Duration(milliseconds: 300));

    expect(find.textContaining('bpm to'), findsOneWidget);
    expect(find.textContaining(r'$gapBpm'), findsNothing,
        reason: 'the template must be interpolated, not printed');
    expect(find.textContaining(r'${'), findsNothing,
        reason: 'no raw interpolation syntax may reach the screen');
    expect(find.text('4 bpm to Z4 — push'), findsOneWidget);
  });
}
