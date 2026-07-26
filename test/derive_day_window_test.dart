// Regression tests for three quieter derivation defects:
//
//  * the deliberate widening of the nocturnal search window was a NO-OP,
//    because the coordinator only ever LOADED substrate back to the previous
//    18:00 while the day model searches from the previous NOON — so
//    `searchStart = max(dataStart, …)` clipped it straight back and any sleep
//    onset before 18:00 was truncated to the slice start;
//  * the habitual-midsleep prior converted HISTORICAL sleep blocks using the
//    CURRENT UTC offset, so re-deriving days from the other side of a DST
//    transition (or a trip) shifted them by an hour and could change which
//    candidate sleep was selected;
//  * `_buildWakeDayFeatures` substituted age 30 / 70 kg / sex 'm' / RHR 60 for
//    a user who never entered a profile and then PERSISTED strain / calories /
//    calories_total as real scalars — fabricated numbers wearing real numbers'
//    clothes, against the never-impute contract the rest of the layer keeps.

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:openstrap_edge/compute/derivation_engine.dart';
import 'package:openstrap_edge/compute/profile.dart';
import 'package:openstrap_edge/compute/substrate.dart';
import 'package:openstrap_edge/data/db.dart';

/// A flat 1 Hz substrate over [durSec] starting at [startSec], HR [hr].
Substrate _synthDay(int startSec, int durSec, {int hr = 82}) {
  final ts = <int>[];
  final hrs = <int>[];
  final ax = <double>[], ay = <double>[], az = <double>[];
  for (var i = 0; i < durSec; i++) {
    ts.add(startSec + i);
    hrs.add(hr + (i % 7)); // gentle deterministic variation, never 0
    // Enough orientation change to produce real motion minutes.
    ax.add(0.05 * ((i % 60) / 60.0));
    ay.add(0.05 * ((i % 30) / 30.0));
    az.add(0.98);
  }
  final n = ts.length;
  return Substrate(
    tsSec: ts,
    hr: hrs,
    rrTsMs: const [],
    rrMs: const [],
    ax: ax,
    ay: ay,
    az: az,
    spo2Red: List<int>.filled(n, 0),
    spo2Ir: List<int>.filled(n, 0),
    skinTemp: List<int>.filled(n, 3000),
    skinContact: List<int>.filled(n, 0),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_day_window_test.db';
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  // ── the loaded window must cover the whole documented search window ────────

  group('target-day substrate window', () {
    test('reaches back to the previous local NOON, not 18:00', () {
      const dayId = '2026-04-10';
      final dayStart = DateTime(2026, 4, 10).millisecondsSinceEpoch ~/ 1000;
      final dayEnd = DateTime(2026, 4, 11).millisecondsSinceEpoch ~/ 1000;

      final (from, to) = DerivationEngine().debugTargetDayWindow(dayId);

      expect(dayStart - from, kNocturnalSearchLookbackSec,
          reason: 'calendarDays searches from dayStart − '
              'kNocturnalSearchLookbackSec; loading less means '
              '`searchStart = max(dataStart, …)` silently clips it back');
      expect(dayStart - from, 12 * 3600, reason: 'the previous local NOON');
      expect(from, lessThan(dayStart - 6 * 3600),
          reason: 'strictly wider than the old prev-18:00 window, which made '
              'the documented widening a no-op');
      expect(to, dayEnd - 1);
    });

    test('the constant the loader uses is the one the day model searches with',
        () {
      // Two call sites, one constant — they cannot drift apart again.
      const dayId = '2026-10-25'; // a European DST-transition date
      final dayStart = DateTime(2026, 10, 25).millisecondsSinceEpoch ~/ 1000;
      final (from, _) = DerivationEngine().debugTargetDayWindow(dayId);
      expect(from, dayStart - kNocturnalSearchLookbackSec);
    });
  });

  // ── the habitual-midsleep prior is resolved AT THE DAY, not at "now" ───────

  group('historical timezone offset', () {
    test('tzOffsetSecondsAt resolves per instant, not once for today', () {
      final jan = DateTime(2020, 1, 15, 3, 0).millisecondsSinceEpoch ~/ 1000;
      final jul = DateTime(2020, 7, 15, 3, 0).millisecondsSinceEpoch ~/ 1000;
      for (final t in [jan, jul]) {
        expect(
          tzOffsetSecondsAt(t),
          DateTime.fromMillisecondsSinceEpoch(t * 1000, isUtc: false)
              .timeZoneOffset
              .inSeconds,
          reason: 'must ask the platform for the offset that applied THEN',
        );
      }
      // In a DST-observing zone the two instants disagree; a constant
      // "today's offset" cannot equal both.
      final janOff = tzOffsetSecondsAt(jan);
      final julOff = tzOffsetSecondsAt(jul);
      if (janOff != julOff) {
        final nowOff = DateTime.now().timeZoneOffset.inSeconds;
        expect(janOff == nowOff && julOff == nowOff, isFalse);
      }
    });

    test('calendarDays resolves the offset AT the day being segmented', () {
      // Zone-independent: inject the resolver and inspect what it was asked
      // for. The old code never asked at all — it read
      // `DateTime.now().timeZoneOffset`, a constant applied to every
      // historical day regardless of the offset actually in effect then.
      final dayStart = DateTime(2020, 1, 15).millisecondsSinceEpoch ~/ 1000;
      final sub = _synthDay(dayStart + 3600, 900);
      final asked = <int>[];
      final days = calendarDays(
        sub,
        // An override forces the segmentation branch (and therefore the
        // habitual-midsleep prior) to run on a short synthetic capture.
        override: SleepWindowOverride(
          dayId: '2020-01-15',
          onsetSec: dayStart + 3700,
          offsetSec: dayStart + 4300,
          source: 'manual',
        ),
        tzOffsetAt: (t) {
          asked.add(t);
          return DateTime.fromMillisecondsSinceEpoch(t * 1000).timeZoneOffset
              .inSeconds;
        },
      );

      expect(days, isNotEmpty);
      expect(asked, isNotEmpty,
          reason: 'the offset must be RESOLVED per day, not read off '
              'DateTime.now() once');
      final nowSec = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      for (final t in asked) {
        expect(t, dayStart,
            reason: 'resolved at the local midnight of the day being '
                'segmented');
        expect((t - nowSec).abs(), greaterThan(86400),
            reason: 'a historical instant, emphatically not "now"');
      }
    });
  });

  // ── never impute a profile ────────────────────────────────────────────────

  group('absent profile abstains instead of imputing', () {
    // 2 h of daytime 1 Hz data on one calendar day — no sleep, so every minute
    // is wake and the wake-day feature block runs in full.
    final dayStart = DateTime(2026, 4, 10).millisecondsSinceEpoch ~/ 1000;

    Future<Map<String, double?>> deriveWith(
      Profile profile,
      String dayLabel,
      int localDayStart,
    ) async {
      final sub = _synthDay(localDayStart + 9 * 3600, 2 * 3600);
      await DerivationEngine()
          .deriveImportedDays(sub, profile, {dayLabel});
      final out = <String, double?>{};
      for (final key in const [
        'strain',
        'trimp',
        'calories',
        'calories_total',
        'steps',
      ]) {
        out[key] = await LocalDb.metricValueOn(dayLabel, key);
      }
      return out;
    }

    test('no profile → no strain, no calories, no TDEE', () async {
      final got = await deriveWith(const Profile(), '2026-04-10', dayStart);
      expect(got['strain'], isNull,
          reason: 'Banister TRIMP needs a real resting HR, HRmax and sex — '
              'age 30 / RHR 60 / sex m were fabricated');
      expect(got['calories'], isNull,
          reason: 'Keytel needs real age, weight and sex');
      expect(got['calories_total'], isNull,
          reason: 'Mifflin BMR needs real anthropometrics');
    });

    test('steps still compute without a profile (data-derived, not imputed)',
        () async {
      // `dailyStepEstimate` falls back to the day's own 10th-percentile HR when
      // no resting HR is known — that is derived from the data, so abstaining
      // would be over-correction.
      final got = await deriveWith(const Profile(), '2026-04-11',
          DateTime(2026, 4, 11).millisecondsSinceEpoch ~/ 1000);
      expect(got['steps'], isNotNull);
    });

    test('a real profile still produces strain and calories', () async {
      final got = await deriveWith(
        const Profile(
          ageYears: 34,
          weightKg: 72,
          heightCm: 178,
          sex: 'm',
          restingHrManual: 55,
        ),
        '2026-04-12',
        DateTime(2026, 4, 12).millisecondsSinceEpoch ~/ 1000,
      );
      expect(got['strain'], isNotNull,
          reason: 'the abstention must be about MISSING inputs only');
      expect(got['calories'], isNotNull);
      expect(got['calories_total'], isNotNull);
    });
  });
}
