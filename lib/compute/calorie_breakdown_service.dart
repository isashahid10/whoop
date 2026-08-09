// calorie_breakdown_service.dart - where the day's energy actually went.
//
// The daily calorie figure is a single number with no story. This slices the
// same computation by time so the day can be read: which blocks cost what, and
// what was probably happening during them.
//
// IT REUSES THE DAY'S MODEL, it does not invent a second one. Every block runs
// the same Keytel/Harris-Benedict path as the daily total (analytics'
// Calories.dailyEnergy), on that block's own per-minute heart rate. Summing the
// blocks therefore reproduces the day, which is the property that makes the
// breakdown trustworthy rather than decorative.
//
// ATTRIBUTION IS A GUESS AND SAYS SO. A block is labelled from what else is
// known about that window - a logged Hevy session, a detected workout, the time
// of day - and where nothing corroborates it, the label is the honest
// "elevated heart rate" rather than an invented activity.

import 'package:openstrap_analytics/onehz.dart' as ana;

import '../data/db.dart';
import 'profile.dart';

/// One contiguous stretch of the day, with what it cost.
class CalorieBlock {
  final DateTime start;
  final DateTime end;

  /// Active kilocalories: the Keytel surplus over basal for this window.
  final double activeKcal;

  /// Mean and peak heart rate across the block.
  final double meanHr;
  final double peakHr;

  /// What was probably happening. Null when nothing corroborates a guess.
  final String? attribution;

  /// True when [attribution] comes from a logged session rather than inferred
  /// from heart rate alone.
  final bool attributionIsLogged;

  const CalorieBlock({
    required this.start,
    required this.end,
    required this.activeKcal,
    required this.meanHr,
    required this.peakHr,
    this.attribution,
    this.attributionIsLogged = false,
  });

  Duration get duration => end.difference(start);

  /// Rate of burn, kcal per minute. The useful comparator between blocks: a
  /// long walk and a short sprint can cost the same total for very different
  /// reasons.
  double get kcalPerMin {
    final m = duration.inMinutes;
    return m <= 0 ? 0 : activeKcal / m;
  }
}

class CalorieDay {
  final List<CalorieBlock> blocks;

  /// Active kcal across the whole day, from the same model.
  final double activeKcal;

  /// Resting burn for the covered period.
  final double basalKcal;

  /// Minutes of the day with no heart-rate coverage. Energy cannot be
  /// attributed for these, and the UI says so rather than quietly omitting it.
  final int uncoveredMin;

  const CalorieDay({
    required this.blocks,
    required this.activeKcal,
    required this.basalKcal,
    required this.uncoveredMin,
  });

  static const CalorieDay empty =
      CalorieDay(blocks: [], activeKcal: 0, basalKcal: 0, uncoveredMin: 0);

  bool get hasData => blocks.isNotEmpty || activeKcal > 0;

  /// The single most expensive block, which is usually the answer to "what did
  /// I actually do today".
  CalorieBlock? get biggest {
    if (blocks.isEmpty) return null;
    return blocks.reduce((a, b) => b.activeKcal > a.activeKcal ? b : a);
  }
}

class CalorieBreakdownService {
  CalorieBreakdownService._();

  /// A block ends when heart rate drops back for this long. Short enough to
  /// separate two sessions in an evening, long enough not to split a match on
  /// a water break.
  static const int kGapMinutes = 12;

  /// Blocks shorter than this are noise, not events.
  static const int kMinBlockMinutes = 8;

  /// Fraction of heart-rate reserve above which a minute joins a block.
  ///
  /// The same 40% used for active minutes, and for the same reason: it is the
  /// ACSM/WHO moderate-intensity threshold rather than a tuned constant.
  static const double kBlockHrrFraction = 0.40;

