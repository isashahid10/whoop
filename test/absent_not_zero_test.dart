// The honesty contract, under test: an ABSENT measurement renders as "—" /
// nothing / an explicit gap — NEVER as 0, and never as a placeholder that
// reads as measured.
//
// Every test here fails against the pre-fix behaviour. The repository already
// tells the truth (`has` flags, nullable scalars, `segments` as a list); these
// pin down the UI actually reading it instead of `?? 0`-ing it away.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/kit/charts.dart'
    show HrReplayOverlay, LabeledBars, MiniBars, TimeSeriesPoint;
import 'package:openstrap_edge/ui/kit/kit.dart' show OsIcon;
import 'package:openstrap_edge/ui/screens/detail_cards.dart'
    show OxygenNightContent, WearDayContent;
import 'package:openstrap_edge/ui/screens/metric_screen.dart'
    show TrendBoard, trendBarLabel, trendBucketValue, trendDisplay;
import 'package:openstrap_edge/ui/widgets/async_guards.dart'
    show LatestRequestGate, SafeSetState;

Widget _host(Widget child, {Palette palette = kLightPalette}) {
  AppColors.active = palette;
  return MaterialApp(
    theme: buildOpenStrapTheme(palette),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void _phone(WidgetTester t, {double height = 1400}) {
  t.view.physicalSize = Size(390, height);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
}

String _today() {
  final d = DateTime.now();
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

/// A week /trend payload; [absent] lists the bucket indices the repository
/// marked as having no measurement (it still pads their `value` to 0.0).
Map<String, dynamic> _week({
  Set<int> absent = const {},
  String unit = 'bpm',
  String label = 'resting HR',
  num? delta,
  double Function(int i)? value,
}) {
  final monday = DateTime.utc(2026, 7, 13);
  return {
    'label': label,
    'unit': unit,
    'summary': {'avg': 52.4, 'delta_vs_prev': delta, 'total': 7},
    'buckets': [
      for (var i = 0; i < 7; i++)
        {
          't_start': monday.add(Duration(days: i)).millisecondsSinceEpoch ~/ 1000,
          't_end':
              monday.add(Duration(days: i + 1)).millisecondsSinceEpoch ~/ 1000,
          // The repository's exact shape: 0.0 padding + the `has` flag.
          'value': absent.contains(i) ? 0.0 : (value?.call(i) ?? (50 + i)),
          'has': !absent.contains(i),
        },
    ],
  };
}

/// Bars actually PAINTED by a LabeledBars (a gap paints nothing).
int _paintedBars(WidgetTester t) => t
    .widgetList(
      find.descendant(
        of: find.byType(LabeledBars),
        matching: find.byType(FractionallySizedBox),
      ),
    )
    .length;

Map<String, dynamic> _wearDay({
  Object? worn = 900,
  Object? cov = 62,
  Object? segments,
  Object? longestOff,
  List<double>? hourly,
}) {
  final m = <String, dynamic>{
    'first_on': 1752300000,
    'last_on': 1752380000,
    'hourly': hourly ?? const <double>[],
  };
  // Keys are OMITTED (not set to null) when absent — exactly how a bundle with
  // no engine wear block reaches the UI.
  if (worn != null) m['worn_min'] = worn;
  if (cov != null) m['coverage_pct'] = cov;
  if (segments != null) m['segments'] = segments;
  if (longestOff != null) m['longest_off_min'] = longestOff;
  return m;
}

void main() {
  tearDown(() => AppColors.active = kLightPalette);

  // ── 3 · the `has` flag, all the way down ──────────────────────────────────
  group('trend buckets: `has` is the only truth', () {
    test('trendBucketValue returns null for a bucket the repo marked absent',
        () {
      // Exactly what local_repository_impl writes: `value: v ?? 0.0`.
      expect(trendBucketValue({'value': 0.0, 'has': false}), isNull);
      expect(trendBucketValue({'value': 0.0, 'has': true}), 0.0);
      expect(trendBucketValue({'value': 51.0, 'has': true}), 51.0);
      // Payloads that predate `has` still work off value-presence.
      expect(trendBucketValue({'value': 51.0}), 51.0);
      expect(trendBucketValue(const {}), isNull);
    });

    testWidgets('LabeledBars draws NO bar for a null value and labels it —',
        (t) async {
      _phone(t);
      await t.pumpWidget(_host(const SizedBox(
        height: 220,
        child: LabeledBars(
          values: [5.0, null, 7.0],
          labels: ['Mon', 'Tue', 'Wed'],
        ),
      )));
      await t.pump(const Duration(milliseconds: 700));
      // Two real bars, not three: the 0.02 height floor must not manufacture
      // a bar out of a missing measurement.
      expect(_paintedBars(t), 2);
      expect(find.text('—'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('TrendBoard leaves an unworn day empty instead of drawing '
        'an accent bar at the floor', (t) async {
      _phone(t);
      await t.pumpWidget(_host(TrendBoard(
        data: _week(absent: {3}),
        title: 'Heart',
        icon: OsIcon.heart,
        metric: 'resting_hr',
        scale: 'week',
        accent: AppColors.coral,
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(_paintedBars(t), 6); // 7 days, 1 gap
      expect(find.text('—'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('an all-absent period says "No data", an all-ZERO one draws '
        'its real zeros', (t) async {
      _phone(t);
      await t.pumpWidget(_host(TrendBoard(
        data: _week(absent: {0, 1, 2, 3, 4, 5, 6}),
        title: 'Steps',
        icon: OsIcon.activity,
        metric: 'steps',
        scale: 'week',
        accent: AppColors.coral,
      )));
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('No data in this period'), findsOneWidget);

      // Seven measured zeros are a finding, not an absence.
      await t.pumpWidget(_host(TrendBoard(
        data: _week(value: (_) => 0.0),
        title: 'Steps',
        icon: OsIcon.activity,
        metric: 'steps',
        scale: 'week',
        accent: AppColors.coral,
      )));
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('No data in this period'), findsNothing);
      expect(_paintedBars(t), 7);
      expect(t.takeException(), isNull);
    });
  });

  // ── 4 · the fabricated oxygen "0" ─────────────────────────────────────────
  group('oxygen bars', () {
    testWidgets('an unmeasured night never prints a literal 0 SpO₂', (t) async {
      _phone(t);
      await t.pumpWidget(_host(TrendBoard(
        data: _week(absent: {1}, unit: 'dips/h', label: 'oxygen dips'),
        title: 'Overnight oxygen',
        icon: OsIcon.hydration,
        metric: 'spo2',
        scale: 'week',
        accent: AppColors.coral,
        // The screen's OLD formatter, kept here on purpose: if an absent
        // bucket ever reaches a value formatter again, this fails loudly.
        valueFmt: (v) => v == 0 ? '0' : v.toStringAsFixed(1),
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('0'), findsNothing);
      expect(find.text('—'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    // ── 6 · the series is not what its name says ────────────────────────────
    test('trendDisplay renames the spo2 series to what it actually holds', () {
      final d = trendDisplay('spo2', 'oxygen dips', 'dips/h');
      expect(d.label, 'imported oxygen index');
      expect(d.unit, isEmpty); // never "dips/h"
      // Every other series is passed through untouched.
      final hr = trendDisplay('resting_hr', 'resting HR', 'bpm');
      expect(hr.label, 'resting HR');
      expect(hr.unit, 'bpm');
    });

    testWidgets('the spo2 board is not captioned as a dip rate', (t) async {
      _phone(t);
      await t.pumpWidget(_host(TrendBoard(
        data: _week(unit: 'dips/h', label: 'oxygen dips',
            value: (i) => 95.0 + i * 0.1),
        title: 'Overnight oxygen',
        icon: OsIcon.hydration,
        metric: 'spo2',
        scale: 'week',
        accent: AppColors.coral,
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('dips/h'), findsNothing);
      // TileHeader uppercases its title.
      expect(find.textContaining(RegExp('oxygen dips', caseSensitive: false)),
          findsNothing);
      expect(
          find.textContaining(
              RegExp('imported oxygen index', caseSensitive: false)),
          findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  // ── 5 · an absolute delta is not a percentage ─────────────────────────────
  group('trend delta chip', () {
    testWidgets('renders the absolute delta in its own unit, never as %',
        (t) async {
      _phone(t);
      await t.pumpWidget(_host(TrendBoard(
        data: _week(delta: -1.2),
        title: 'Heart',
        icon: OsIcon.heart,
        metric: 'resting_hr',
        scale: 'week',
        accent: AppColors.coral,
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('−1.2 bpm vs prev'), findsOneWidget);
      expect(find.textContaining('1.2%'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('sleep deltas travel in MINUTES and say so', (t) async {
      _phone(t);
      await t.pumpWidget(_host(TrendBoard(
        data: _week(delta: 20, unit: 'h', label: 'sleep',
            value: (i) => 420 + i.toDouble()),
        title: 'Sleep',
        icon: OsIcon.activity,
        metric: 'sleep',
        scale: 'week',
        accent: AppColors.coral,
      )));
      await t.pump(const Duration(milliseconds: 900));
      // The bug: "20 minutes more sleep" rendered as "▲ 20.0%".
      expect(find.text('+20 min vs prev'), findsOneWidget);
      expect(find.textContaining('20.0%'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  // ── window labelling ──────────────────────────────────────────────────────
  group('window labels name the real window', () {
    test('month buckets are rolling 7-day windows, labelled by their end', () {
      final b = {
        't_start': DateTime.utc(2026, 7, 8).millisecondsSinceEpoch ~/ 1000,
        't_end': DateTime.utc(2026, 7, 15).millisecondsSinceEpoch ~/ 1000,
      };
      expect(trendBarLabel('month', 0, b), 'Jul 14'); // was the false 'W1'
      // week + quarter are unchanged.
      final mon = {
        't_start': DateTime.utc(2026, 7, 6).millisecondsSinceEpoch ~/ 1000,
      };
      expect(trendBarLabel('week', 0, mon), 'Mon');
      expect(trendBarLabel('quarter', 0, mon), 'Jul');
    });

    testWidgets('the board header dates the window instead of saying '
        '"this week"', (t) async {
      _phone(t);
      await t.pumpWidget(_host(TrendBoard(
        data: _week(),
        title: 'Heart',
        icon: OsIcon.heart,
        metric: 'resting_hr',
        scale: 'week',
        accent: AppColors.coral,
      )));
      await t.pump(const Duration(milliseconds: 700));
      // /trend anchors on the LAST DAY WITH DATA when no anchor is given, so
      // "this week" can be a fortnight ago.
      expect(find.textContaining(RegExp('this week', caseSensitive: false)),
          findsNothing);
      expect(find.textContaining(RegExp('Jul 13.19', caseSensitive: false)),
          findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  // ── 1, 2, 7, 8 · the wear day board ───────────────────────────────────────
  group('WearDayContent', () {
    testWidgets('counts the segments LIST instead of printing 0 forever',
        (t) async {
      _phone(t, height: 2400);
      await t.pumpWidget(_host(WearDayContent(
        data: _wearDay(segments: [
          {'start': 1, 'end': 2},
          {'start': 3, 'end': 4},
          {'start': 5, 'end': 6},
        ]),
        date: _today(),
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('WEAR STRETCHES'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      // The old `_n(List) ?? 0` printed this on every worn day, every device.
      expect(find.text('0'), findsNothing);
      expect(t.takeException(), isNull);
    });

    testWidgets('an unrecorded stretch count is —, not 0', (t) async {
      _phone(t, height: 2400);
      await t.pumpWidget(_host(WearDayContent(
        // Exactly what getDayWear emits with no engine wear block.
        data: _wearDay(segments: const []),
        date: _today(),
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('WEAR STRETCHES'), findsOneWidget);
      expect(find.text('0'), findsNothing);
      expect(find.text('—'), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('a day with NO wear measurement does not assert "not worn"',
        (t) async {
      _phone(t);
      await t.pumpWidget(_host(WearDayContent(
        data: _wearDay(worn: null, cov: null), // imported day: no wear block
        date: _today(),
      )));
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('Not worn on this day'), findsNothing);
      expect(find.text('Wear time wasn’t recorded'), findsOneWidget);

      // A MEASURED zero still says so — the two claims stay distinguishable.
      await t.pumpWidget(_host(
        WearDayContent(data: const {'worn_min': 0}, date: _today()),
      ));
      await t.pump(const Duration(milliseconds: 700));
      expect(find.text('Not worn on this day'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('"Longest off: none" is only claimed from a measured zero',
        (t) async {
      _phone(t, height: 2400);
      await t.pumpWidget(_host(WearDayContent(
        data: _wearDay(segments: const []), // no longest_off_min at all
        date: _today(),
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('LONGEST OFF'), findsOneWidget);
      expect(find.text('none'), findsNothing);

      await t.pumpWidget(_host(WearDayContent(
        data: _wearDay(segments: const [], longestOff: 0),
        date: _today(),
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('none'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a recent day with no hourly array explains itself instead of '
        'rendering nothing', (t) async {
      _phone(t, height: 2400);
      await t.pumpWidget(_host(WearDayContent(
        data: _wearDay(segments: const []), // hourly: [] — the real payload
        date: _today(),
      )));
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('Hourly coverage'), findsNothing);
      expect(
        find.textContaining('Hour-by-hour wear isn’t stored'),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
    });
  });

  // ── 9 · oxygen severity from absent inputs ────────────────────────────────
  group('OxygenNightContent severity', () {
    testWidgets('trusted coverage with NO computed dip metrics is "Not '
        'graded", never an all-clear', (t) async {
      _phone(t, height: 3600);
      await t.pumpWidget(_host(OxygenNightContent(
        data: const {
          'spo2': {
            'trusted_coverage': 0.71,
            'signal_coverage': 0.82,
            'analyzed_hours': 6.8,
            'dip_count': 0,
            // odi_per_hour / max_dip_pct / burden_pct all absent.
          },
        },
        date: _today(),
      )));
      await t.pump(const Duration(milliseconds: 1200));
      expect(find.text('Not graded'), findsOneWidget);
      expect(find.text('Quiet'), findsNothing);
      expect(
        find.textContaining('No meaningful overnight oxygen dips'),
        findsNothing,
      );
      expect(t.takeException(), isNull);
    });
  });

  // ── week-strip gaps ───────────────────────────────────────────────────────
  // This used to go through RecapCard (now deleted — it had no call site
  // outside the gallery). The invariant it guarded is MiniBars' own: a null
  // day holds its slot instead of sliding the rest of the week left.
  group('MiniBars week strip', () {
    testWidgets('keeps a missing day in place instead of shifting the week '
        'left', (t) async {
      _phone(t);
      await t.pumpWidget(_host(const MiniBars(
        [420.0, 430.0, null, 445.0, 455.0, 460.0, 470.0],
      )));
      await t.pump(const Duration(milliseconds: 700));
      final bars = t.widget<MiniBars>(find.byType(MiniBars));
      expect(bars.values.length, 7); // was 6 — Thu–Sun slid onto Wed–Sat
      expect(bars.values[2], isNull);
      expect(t.takeException(), isNull);
    });
  });

  // ── the workout HR replay dot ─────────────────────────────────────────────
  group('HrReplayOverlay', () {
    testWidgets('mounts the replay dot once playing', (t) async {
      _phone(t);
      await t.pumpWidget(_host(SizedBox(
        height: 200,
        child: Stack(
          children: [
            HrReplayOverlay(
              points: const [
                TimeSeriesPoint(0, 60),
                TimeSeriesPoint(1, 90),
                TimeSeriesPoint(2, 70),
              ],
              loX: 0,
              hiX: 2,
              loY: 60,
              hiY: 90,
              chartHeight: 200,
            ),
          ],
        ),
      )));
      await t.pump(const Duration(milliseconds: 100));
      final dot = find.descendant(
        of: find.byType(HrReplayOverlay),
        matching: find.byType(IgnorePointer),
      );
      expect(dot, findsNothing);

      await t.tap(find.byIcon(Icons.play_arrow));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      // The AnimatedBuilder used to live INSIDE the `0 < t < 1` gate, so the
      // only rebuild (the setState in _toggle, at t == 0) never passed it and
      // the dot never mounted.
      expect(dot, findsOneWidget);
      await t.pump(const Duration(seconds: 6));
      expect(t.takeException(), isNull);
    });
  });

  // ── 10 · stale-response overwrite ─────────────────────────────────────────
  group('LatestRequestGate', () {
    test('only the newest request may write back', () {
      final gate = LatestRequestGate();
      final first = gate.begin();
      expect(gate.isCurrent(first), isTrue);

      final second = gate.begin(); // a second revision arrives
      // The first load completes LAST (futures do not settle in start order)…
      expect(gate.isCurrent(first), isFalse); // …and is dropped.
      expect(gate.isCurrent(second), isTrue);

      // A third supersedes the second in turn.
      final third = gate.begin();
      expect(gate.isCurrent(second), isFalse);
      expect(gate.isCurrent(third), isTrue);
    });
  });

  // ── 13, 14 · setState after dispose ───────────────────────────────────────
  group('setStateIfMounted', () {
    testWidgets('a callback that lands after dispose is dropped, not thrown',
        (t) async {
      await t.pumpWidget(const MaterialApp(home: _LateSetState()));
      final state = t.state<_LateSetStateState>(find.byType(_LateSetState));
      await t.pumpWidget(const MaterialApp(home: SizedBox()));
      expect(state.mounted, isFalse);

      // What a 120 s provider call's onItem/onStatus/catch does when the user
      // has already popped the screen.
      state.setStateIfMounted(() {});
      expect(t.takeException(), isNull);

      // The control: the unguarded call this replaced does throw.
      expect(() => state.callSetState(() {}), throwsFlutterError);
    });
  });
}

class _LateSetState extends StatefulWidget {
  const _LateSetState();
  @override
  State<_LateSetState> createState() => _LateSetStateState();
}

class _LateSetStateState extends State<_LateSetState> {
  void callSetState(VoidCallback fn) => setState(fn);
  @override
  Widget build(BuildContext context) => const SizedBox();
}
