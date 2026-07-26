// Async-lifecycle guards on the AI surfaces. All three bugs share a shape: a
// callback lands after the world has moved on (a newer request started, or the
// screen is gone) and clobbers what's on screen — or crashes the frame.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/ai/briefing.dart';
import 'package:openstrap_edge/ai/briefing_engine.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/data/local_repository.dart';
import 'package:openstrap_edge/state/prefs.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/ai/ai_breakdown_screen.dart';
import 'package:openstrap_edge/ui/ai/ai_settings_screen.dart';

class _FakeRepo extends LocalRepository {
  @override
  Future<Map<String, dynamic>> getToday() async => {
        'daily': {
          'readiness': {'value': 74},
        },
        'status': const {},
      };
  @override
  Future<Map<String, dynamic>> getDaySleep(String date) async =>
      {'has_sleep': false};
}

Widget _host(Widget child) {
  AppColors.active = kLightPalette;
  return MultiProvider(
    providers: [
      ChangeNotifierProvider<CoachConfig>(create: (_) => CoachConfig()),
    ],
    child: MaterialApp(theme: buildOpenStrapTheme(kLightPalette), home: child),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs.ensureLoaded();
    AppColors.active = kLightPalette;
    AiSettingsScreen.pickerOverride = null;
  });
  tearDown(() {
    AiSettingsScreen.pickerOverride = null;
    AppColors.active = kLightPalette;
  });

  testWidgets('regenerate is single-flight: a double tap does not put two '
      'briefings in the air', (t) async {
    t.view.physicalSize = const Size(390, 2000);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    var calls = 0;
    final engine = BriefingEngine(
      config: CoachConfig(),
      repo: _FakeRepo(),
      complete: ({required system, required user}) async {
        calls++;
        await Future<void>.delayed(const Duration(milliseconds: 40));
        return 'Recovered and ready.\n---\n- Readiness sits at 74';
      },
    );

    await t.pumpWidget(_host(AiBreakdownScreen(
      period: BriefingPeriod.morning,
      engineOverride: engine,
    )));
    await t.pump(); // post-frame _load → _generate
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 700));
    expect(calls, 1);
    expect(find.text('Recovered and ready.'), findsOneWidget);

    // Two taps inside one frame — the button is still on screen for both.
    final regen = find.byType(InkWell).first;
    await t.tap(regen, warnIfMissed: false);
    await t.tap(regen, warnIfMissed: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    await t.pump(const Duration(milliseconds: 700));

    // Without the in-flight guard both taps issued a generate, and whichever
    // settled LAST won — an error arriving after a success discards the fresh
    // briefing (and vice versa shows a stale one as current).
    expect(calls, 2);
    expect(find.text('Recovered and ready.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('AI settings: a time picked after the screen is gone is dropped',
      (t) async {
    t.view.physicalSize = const Size(390, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final picked = Completer<TimeOfDay?>();
    AiSettingsScreen.pickerOverride = (_, _) => picked.future;

    await t.pumpWidget(_host(const AiSettingsScreen()));
    await t.pump();
    await t.pump(const Duration(milliseconds: 700));

    await t.tap(find.text('Time').first);
    await t.pump();

    // The user leaves while the picker is still up. showTimePicker's future
    // resolves after the dialog's exit transition, i.e. plausibly now.
    await t.pumpWidget(_host(const SizedBox()));
    await t.pump();

    picked.complete(const TimeOfDay(hour: 7, minute: 30));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));

    // Unguarded this is "setState() called after dispose()".
    expect(t.takeException(), isNull);
  });
}
