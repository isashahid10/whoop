// activity_source.dart — decide WHERE the day's steps and energy come from.
//
// THE PROBLEM THIS SOLVES. Two sources measure the same things:
//
//   BAND   a wrist-motion estimate (AN-2554 step detection over the 1 Hz
//          accelerometer). Only covers time the band was actually worn, and
//          only updates when the band syncs and a derivation pass runs.
//   PHONE  Apple Health. The iPhone counts steps in hardware whenever it is on
//          your person, HealthKit aggregates every contributing device, and it
//          holds years of history that predate this app entirely.
//
// The app was reading ONLY the band, which produced three complaints that are
// all the same bug: the number was wrong (a barely-worn band sees almost no
// steps), it did not move through the day (it changes only on sync + derive),
// and previous days were blank (the band has no history before you owned it,
// while Health does).
//
// THE RULE: prefer the phone, fall back to the band, and SAY WHICH. A silent
// switch between two sources that disagree is worse than either, because the
// user cannot tell whether a jump is real. Every result carries its provenance
// so the UI can label it.
//
// Deliberately NOT summed. Both sources count the same walking, so adding them
// would roughly double a day spent with band and phone together.

import '../data/db.dart';

/// Where a figure came from.
enum ActivitySource {
  /// Apple Health / Health Connect — the phone's own count.
  phone,

  /// The band's wrist-motion estimate.
  band,

  /// Neither source had a value.
  none,
}

/// One resolved figure plus its provenance.
class SourcedValue {
  final double? value;
  final ActivitySource source;

  const SourcedValue(this.value, this.source);

  static const SourcedValue absent = SourcedValue(null, ActivitySource.none);

  bool get present => value != null;

  /// Short provenance label for the UI. Null when there is nothing to caption.
  ///
  /// The band figure is explicitly marked an estimate; the phone's is a real
  /// count and must not be tarred with the same badge.
  String? get label => switch (source) {
        ActivitySource.phone => 'Apple Health',
        ActivitySource.band => 'wrist estimate',
        ActivitySource.none => null,
      };
}

class ActivitySourceResolver {
  ActivitySourceResolver._();

  /// metric_series keys, in the order they are preferred.
  static const String kPhoneSteps = 'hk_steps';
  static const String kPhoneActiveKcal = 'hk_active_kcal';
  static const String kPhoneBasalKcal = 'hk_basal_kcal';

  /// The band's own derived figures, as persisted by the derivation engine.
  ///
  /// Read as a LAST resort. The caller normally passes the band value straight
  /// from the day bundle, but that bundle is null on any day the derivation has
  /// not produced one — and then the tile went blank even though the derived
  /// scalar was sitting in metric_series the whole time.
  static const String kBandSteps = 'steps';
  static const String kBandCalories = 'calories';
  static const String kBandCaloriesTotal = 'calories_total';

  static Future<double?> _metric(String date, String key) async {
    try {
      final db = await LocalDb.instance;
      final rows = await db.query(
        'metric_series',
        columns: ['value'],
        where: 'date = ? AND key = ?',
        whereArgs: [date, key],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final v = (rows.first['value'] as num?)?.toDouble();
      // A stored 0 is a real measurement ("you did not move"), so it is kept —
      // only a missing row means "no data".
      return v;
    } catch (_) {
      return null;
    }
  }

  /// Steps for [date]: the phone's count when Health has one, else the band's
  /// estimate.
  ///
  /// [bandSteps] is whatever the derivation produced, passed in rather than
  /// re-read so this stays a pure preference decision.
  static Future<SourcedValue> steps(String date, {num? bandSteps}) async {
    final phone = await _metric(date, kPhoneSteps);
    if (phone != null) return SourcedValue(phone, ActivitySource.phone);
    if (bandSteps != null) {
      return SourcedValue(bandSteps.toDouble(), ActivitySource.band);
    }
    final stored = await _metric(date, kBandSteps);
    if (stored != null) return SourcedValue(stored, ActivitySource.band);
    return SourcedValue.absent;
  }

  /// Active energy for [date] — the "move" number, excluding resting burn.
  static Future<SourcedValue> activeCalories(
    String date, {
    num? bandCalories,
  }) async {
    final phone = await _metric(date, kPhoneActiveKcal);
    if (phone != null) return SourcedValue(phone, ActivitySource.phone);
    if (bandCalories != null) {
      return SourcedValue(bandCalories.toDouble(), ActivitySource.band);
    }
    final stored = await _metric(date, kBandCalories);
    if (stored != null) return SourcedValue(stored, ActivitySource.band);
    return SourcedValue.absent;
  }

  /// Total energy = active + basal.
  ///
  /// Health stores the two separately, so a "total" only exists once both are
  /// present. Falling back to active-alone would be a materially different
  /// number wearing the same label — roughly a third of the true figure.
  static Future<SourcedValue> totalCalories(
    String date, {
    num? bandTotal,
  }) async {
    final active = await _metric(date, kPhoneActiveKcal);
    final basal = await _metric(date, kPhoneBasalKcal);
    if (active != null && basal != null) {
      return SourcedValue(active + basal, ActivitySource.phone);
    }
    if (bandTotal != null) {
      return SourcedValue(bandTotal.toDouble(), ActivitySource.band);
    }
    final stored = await _metric(date, kBandCaloriesTotal);
    if (stored != null) return SourcedValue(stored, ActivitySource.band);
    return SourcedValue.absent;
  }
}
