// The share card is defined as much by what it LEAVES OUT as by what it shows.
//
// Sharing used to rasterise the whole finish card — header, route thumbnail,
// strain gauge, peak/avg/kcal/steps, time-in-zones, the HR-recovery curve and
// any PR badges — into one tall PNG. These tests pin the composition that
// replaced it: map-led, one headline figure, three supporting stats, and none
// of the dashboard furniture that doesn't survive a feed thumbnail.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:openstrap_edge/gps/route_models.dart';
import 'package:openstrap_edge/state/units_controller.dart';
import 'package:openstrap_edge/theme/theme.dart';
import 'package:openstrap_edge/theme/tokens.dart';
import 'package:openstrap_edge/ui/activity/workout_share_card.dart';
import 'package:openstrap_edge/ui/design/fake_route_fixture.dart';
import 'package:openstrap_edge/ui/kit/route_map.dart';
import 'package:provider/provider.dart';

List<RouteVertex> _route() => [
      for (var i = 0; i < 40; i++)
        RouteVertex(
          LatLng(51.5074 + i * 0.0004, -0.1278 + i * 0.0003),
          (i ~/ 8).clamp(0, 5),
        ),
    ];

WorkoutShareData _data({List<RouteVertex>? vertices}) => WorkoutShareData(
      title: 'Morning Run',
      subtitle: '27 Jul 2026',
      vertices: vertices ?? _route(),
      heroValue: '8.42',
      heroUnit: 'km',
      stats: const [
        ('42:30', 'Time'),
        ('5:02 /km', 'Pace'),
        ('14.2', 'Strain'),
      ],
      accent: AppColors.coral,
    );

Widget _host(Widget child) => MultiProvider(
      providers: [
        ChangeNotifierProvider<UnitsController>.value(
          value: UnitsController.seed(UnitSystem.metric),
        ),
      ],
      child: MaterialApp(
        theme: buildOpenStrapTheme(kDarkPalette),
        home: Scaffold(body: Center(child: child)),
      ),
    );

/// Drop map-tile fetch errors, keep everything else.
///
/// flutter_test's HTTP mock answers 400 for every request, so each tile throws
/// through the image-resource service — and flutter_test fails a test on ANY
/// unhandled exception, so a card that renders perfectly still goes red.
///
/// Filtered rather than drained, so RenderFlex overflow still fails these
/// tests. MUST be installed inside the test body: the test binding replaces
/// FlutterError.onError after setUp runs, so a filter installed there is
/// silently discarded (which is what sent me down a blind alley of
/// hand-stubbing HttpClient before noticing).
void _ignoreTileFetchErrors() {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    if (details.library == 'image resource service') return;
    if (details.exception.toString().contains('ClientException')) return;
    previous?.call(details);
  };
  addTearDown(() => FlutterError.onError = previous);
}

