// ramadan.dart — fasting days, and why the app must know about them.
//
// THE PROBLEM THIS SOLVES IS NOT A MISSING SCREEN. Fasting changes almost
// every signal this app measures. Sleep fragments around suhoor. Resting heart
// rate and HRV shift with dehydration and a compressed eating window. Training
// moves to pre-iftar or post-taraweeh.
//
// Every baseline in the app is a rolling personal reference, so a month of
// fasted days does two damaging things at once: the illness/anomaly watch sees
// a sustained physiological shift and flags it as a warning, and the baselines
// themselves drift toward fasted values — which then makes the first week
// AFTER Ramadan look abnormal too. An app that spends Ramadan telling you that
// you might be ill is worse than one that ignores fasting entirely.
//
// So the point of this file is to LABEL the days. Once a day is known to be
// fasted, everything downstream can treat it as its own population rather than
// as an anomaly.
//
// WHY THE DATES ARE NOT COMPUTED OUTRIGHT. Ramadan begins on local moon
// sighting, which genuinely differs between countries and even between
// communities in the same city. Any calendar that claims an exact start date is
// wrong for somebody. The tabular Islamic calendar below is used only to
// SUGGEST the window; the user confirms, and the confirmation is what counts.

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/db.dart';
import 'prayer_times.dart';

class RamadanService {
  RamadanService._();

  /// metric_series key marking a day as fasted. 1.0 = fasting.
  ///
  /// Stored as a metric rather than its own table so every existing consumer —
  /// the coach's v_metric view, the correlation engine, any future analysis —
  /// can see it without new plumbing.
  static const String kFastingKey = 'fasting';

  static const _kEnabled = 'ramadan_enabled';
  static const _kStart = 'ramadan_start'; // 'YYYY-MM-DD'
  static const _kEnd = 'ramadan_end';

