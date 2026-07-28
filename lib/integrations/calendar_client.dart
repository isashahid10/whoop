// calendar_client.dart — schedule density as a stress/sleep covariate.
//
// WHY: a nine-meeting day and a clear day are different physiological loads,
// and the band cannot tell them apart — it just sees elevated resting HR and
// depressed HRV with no explanation. Density lets the coach say "your HRV dip
// tracks your heaviest meeting days" instead of guessing.
//
// PRIVACY: read-only, and event TITLES ARE NEVER STORED. Only counts and
// durations reach the database, so the coach can correlate schedule load
// without any of it becoming a permanent, LLM-readable record of who the user
// met and what about. That is a deliberate limit, not an oversight — the
// correlation works fine on counts alone.
//
// Stored as `cal_`-prefixed keys in metric_series, matching the `hk_`/`wx_`
// convention so imports can never collide with a derived metric.

import 'package:device_calendar/device_calendar.dart';
import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart' show ConflictAlgorithm;

import '../data/day_label.dart';
import '../data/db.dart';

class CalendarClient {
  final DeviceCalendarPlugin _plugin = DeviceCalendarPlugin();

  /// Ask for calendar access. False when declined; never throws.
  Future<bool> requestPermission() async {
    try {
      final has = await _plugin.hasPermissions();
      if (has.isSuccess && has.data == true) return true;
      final req = await _plugin.requestPermissions();
      return req.isSuccess && req.data == true;
    } catch (e) {
      debugPrint('[calendar] permission failed: $e');
      return false;
    }
  }

  Future<bool> get hasPermission async {
    try {
      final has = await _plugin.hasPermissions();
      return has.isSuccess && has.data == true;
    } catch (_) {
      return false;
    }
  }

  /// Summarise the last [days] days of schedule into per-day scalars.
  /// Returns the number of days written; 0 on any failure.
  Future<int> syncRecent({int days = 30}) async {
    try {
      if (!await hasPermission) {
        debugPrint('[calendar] no permission — skipping');
        return 0;
      }

      final cals = await _plugin.retrieveCalendars();
      if (!cals.isSuccess || cals.data == null || cals.data!.isEmpty) return 0;

      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day)
          .subtract(Duration(days: days));

      // day -> (count, busyMinutes, earliestStartMin, latestEndMin)
      final counts = <String, int>{};
      final busyMin = <String, double>{};
      final firstMin = <String, double>{};
      final lastMin = <String, double>{};

      for (final cal in cals.data!) {
        final id = cal.id;
        if (id == null) continue;
        // Skip birthdays/holidays: they are all-day noise that would inflate
        // every day's count without representing any real time commitment.
        final name = (cal.name ?? '').toLowerCase();
        if (name.contains('birthday') || name.contains('holiday')) continue;

        final res = await _plugin.retrieveEvents(
          id,
          RetrieveEventsParams(startDate: start, endDate: now),
        );
        if (!res.isSuccess || res.data == null) continue;

        for (final e in res.data!) {
          final s = e.start;
          final en = e.end;
          if (s == null) continue;
          // All-day events represent no scheduled BLOCK of time — count them,
          // but never let them contribute 24h of "busy".
          final allDay = e.allDay ?? false;
          final day = dayLabelOf(s);

          counts[day] = (counts[day] ?? 0) + 1;
          if (!allDay && en != null) {
            final mins = en.difference(s).inMinutes.toDouble();
            // Guard against malformed multi-day entries skewing the day.
            if (mins > 0 && mins <= 24 * 60) {
              busyMin[day] = (busyMin[day] ?? 0) + mins;
            }
            final sMin = (s.hour * 60 + s.minute).toDouble();
            final eMin = (en.hour * 60 + en.minute).toDouble();
            firstMin[day] =
                firstMin[day] == null ? sMin : (sMin < firstMin[day]! ? sMin : firstMin[day]!);
            lastMin[day] =
                lastMin[day] == null ? eMin : (eMin > lastMin[day]! ? eMin : lastMin[day]!);
          }
        }
      }

      if (counts.isEmpty) return 0;

      final db = await LocalDb.instance;
      await db.transaction((txn) async {
        Future<void> put(String day, String key, double? v) async {
          if (v == null) return;
          await txn.insert(
            'metric_series',
            {'date': day, 'key': key, 'value': v},
            conflictAlgorithm: ConflictAlgorithm.replace,
          );
        }

        for (final day in counts.keys) {
          await put(day, 'cal_events', counts[day]!.toDouble());
          await put(day, 'cal_busy_min', busyMin[day]);
          // First commitment of the day: a proxy for how early the user had to
          // be up, which bears directly on sleep debt.
          await put(day, 'cal_first_start_min', firstMin[day]);
          await put(day, 'cal_last_end_min', lastMin[day]);
        }
      });

      debugPrint('[calendar] wrote ${counts.length} days');
      return counts.length;
    } catch (e) {
      debugPrint('[calendar] sync failed: $e');
      return 0;
    }
  }
}
