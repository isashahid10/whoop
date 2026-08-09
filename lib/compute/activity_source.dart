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
// THE RULE DEPENDS ON THE QUANTITY, because the two sources fail differently.
//
//   STEPS  -> PHONE FIRST. The iPhone counts steps in dedicated hardware and
//             is a real measurement. The band cannot count steps at all from
//             its 1 Hz stream (gait is 1.4-2.5 Hz, above the Nyquist limit), so
//             its figure is ambulatory-minutes x a cadence band. A real count
//             beats an estimate.
//
//   ENERGY -> BAND FIRST. This is the opposite, for a concrete reason. The
//             band's figure comes from Keytel et al. 2005 applied to MEASURED
//             HEART RATE; the phone's comes from accelerometry, which sees
//             nothing whenever the phone is not on your body.
//
//             Observed on 2026-08-07: 2.5 hours of badminton at a mean 125 bpm
//             with peaks to 163. The band charged 2,432 kcal. The phone, sitting
//             in a bag courtside, charged 176. Phone-first showed the 176.
//             Any sport played without a phone in your pocket hits this, and
//             the failure is silent and large.
//
// Both paths SAY WHICH source won. A silent switch between two sources that
// disagree is worse than either, because the user cannot tell whether a jump is
// real. Every result carries its provenance so the UI can label it.
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

  /// Active energy for [date] - the "move" number, excluding resting burn.
  ///
  /// BAND FIRST, unlike [steps]. See the rule at the top of this file: the
  /// band's figure is Keytel applied to measured heart rate, the phone's is
  /// inferred from motion, and the phone measures nothing at all when it is not
  /// on you. Falling back to the phone still matters for days the band was off
  /// the wrist or never synced.
  static Future<SourcedValue> activeCalories(
    String date, {
    num? bandCalories,
  }) async {
    final band = bandCalories?.toDouble() ?? await _metric(date, kBandCalories);
    // A zero or negative figure means the band contributed nothing usable, not
    // that the day was genuinely sedentary; treat it as absent rather than
    // letting it beat a real phone reading.
    if (band != null && band > 0) return SourcedValue(band, ActivitySource.band);
    final phone = await _metric(date, kPhoneActiveKcal);
    if (phone != null) return SourcedValue(phone, ActivitySource.phone);
    return SourcedValue.absent;
  }

  /// How far apart the two energy sources are for [date], as a ratio of the
  /// larger to the smaller. Null when only one source has a figure.
  ///
  /// A large gap is INFORMATION, not noise: it means you trained while the
  /// phone was elsewhere. The UI uses it to explain the number rather than
  /// silently presenting whichever source won.
  static Future<double?> energyDisagreement(String date) async {
    final band = await _metric(date, kBandCalories);
    final phone = await _metric(date, kPhoneActiveKcal);
    if (band == null || phone == null) return null;
    if (band <= 0 || phone <= 0) return null;
    return band > phone ? band / phone : phone / band;
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
    // Band first, to stay consistent with [activeCalories]. Mixing sources
    // between the two would let "total" come out BELOW "active" on a day the
    // band saw a hard session the phone missed, which is nonsense on its face.
    final band = bandTotal?.toDouble() ?? await _metric(date, kBandCaloriesTotal);
    if (band != null && band > 0) return SourcedValue(band, ActivitySource.band);

    final active = await _metric(date, kPhoneActiveKcal);
    final basal = await _metric(date, kPhoneBasalKcal);
    if (active != null && basal != null) {
      return SourcedValue(active + basal, ActivitySource.phone);
    }
    return SourcedValue.absent;
  }
}
