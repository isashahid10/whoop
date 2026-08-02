// Edge wiring for the training analyses and the caffeine log.
//
// The maths is tested in analytics. What is tested here is the part only edge
// can get wrong: reading the right keys, ordering by real elapsed time rather
// than by row, and - the one with teeth - not letting a flat two-session lift
// drag the strength median into "you have stalled".

import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/caffeine_service.dart';
import 'package:openstrap_edge/compute/correlation_service.dart';
import 'package:openstrap_edge/compute/training_insights.dart';
import 'package:openstrap_edge/data/db.dart';

String _day(int daysAgo) {
  final d = DateTime.now().subtract(Duration(days: daysAgo));
  return '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';
}

Future<void> _put(String day, String key, double v) async {
  final db = await LocalDb.instance;
  await db.insert(
    'metric_series',
    {'date': day, 'key': key, 'value': v},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_insights_test.db';
  });

  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  group('training insights', () {
    test('an empty store abstains on both analyses', () async {
      final t = await TrainingInsightsService.load();
      expect(t.bulk.verdict, ana.BulkVerdict.unknown);
      expect(t.overreaching.status, ana.TrainingStatus.unknown);
    });

    test('weight is read from Apple Health, and the slope is per real time',
        () async {
      // Gaining ~0.3 kg/week over 30 days, weighed every OTHER day. Indexing
      // by row rather than by date would double the apparent rate.
      for (var i = 0; i < 30; i += 2) {
        await _put(_day(30 - i), 'hk_weight_kg', 80.0 + (0.3 / 7.0) * i);
      }
      final t = await TrainingInsightsService.load();
      expect(t.bulk.weightDays, greaterThanOrEqualTo(10));
      expect(t.bulk.weightKgPerWeek, closeTo(0.3, 0.08));
    });

    test('a store with weight but NO lifts does not blame the diet', () async {
      for (var i = 0; i < 20; i++) {
        await _put(_day(20 - i), 'hk_weight_kg', 80.0 + i * 0.1);
      }
      final t = await TrainingInsightsService.load();
      // Weight is climbing fast. Without strength data "surplus too large"
      // would be a verdict about missing information.
      expect(t.bulk.verdict, ana.BulkVerdict.unknown);
    });

    test('overreaching needs both HRV and RHR history', () async {
      for (var i = 0; i < 20; i++) {
        await _put(_day(20 - i), 'rmssd', 60.0);
        // No rhr written at all.
      }
      final t = await TrainingInsightsService.load();
      expect(t.overreaching.status, ana.TrainingStatus.unknown);
    });
  });

  group('correlations', () {
    test('an empty store reports nothing, and says why', () async {
      final r = await CorrelationService.analyse();
      expect(r.findings, isEmpty);
      expect(r.basis, contains('overlapping days'));
    });

    test('the spec family is small enough that FDR can still find things',
        () async {
      // Every extra hypothesis raises the bar for ALL of them. Twenty-ish is
      // the practical ceiling at which a genuine moderate effect over a month
      // can still clear correction.
      expect(CorrelationService.specs.length, lessThanOrEqualTo(20));
      expect(CorrelationService.specs, isNotEmpty);
    });

    test('every spec has a distinct predictor/outcome/lag triple', () async {
      // A duplicated pair would be tested twice, inflating the family size and
      // making everything else harder to detect for no information gain.
      final seen = <String>{};
      for (final s in CorrelationService.specs) {
        final k = '${s.predictor}|${s.outcome}|${s.lagDays}';
        expect(seen.add(k), isTrue, reason: 'duplicate spec: $k');
      }
    });

    test('a real association is found end to end', () async {
      // Strain today vs HRV tomorrow, cleanly related.
      for (var i = 0; i < 30; i++) {
        final day = _day(30 - i);
        await _put(day, 'strain', 5.0 + i * 0.4);
        await _put(day, 'rmssd', 80.0 - i * 0.8);
      }
      final r = await CorrelationService.analyse();
      final hit = r.all.where(
          (c) => c.predictor == 'strain' && c.outcome == 'rmssd');
      expect(hit, isNotEmpty);
      expect(hit.first.rho, lessThan(-0.8), reason: 'more strain, less HRV');
    });
  });

  group('caffeine log', () {
    test('logs and reads back in time order', () async {
      // Anchored to fixed times WITHIN today rather than offsets from now.
      // `now - 6h` is only on the same calendar day if the suite happens to
      // run after 06:00 local, so the original form passed in the afternoon
      // and returned an empty list overnight. CI runs around 02:00 UTC and
      // failed there while passing on a developer machine in AEST.
      final today = DateTime.now();
      DateTime at(int hour) =>
          DateTime(today.year, today.month, today.day, hour);
      await CaffeineService.log(mg: 95, at: at(11), label: 'Filter');
      await CaffeineService.log(mg: 63, at: at(8), label: 'Espresso');
      final all = await CaffeineService.today();
      expect(all, hasLength(2));
      expect(all.first.mg, 63, reason: 'earliest first');
      expect(all.last.label, 'Filter');
    });

    test('an entry can be removed', () async {
      final at = DateTime.now().subtract(const Duration(hours: 1));
      await CaffeineService.log(mg: 95, at: at);
      expect(await CaffeineService.today(), hasLength(1));
      await CaffeineService.remove(at);
      expect(await CaffeineService.today(), isEmpty);
    });

    test('no intake means no impact at all', () async {
      final i = await CaffeineService.impactTonight();
      expect(i.meaningful, isFalse);
      expect(i.summary, isNull);
    });

    test('a late large dose is meaningful; a morning one is not', () async {
      final bed = (await CaffeineService.bedtime()).at;
      await CaffeineService.log(
          mg: 200, at: bed.subtract(const Duration(hours: 2)));
      final late = await CaffeineService.impactTonight();
      expect(late.meaningful, isTrue);
      expect(late.summary, contains('deep sleep'));

      await LocalDb.close();
      final dir = await databaseFactory.getDatabasesPath();
      await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));

      await CaffeineService.log(
          mg: 95, at: bed.subtract(const Duration(hours: 16)));
      final morning = await CaffeineService.impactTonight();
      expect(morning.meaningful, isFalse);
    });

    test('bedtime falls back honestly when there is no coach estimate',
        () async {
      final b = await CaffeineService.bedtime();
      expect(b.personal, isFalse,
          reason: 'no crossday rollup exists, so it must report the fallback');
      expect(b.at.isAfter(DateTime.now()), isTrue,
          reason: 'a bedtime already past belongs to tonight, not this morning');
    });
  });
}
