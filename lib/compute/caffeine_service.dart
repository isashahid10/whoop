// caffeine_service.dart — log intakes, read the residual.
//
// Orchestration only; the decay maths and the published effect sizes live in
// analytics' caffeine.dart.
//
// BEDTIME comes from the sleep coach's recommended bedtime where one exists,
// because "how much is still in me when I actually go to bed" is the only
// version of the question worth answering. A fixed 23:00 assumption would be
// wrong for anyone whose schedule moves, which is most people.

import 'dart:convert';

import 'package:openstrap_analytics/onehz.dart' as ana;
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/db.dart';

/// A drink, with its usual caffeine content.
///
/// Figures are USDA/manufacturer central estimates. They are approximations by
/// nature — brew strength varies enormously — which is exactly why the impact
/// model downstream reports a range rather than a point.
class CaffeinePreset {
  final String label;
  final double mg;
  const CaffeinePreset(this.label, this.mg);

  static const List<CaffeinePreset> all = [
    CaffeinePreset('Espresso', 63),
    CaffeinePreset('Double espresso', 126),
    CaffeinePreset('Filter coffee', 95),
    CaffeinePreset('Instant coffee', 62),
    CaffeinePreset('Black tea', 47),
    CaffeinePreset('Green tea', 28),
    CaffeinePreset('Energy drink', 80),
    CaffeinePreset('Cola', 34),
    CaffeinePreset('Pre-workout', 200),
  ];
}

class CaffeineService {
  CaffeineService._();

  static String _dayOf(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// Record an intake.
  static Future<void> log({
    required double mg,
    DateTime? at,
    String? label,
  }) async {
    try {
      final db = await LocalDb.instance;
      final when = at ?? DateTime.now();
      await db.insert(
        'caffeine_log',
        {
          'ts': when.millisecondsSinceEpoch,
          'day': _dayOf(when),
          'mg': mg,
          'label': label,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {
      // A failed log must never break the screen that called it.
    }
  }

  static Future<void> remove(DateTime at) async {
    try {
      final db = await LocalDb.instance;
      await db.delete('caffeine_log',
          where: 'ts = ?', whereArgs: [at.millisecondsSinceEpoch]);
    } catch (_) {}
  }

  /// Intakes on the calendar day containing [when], earliest first.
  ///
  /// Single implementation on purpose. A previous version of [impactTonight]
  /// grew its own copy of this query and got both the column name and the
  /// timestamp units wrong, which only surfaced as a SQL error in one
  /// timezone.
  static Future<List<({DateTime at, double mg, String? label})>> onDay(
      DateTime when) async {
    try {
      final db = await LocalDb.instance;
      final rows = await db.query(
        'caffeine_log',
        where: 'day = ?',
        whereArgs: [_dayOf(when)],
        orderBy: 'ts ASC',
      );
      return [
        for (final r in rows)
          (
            at: DateTime.fromMillisecondsSinceEpoch((r['ts'] as num).toInt()),
            mg: (r['mg'] as num).toDouble(),
            label: r['label'] as String?,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Today's intakes, earliest first.
  static Future<List<({DateTime at, double mg, String? label})>> today() =>
      onDay(DateTime.now());

  /// Tonight's bedtime: the sleep coach's recommendation when it has one, else
  /// 23:00 as a stated fallback.
  ///
  /// Returned alongside a flag so the UI can say WHICH it used — a residual
  /// computed against a guessed bedtime is worth less than one computed against
  /// the user's actual pattern, and the difference should be visible.
  static Future<({DateTime at, bool personal})> bedtime() async {
    final now = DateTime.now();
    DateTime atHour(int minOfDay) {
      final base = DateTime(now.year, now.month, now.day)
          .add(Duration(minutes: minOfDay));
      // A bedtime that has already passed belongs to tonight, not this morning.
      return base.isAfter(now) ? base : base.add(const Duration(days: 1));
    }

    try {
      final row = await LocalDb.baseline('crossday');
      final raw = row?['payload_json'];
      if (raw is String && raw.isNotEmpty) {
        final j = jsonDecode(raw);
        if (j is Map) {
          final coach = j['sleep_coach'];
          if (coach is Map) {
            final bt = coach['bedtime'];
            final v = bt is Map ? bt['value'] : null;
            final m = v is Map ? (v['bedtime_min_of_day'] as num?) : null;
            if (m != null) return (at: atHour(m.round() % 1440), personal: true);
          }
        }
      }
    } catch (_) {}
    return (at: atHour(23 * 60), personal: false);
  }

  /// Residual and expected cost at tonight's bedtime.
  static Future<ana.CaffeineImpact> impactTonight() async {
    final bed = await bedtime();
    // Doses from TODAY, plus anything already logged against the bedtime's own
    // date when that has rolled past midnight.
    //
    // `bedtime()` returns tomorrow once tonight's hour has passed, so between
    // 23:00 and midnight a coffee logged at 23:30 sits on today's date while
    // bedtime points at tomorrow. Reading only today's log then measured ~23
    // hours of decay and reported no impact, when in fact that coffee lands
    // squarely on the sleep about to happen.
    final doses = <({DateTime at, double mg, String? label})>[
      ...await today(),
      if (_dayOf(bed.at) != _dayOf(DateTime.now())) ...await onDay(bed.at),
    ];
    if (doses.isEmpty) return ana.CaffeineImpact.none;
    return ana.caffeineImpact(
      doses: [
        for (final d in doses) ana.CaffeineDose(mg: d.mg, at: d.at),
      ],
      bedtime: bed.at,
    );
  }

  /// The latest time a [mg] dose could still be taken tonight.
  static Future<DateTime?> cutoffFor(double mg) async {
    final bed = await bedtime();
    return ana.latestSafeTime(mg: mg, bedtime: bed.at);
  }
}
