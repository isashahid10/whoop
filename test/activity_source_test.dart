// Where the day's steps and energy come from.
//
// Two sources measure the same thing and disagree badly: the phone counts
// steps in hardware all day, the band estimates them from wrist motion and
// only while worn. Reading the band alone is what made the figure wrong,
// static through the day, and blank for days before the band existed.
//
// The rules worth defending are the ones that would silently produce a wrong
// number: never sum the two, never call a partial figure a total, and never
// mistake a real zero for missing data.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/compute/activity_source.dart';
import 'package:openstrap_edge/data/db.dart';

const _day = '2026-07-28';

Future<void> _put(String key, double value, {String day = _day}) async {
  final db = await LocalDb.instance;
  await db.insert(
    'metric_series',
    {'date': day, 'key': key, 'value': value},
    conflictAlgorithm: ConflictAlgorithm.replace,
  );
}

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_activity_source_test.db';
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

  group('steps', () {
    test('the PHONE wins when Health has the day', () async {
      await _put(ActivitySourceResolver.kPhoneSteps, 8412);
      final s = await ActivitySourceResolver.steps(_day, bandSteps: 20);
      expect(s.value, 8412);
      expect(s.source, ActivitySource.phone);
      expect(s.label, 'Apple Health');
    });

    test('the two are NEVER summed', () async {
      // Both count the same walking; adding them would roughly double a day
      // spent carrying the phone while wearing the band.
      await _put(ActivitySourceResolver.kPhoneSteps, 8000);
      final s = await ActivitySourceResolver.steps(_day, bandSteps: 500);
      expect(s.value, 8000);
      expect(s.value, isNot(8500));
    });

    test('falls back to the band when Health has nothing', () async {
      final s = await ActivitySourceResolver.steps(_day, bandSteps: 3200);
      expect(s.value, 3200);
      expect(s.source, ActivitySource.band);
      expect(s.label, 'wrist estimate');
    });

    test('a real zero from the phone is a MEASUREMENT, not missing data',
        () async {
      // "You did not move today" is a fact. Treating 0 as absent would fall
      // through to the band and report its estimate as the day's steps.
      await _put(ActivitySourceResolver.kPhoneSteps, 0);
      final s = await ActivitySourceResolver.steps(_day, bandSteps: 900);
      expect(s.value, 0);
      expect(s.source, ActivitySource.phone);
    });

    test('neither source is an honest absence, not a zero', () async {
      final s = await ActivitySourceResolver.steps(_day);
      expect(s.value, isNull);
      expect(s.present, isFalse);
      expect(s.source, ActivitySource.none);
    });

    test('a day the band never saw still resolves from Health history',
        () async {
      // The whole point of reading Health: it holds years that predate the
      // band, so past days are no longer blank.
      await _put(ActivitySourceResolver.kPhoneSteps, 11000, day: '2024-01-15');
      final s = await ActivitySourceResolver.steps('2024-01-15');
      expect(s.value, 11000);
      expect(s.source, ActivitySource.phone);
    });
  });

  group('energy', () {
    test('active energy prefers the phone', () async {
      await _put(ActivitySourceResolver.kPhoneActiveKcal, 640);
      final c = await ActivitySourceResolver.activeCalories(
        _day,
        bandCalories: 99,
      );
      expect(c.value, 640);
      expect(c.source, ActivitySource.phone);
    });

    test('total = active + basal', () async {
      await _put(ActivitySourceResolver.kPhoneActiveKcal, 600);
      await _put(ActivitySourceResolver.kPhoneBasalKcal, 1700);
      final c = await ActivitySourceResolver.totalCalories(_day);
      expect(c.value, 2300);
      expect(c.source, ActivitySource.phone);
    });

    test('a MISSING basal falls back to the band rather than reporting '
        'active-alone as a total', () async {
      // Active-alone is roughly a third of true daily energy. Labelling it
      // "total" would be a materially wrong number wearing the right name.
      await _put(ActivitySourceResolver.kPhoneActiveKcal, 600);
      final c = await ActivitySourceResolver.totalCalories(
        _day,
        bandTotal: 2450,
      );
      expect(c.value, 2450);
      expect(c.source, ActivitySource.band);
    });
  });
}