  static String dayLabel(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  // ── settings ───────────────────────────────────────────────────────────────

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? false;

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  /// The confirmed window, or null when not set.
  static Future<({DateTime start, DateTime end})?> window() async {
    final p = await SharedPreferences.getInstance();
    final s = p.getString(_kStart);
    final e = p.getString(_kEnd);
    if (s == null || e == null) return null;
    final ds = DateTime.tryParse(s);
    final de = DateTime.tryParse(e);
    if (ds == null || de == null) return null;
    return (start: ds, end: de);
  }

  static Future<void> setWindow(DateTime start, DateTime end) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kStart, dayLabel(start));
    await p.setString(_kEnd, dayLabel(end));
    await p.setBool(_kEnabled, true);
    // Backfill the flag across the window so analyses that read history see it
    // immediately rather than only from today forward.
    await _markWindow(start, end);
  }

  static Future<void> clearWindow() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_kStart);
    await p.remove(_kEnd);
    await p.setBool(_kEnabled, false);
  }

  // ── fasting days ───────────────────────────────────────────────────────────

  /// Whether [day] is marked fasted.
  static Future<bool> isFasting(DateTime day) async {
    try {
      final db = await LocalDb.instance;
      final rows = await db.query(
        'metric_series',
        columns: ['value'],
        where: 'date = ? AND key = ?',
        whereArgs: [dayLabel(day), kFastingKey],
        limit: 1,
      );
      if (rows.isEmpty) return false;
      return ((rows.first['value'] as num?) ?? 0) > 0;
    } catch (_) {
      return false;
    }
  }

  /// Mark or unmark a single day.
  ///
  /// Kept per-day rather than window-only because real fasting is per-day: a
  /// missed day for travel or illness should not be averaged in with the rest.
  static Future<void> setFasting(DateTime day, bool fasting) async {
    try {
      final db = await LocalDb.instance;
      await db.insert(
        'metric_series',
        {'date': dayLabel(day), 'key': kFastingKey, 'value': fasting ? 1.0 : 0.0},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    } catch (_) {}
  }

  static Future<void> _markWindow(DateTime start, DateTime end) async {
    var d = DateTime(start.year, start.month, start.day);
    final last = DateTime(end.year, end.month, end.day);
    // Bounded so a mis-entered window cannot write thousands of rows.
    var guard = 0;
    while (!d.isAfter(last) && guard++ < 40) {
      await setFasting(d, true);
      d = d.add(const Duration(days: 1));
    }
  }

  /// Every fasted day in the store, for analyses that need to exclude them.
  static Future<Set<String>> fastingDays() async {
    try {
      final db = await LocalDb.instance;
      final rows = await db.query(
        'metric_series',
        columns: ['date'],
        where: 'key = ? AND value > 0',
        whereArgs: [kFastingKey],
      );
      return {
        for (final r in rows)
          if (r['date'] is String) r['date'] as String,
      };
    } catch (_) {
      return const {};
    }
  }

  // ── today's timings ────────────────────────────────────────────────────────

  /// Suhoor ends at Fajr and iftar is at Maghrib — the same two prayer times
  /// already computed, so there is exactly one source for both and they cannot
  /// drift apart.
  static Future<({DateTime suhoorEnds, DateTime iftar})?> timings(
    DateTime day,
  ) async {
    final slots = await PrayerTimesService.slotsFor(day);
    if (slots == null) return null;
    DateTime? fajr, maghrib;
    for (final s in slots) {
      if (s.isMarker) continue;
      if (s.prayer == Prayer5.fajr) fajr = s.at;
      if (s.prayer == Prayer5.maghrib) maghrib = s.at;
    }
    if (fajr == null || maghrib == null) return null;
    return (suhoorEnds: fajr, iftar: maghrib);
  }

  /// The fasting window's length today, which is what actually varies and what
  /// determines how hard the day is.
  static Future<Duration?> fastLength(DateTime day) async {
    final t = await timings(day);
    if (t == null) return null;
    return t.iftar.difference(t.suhoorEnds);
  }

  // ── the estimate ───────────────────────────────────────────────────────────

  /// Approximate Gregorian date of 1 Ramadan for a given Hijri year, by the
  /// tabular Islamic calendar.
  ///
  /// APPROXIMATE BY CONSTRUCTION. The tabular calendar is arithmetic; the real
  /// month begins on local moon sighting and commonly differs by a day either
  /// way. This exists to PREFILL the picker, never to assert a date.
  static DateTime estimatedRamadanStart(int hijriYear) {
    // Islamic (tabular, civil epoch) → Julian Day Number for 1 Ramadan (month 9).
    final jdn = ((11 * hijriYear + 3) ~/ 30) +
        354 * hijriYear +
        30 * 9 -
        ((9 - 1) ~/ 2) +
        1 +
        1948440 -
        386;
    // JDN → Gregorian.
    var l = jdn + 68569;
    final n = (4 * l) ~/ 146097;
    l = l - (146097 * n + 3) ~/ 4;
    final i = (4000 * (l + 1)) ~/ 1461001;
    l = l - (1461 * i) ~/ 4 + 31;
    final j = (80 * l) ~/ 2447;
    final day = l - (2447 * j) ~/ 80;
    l = j ~/ 11;
    final month = j + 2 - 12 * l;
    final year = 100 * (n - 49) + i + l;
    return DateTime(year, month, day);
  }

  /// The Hijri year that Ramadan falls in for a given Gregorian year.
  static int hijriYearFor(DateTime d) =>
      (((d.year - 622) * 33) ~/ 32) + 1;

  /// A suggested window for the picker: estimated start, 30 days long.
  static ({DateTime start, DateTime end}) suggestedWindow([DateTime? now]) {
    final n = now ?? DateTime.now();
    var start = estimatedRamadanStart(hijriYearFor(n));
    // If this year's estimate has already passed, suggest next year's.
    if (start.isBefore(n.subtract(const Duration(days: 35)))) {
      start = estimatedRamadanStart(hijriYearFor(n) + 1);
    }
    return (start: start, end: start.add(const Duration(days: 29)));
  }
}