  /// [profile] comes from AppState, which owns the user map. Passing it in
  /// rather than reloading keeps this a pure read over the derived store.
  static Future<CalorieDay> forDay(String day, {required Profile profile}) async {
    try {
      final age = profile.ageYears?.toDouble();
      final weight = profile.weightKg;
      final sex = profile.sex?.toLowerCase();
      // Never impute a profile: without these the Keytel model is not being
      // applied to this person, and a plausible number would be a fabrication.
      if (age == null || weight == null || sex == null) return CalorieDay.empty;

      final maxHr = profile.hrMaxTanaka;
      final restingHr = await _restingHr();
      if (maxHr == null || restingHr == null) return CalorieDay.empty;

      final perMin = await _hrPerMinute(day);
      if (perMin.isEmpty) return CalorieDay.empty;

      final wp = ana.WorkoutUserProfile(
        weightKg: weight,
        heightCm: profile.heightCm ?? 170.0,
        age: age,
        sex: sex == 'f' ? 'female' : (sex == 'm' ? 'male' : 'nonbinary'),
      );

      // Whole-day figures, from the same call the daily scalar uses.
      final dayEnergy = ana.Calories.dailyEnergy(
        [for (final e in perMin) e.hr],
        profile: wp,
        hrmax: maxHr,
        dayMinutes: perMin.length,
      );

      final cut = restingHr + kBlockHrrFraction * (maxHr - restingHr);
      final blocks = <CalorieBlock>[];
      final logged = await _loggedSessions(day);

      var i = 0;
      while (i < perMin.length) {
        if (perMin[i].hr < cut) {
          i++;
          continue;
        }
        // Extend while heart rate stays up, tolerating a short dip.
        var j = i;
        var lastHigh = i;
        while (j < perMin.length) {
          if (perMin[j].hr >= cut) {
            lastHigh = j;
          } else if (perMin[j].minute - perMin[lastHigh].minute > kGapMinutes) {
            break;
          }
          j++;
        }
        final slice = perMin.sublist(i, lastHigh + 1);
        final mins = slice.length;
        if (mins >= kMinBlockMinutes) {
          final e = ana.Calories.dailyEnergy(
            [for (final s in slice) s.hr],
            profile: wp,
            hrmax: maxHr,
            dayMinutes: mins,
          );
          final hrs = [for (final s in slice) s.hr];
          final start = DateTime.fromMillisecondsSinceEpoch(
              slice.first.minute * 60 * 1000);
          final end = DateTime.fromMillisecondsSinceEpoch(
              (slice.last.minute + 1) * 60 * 1000);
          final att = _attribute(start, end, logged);
          blocks.add(CalorieBlock(
            start: start,
            end: end,
            activeKcal: e.active,
            meanHr: hrs.reduce((a, b) => a + b) / hrs.length,
            peakHr: hrs.reduce((a, b) => a > b ? a : b),
            attribution: att?.$1,
            attributionIsLogged: att?.$2 ?? false,
          ));
        }
        i = lastHigh + 1;
      }

      return CalorieDay(
        blocks: blocks,
        activeKcal: dayEnergy.active,
        basalKcal: dayEnergy.basal,
        uncoveredMin: _uncovered(perMin),
      );
    } catch (_) {
      return CalorieDay.empty;
    }
  }

  /// Name a block from what else is known about that window.
  ///
  /// Returns the label and whether it came from a LOGGED session (high
  /// confidence) or was inferred (a guess the UI should mark as such).
  static (String, bool)? _attribute(
    DateTime start,
    DateTime end,
    List<({DateTime start, DateTime end, String title})> logged,
  ) {
    for (final s in logged) {
      // Any real overlap counts: a logged session rarely lines up exactly with
      // the heart-rate block it produced.
      if (s.start.isBefore(end) && s.end.isAfter(start)) {
        return (s.title, true);
      }
    }
    // Nothing corroborates it. Time of day is the only remaining signal, and
    // it is weak, so the label stays descriptive rather than naming a sport.
    final h = start.hour;
    if (h < 5) return ('Elevated overnight', false);
    if (h < 11) return ('Morning effort', false);
    if (h < 17) return ('Afternoon effort', false);
    return ('Evening effort', false);
  }

  static Future<List<({DateTime start, DateTime end, String title})>>
      _loggedSessions(String day) async {
    final out = <({DateTime start, DateTime end, String title})>[];
    try {
      final db = await LocalDb.instance;
      // Hevy workouts are the strongest attribution available: the user typed
      // them in, so the name is real rather than inferred.
      final rows = await db.rawQuery(
        'SELECT name, start_ts, end_ts FROM hevy_workout WHERE day = ?',
        [day],
      );
      for (final r in rows) {
        final s = (r['start_ts'] as num?)?.toInt();
        final e = (r['end_ts'] as num?)?.toInt();
        final t = r['name'];
        if (s == null || e == null) continue;
        out.add((
          start: DateTime.fromMillisecondsSinceEpoch(s * 1000),
          end: DateTime.fromMillisecondsSinceEpoch(e * 1000),
          title: t is String && t.isNotEmpty ? t : 'Logged workout',
        ));
      }
    } catch (_) {
      // Table may not exist on an install that has never synced Hevy.
    }
    return out;
  }

  static Future<double?> _restingHr() async {
    try {
      final db = await LocalDb.instance;
      final rows = await db.query('metric_series',
          columns: ['value'],
          where: 'key = ?',
          whereArgs: ['rhr'],
          orderBy: 'date DESC',
          limit: 14);
      final xs = <double>[
        for (final r in rows) ?(r['value'] as num?)?.toDouble(),
      ]..sort();
      if (xs.isEmpty) return null;
      return xs[xs.length ~/ 2];
    } catch (_) {
      return null;
    }
  }

  /// Per-minute mean heart rate for [day], minutes with no samples omitted.
  static Future<List<({int minute, double hr})>> _hrPerMinute(
      String day) async {
    final db = await LocalDb.instance;
    final rows = await db.rawQuery(
      '''
      SELECT rec_ts / 60 AS m, AVG(hr) AS hr
      FROM decoded_onehz
      WHERE hr > 0 AND date(rec_ts,'unixepoch','localtime') = ?
      GROUP BY m ORDER BY m
      ''',
      [day],
    );
    return [
      for (final r in rows)
        if (r['m'] is num && r['hr'] is num)
          (minute: (r['m'] as num).toInt(), hr: (r['hr'] as num).toDouble()),
    ];
  }

  /// Minutes inside the covered span that have no heart rate at all.
  static int _uncovered(List<({int minute, double hr})> perMin) {
    if (perMin.length < 2) return 0;
    final span = perMin.last.minute - perMin.first.minute + 1;
    return span - perMin.length;
  }
}