void main() {
  setUp(() => AppColors.active = kDarkPalette);
  tearDown(() => AppColors.active = kLightPalette);

  group('WorkoutShareCard', () {
    testWidgets('leads with the map and the headline figure', (t) async {
      _ignoreTileFetchErrors();
      t.view.physicalSize = const Size(500, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(
        WorkoutShareCard(data: _data(), format: ShareFormat.feed),
      ));
      await t.pump(const Duration(milliseconds: 400));

      expect(find.byType(RouteMapView), findsOneWidget,
          reason: 'the route is the reason anyone shares this');
      expect(find.text('8.42'), findsOneWidget);
      expect(find.text('KM'), findsOneWidget);
      expect(find.text('MORNING RUN'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('carries exactly three supporting stats, no more', (t) async {
      _ignoreTileFetchErrors();
      t.view.physicalSize = const Size(500, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(_host(
        WorkoutShareCard(data: _data(), format: ShareFormat.feed),
      ));
      await t.pump(const Duration(milliseconds: 400));

      for (final label in ['TIME', 'PACE', 'STRAIN']) {
        expect(find.text(label), findsOneWidget);
      }
      // The dashboard furniture that used to end up in the shared PNG.
      for (final absent in ['PEAK BPM', 'TIME IN ZONES', 'KCAL', 'STEPS']) {
        expect(find.text(absent), findsNothing,
            reason: '"$absent" belongs on the screen, not in a feed post');
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('both formats lay out without overflowing', (t) async {
      _ignoreTileFetchErrors();
      t.view.physicalSize = const Size(500, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      for (final f in ShareFormat.values) {
        await t.pumpWidget(_host(WorkoutShareCard(data: _data(), format: f)));
        await t.pump(const Duration(milliseconds: 400));
        final size = t.getSize(find.byType(WorkoutShareCard));
        expect(size.width, WorkoutShareCard.kWidth);
        expect(
          size.height,
          closeTo(WorkoutShareCard.kWidth / f.aspect, 0.5),
          reason: '${f.label} must honour its aspect ratio',
        );
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('an indoor workout keeps the same composition, no map',
        (t) async {
      t.view.physicalSize = const Size(500, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final indoor = WorkoutShareData(
        title: 'Strength',
        subtitle: '27 Jul 2026',
        vertices: const [],
        heroValue: '48:10',
        heroUnit: '',
        stats: const [('14.2', 'Strain'), ('512', 'Kcal'), ('141', 'Avg bpm')],
        accent: AppColors.coral,
      );

      await t.pumpWidget(_host(
        WorkoutShareCard(data: indoor, format: ShareFormat.feed),
      ));
      await t.pump(const Duration(milliseconds: 400));

      expect(find.byType(RouteMapView), findsNothing);
      // Same layout, different backdrop — not a second design.
      expect(find.text('48:10'), findsOneWidget);
      expect(find.text('STRAIN'), findsOneWidget);
      expect(find.text('AVG BPM'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('a one-point route is treated as no route', (t) async {
      t.view.physicalSize = const Size(500, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      // A single fix cannot draw a line; RouteMapView would render an empty
      // box, so the card must fall back rather than show a blank frame.
      final oneFix = _data(vertices: [
        RouteVertex(const LatLng(51.5074, -0.1278), 2),
      ]);
      expect(oneFix.hasRoute, isFalse);

      await t.pumpWidget(_host(
        WorkoutShareCard(data: oneFix, format: ShareFormat.feed),
      ));
      await t.pump(const Duration(milliseconds: 400));
      expect(find.byType(RouteMapView), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('buildWorkoutShareData — one composition, two entry points', () {
    final units = UnitsController.seed(UnitSystem.metric);
    final route = fakeRunRoute();
    final when = DateTime(2026, 7, 27, 8, 14);

    WorkoutShareData build({WorkoutRoute? r}) => buildWorkoutShareData(
          units: units,
          type: 'run',
          duration: const Duration(minutes: 20, seconds: 6),
          when: when,
          maxHr: 190,
          strain: 11.6,
          calories: 284,
          route: r,
          avgHr: 148,
        );

    test('the finish screen and the detail screen produce the SAME card', () {
      // Both call this factory with the same workout. If they ever diverge,
      // sharing the same run from two places gives two different images.
      final fromFinish = build(r: route);
      final fromDetail = build(r: route);
      expect(fromDetail.title, fromFinish.title);
      expect(fromDetail.subtitle, fromFinish.subtitle);
      expect(fromDetail.heroValue, fromFinish.heroValue);
      expect(fromDetail.heroUnit, fromFinish.heroUnit);
      expect(fromDetail.stats, fromFinish.stats);
      expect(fromDetail.vertices.length, fromFinish.vertices.length);
    });

    test('a route leads with DISTANCE — the map is what the image shows', () {
      final d = build(r: route);
      expect(d.hasRoute, isTrue);
      expect(d.heroUnit, 'km');
      expect(double.tryParse(d.heroValue), isNotNull);
      expect([for (final (_, l) in d.stats) l], ['Time', 'Pace', 'Strain']);
    });

    test('no route leads with the CLOCK and swaps to indoor stats', () {
      final d = build();
      expect(d.hasRoute, isFalse);
      expect(d.heroValue, '20m 06s');
      expect(d.heroUnit, isEmpty);
      expect([for (final (_, l) in d.stats) l], ['Strain', 'Kcal', 'Avg bpm']);
      expect(d.stats.last.$1, '148');
    });

    test('an absent average heart rate is "—", never a fabricated 0', () {
      final d = buildWorkoutShareData(
        units: units,
        type: 'other',
        duration: const Duration(minutes: 30),
        when: when,
        maxHr: 190,
        strain: 8.0,
        calories: 200,
        avgHr: null,
      );
      expect(d.stats.last, ('—', 'Avg bpm'));
    });

    test('imperial units carry through to the headline', () {
      final d = buildWorkoutShareData(
        units: UnitsController.seed(UnitSystem.imperial),
        type: 'run',
        duration: const Duration(minutes: 20),
        when: when,
        maxHr: 190,
        strain: 11.6,
        calories: 284,
        route: route,
      );
      expect(d.heroUnit, 'mi');
    });

    test('an empty type still gets a human title', () {
      final d = buildWorkoutShareData(
        units: units,
        type: '',
        duration: const Duration(minutes: 5),
        when: when,
        maxHr: 190,
        strain: 1.0,
        calories: 20,
      );
      expect(d.title, 'Workout');
    });
  });
}
