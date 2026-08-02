// nap_service.dart — reading the naps the derivation engine already finds.
//
// Nap DETECTION is not new work: `derivation_engine` has produced a `naps`
// block since v20 (van Hees immobility + an HR autonomic dip, bounded to
// 20 min - 3 h, with main sleep excluded so the night cannot be re-counted as
// a nap). What was missing was any way to SEE it. This file is the read path.
//
// WHAT A NAP IS NOT. The detector's own note is explicit that this is a wrist
// ESTIMATE and not PSG, and two limits follow from that which the UI must
// respect:
//
//   1. NO STAGING. The nightly stager needs a long consolidated bout to
//      establish the within-sleep references it stages against — its own code
//      requires >= 60 min precisely so daytime naps cannot pollute the night
//      profile. A 20-minute nap therefore gets a duration and nothing else.
//      Reporting "12 min REM" for a nap would be invention.
//
//   2. NAP MINUTES ARE NOT NIGHT MINUTES. Adding them to nocturnal TST as if
//      interchangeable would be wrong in both directions: short naps are
//      overwhelmingly light sleep, and a nap also discharges the homeostatic
//      sleep pressure that drives the following night. Naps are therefore
//      reported ALONGSIDE the night, never silently folded into it.
//
// So this file surfaces what is real (that you slept, when, for how long, and
// how confident the detector is) and abstains from the rest.

import 'dart:convert';

import '../data/db.dart';

/// One detected daytime sleep bout.
class Nap {
  final DateTime start;
  final DateTime end;

  /// Duration in minutes, as reported by the detector.
  final int minutes;

  /// Detector confidence, 0-1. Surfaced rather than hidden: a 0.4 nap and a
  /// 0.9 nap are different claims and should not look alike.
  final double confidence;

  /// Minutes actually asleep, as opposed to the window's length.
  final double tstMin;

  /// Stage minutes from the SAME cardio stager the night uses. These were
  /// computed all along and discarded; nothing new is being estimated here.
  final double lightMin;
  final double deepMin;
  final double remMin;

  /// Lowest 5-minute rolling-mean HR during the nap, bpm.
  final int? restingHr;

  /// Mean RMSSD during the nap, ms. Often null: a short nap rarely yields
  /// enough clean beats, and abstaining is correct there.
  final double? avgHrv;

  /// Whether the nap is long enough for its stage split to be worth trusting.
  /// Set by analytics from the session length, not re-derived here.
  final bool stagingReliable;

  const Nap({
    required this.start,
    required this.end,
    required this.minutes,
    required this.confidence,
    this.tstMin = 0,
    this.lightMin = 0,
    this.deepMin = 0,
    this.remMin = 0,
    this.stagingReliable = false,
    this.restingHr,
    this.avgHrv,
  });

  /// True when the stager produced a split at all. A nap detected before this
  /// change has no stage fields, so old days stay duration-only rather than
  /// rendering a bar of zeroes.
  bool get hasStages => (lightMin + deepMin + remMin) > 0;

  /// Naps below this confidence are shown as uncertain rather than as fact.
  static const double kLowConfidence = 0.5;

  bool get isLowConfidence => confidence < kLowConfidence;

  /// A restorative nap without much sleep inertia on waking.
  ///
  /// The "power nap" band is conventionally ~10-30 min: long enough to be
  /// restorative, short enough to end before the deep sleep whose interruption
  /// causes prolonged grogginess. This is a descriptive label on the duration,
  /// not a claim about what stages were actually reached — the detector cannot
  /// see stages at this length.
  bool get isShort => minutes <= 30;

  /// Long enough that waking mid-cycle is likely, and long enough to measurably
  /// reduce the coming night's sleep pressure.
  bool get isLong => minutes >= 90;
}

class NapService {
  NapService._();

  /// Naps detected on [day] ('YYYY-MM-DD'), earliest first.
  static Future<List<Nap>> forDay(String day) async {
    try {
      final bundle = await LocalDb.dayResult(day);
      if (bundle == null) return const [];
      return _parse(bundle);
    } catch (_) {
      // A read failure means "we do not know", which the empty state handles.
      // It must never surface as "you did not nap".
      return const [];
    }
  }

  /// Extract the naps block from a day_result payload.
  ///
  /// Split out and left visible for tests: the block's shape is set by the
  /// derivation engine, and a change there should fail a test here rather than
  /// silently produce an empty list forever.
  /// Test seam for [_parse]; the block shape is set by the derivation engine
  /// and a change there must fail a test rather than silently yield nothing.
  static List<Nap> parseForTest(Map<String, dynamic> bundle) => _parse(bundle);

  static List<Nap> _parse(Map<String, dynamic> bundle) {
    Object? payload = bundle['payload_json'] ?? bundle['payload'] ?? bundle;
    if (payload is String) {
      payload = jsonDecode(payload);
    }
    if (payload is! Map) return const [];

    final naps = payload['naps'];
    if (naps is! Map) return const [];
    final list = naps['value'];
    if (list is! List) return const [];

    final out = <Nap>[];
    for (final e in list) {
      if (e is! Map) continue;
      // Epoch SECONDS, matching the rest of the derived bundle.
      final s = (e['start'] as num?)?.toInt();
      final en = (e['end'] as num?)?.toInt();
      final mins = (e['duration_min'] as num?)?.toInt();
      if (s == null || en == null || mins == null || mins <= 0) continue;
      out.add(
        Nap(
          start: DateTime.fromMillisecondsSinceEpoch(s * 1000),
          end: DateTime.fromMillisecondsSinceEpoch(en * 1000),
          minutes: mins,
          confidence: (e['confidence'] as num?)?.toDouble() ?? 0.0,
          tstMin: (e['tst_min'] as num?)?.toDouble() ?? 0,
          lightMin: (e['light_min'] as num?)?.toDouble() ?? 0,
          deepMin: (e['deep_min'] as num?)?.toDouble() ?? 0,
          remMin: (e['rem_min'] as num?)?.toDouble() ?? 0,
          stagingReliable: e['staging_reliable'] == true,
          restingHr: (e['resting_hr'] as num?)?.toInt(),
          avgHrv: (e['avg_hrv'] as num?)?.toDouble(),
        ),
      );
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  /// Total nap minutes per day over the trailing [days], for the trend.
  ///
  /// Reads the `nap_min` scalar rather than re-parsing every bundle: the
  /// scalar is written by the same derivation pass, and a day with no naps
  /// legitimately has no row.
  static Future<Map<String, double>> trend({int days = 30}) async {
    try {
      final db = await LocalDb.instance;
      final from = DateTime.now().subtract(Duration(days: days));
      final cutoff = '${from.year.toString().padLeft(4, '0')}-'
          '${from.month.toString().padLeft(2, '0')}-'
          '${from.day.toString().padLeft(2, '0')}';
      final rows = await db.query(
        'metric_series',
        columns: ['date', 'value'],
        where: 'key = ? AND date >= ? AND value IS NOT NULL',
        whereArgs: ['nap_min', cutoff],
        orderBy: 'date ASC',
      );
      return {
        for (final r in rows)
          if (r['date'] is String && r['value'] is num)
            r['date'] as String: (r['value'] as num).toDouble(),
      };
    } catch (_) {
      return const {};
    }
  }
}
