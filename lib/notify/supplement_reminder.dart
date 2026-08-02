// supplement_reminder.dart — the evening supplement nudge, with a real snooze.
//
// A daily reminder you cannot postpone is a reminder you learn to swipe away,
// and a habit reminder that gets swiped away every night is worse than none:
// it trains you to ignore the app's notifications generally. So this ships with
// snooze as a first-class action rather than an afterthought.
//
// SNOOZE IS A ONE-SHOT, NOT A RESCHEDULE of the daily. The daily repeat has to
// keep its slot for tomorrow — moving it would silently drift the reminder
// later every time it was postponed, until it landed at bedtime.
//
// TAKEN IS PER-DAY. Marking it done stops tonight's follow-ups and nothing
// else; tomorrow's reminder is untouched.

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'notification_event.dart';
import 'notification_service.dart';

class SupplementReminder {
  SupplementReminder._();

  /// The daily reminder, plus a band for snoozed one-shots. Sits above the
  /// prayer band (2400 + 5x10) and well below the allocated category bands.
  static const int idDaily = 2500;
  static const int idSnoozeBase = 2501;
  static const int maxSnoozes = 4;

  static const _kEnabled = 'supp_enabled';
  static const _kHour = 'supp_hour';
  static const _kMinute = 'supp_minute';

  /// Default 19:30 — inside the window the user asked for, and early enough
  /// that a snooze or two still lands well before bed.
  static const int defaultHour = 19;
  static const int defaultMinute = 30;

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? true;

  static Future<({int hour, int minute})> time() async {
    final p = await SharedPreferences.getInstance();
    return (
      hour: p.getInt(_kHour) ?? defaultHour,
      minute: p.getInt(_kMinute) ?? defaultMinute,
    );
  }

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
    await reschedule();
  }

  static Future<void> setTime(int hour, int minute) async {
    final p = await SharedPreferences.getInstance();
    await p.setInt(_kHour, hour.clamp(0, 23));
    await p.setInt(_kMinute, minute.clamp(0, 59));
    await reschedule();
  }

  // ── taken ──────────────────────────────────────────────────────────────────

  static String _takenKey(DateTime d) =>
      'supp_taken:${d.year}-${d.month}-${d.day}';

  static Future<bool> takenToday() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_takenKey(DateTime.now())) ?? false;
  }

  /// Mark taken and silence tonight's snoozes. Tomorrow's daily is left alone.
  static Future<void> markTaken() async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_takenKey(DateTime.now()), true);
    await _cancelSnoozes();
  }

  static Future<void> undoTaken() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_takenKey(DateTime.now()));
  }

  // ── snooze ─────────────────────────────────────────────────────────────────

  static Future<void> _cancelSnoozes() async {
    final svc = NotificationService.instance;
    for (var i = 0; i < maxSnoozes; i++) {
      await svc.cancel(idSnoozeBase + i);
    }
  }

  /// Postpone tonight's reminder by [by].
  ///
  /// Each snooze takes the next slot in the band so an earlier one still
  /// pending is replaced rather than stacking into two notifications.
  static Future<void> snooze({Duration by = const Duration(minutes: 30)}) async {
    if (await takenToday()) return;
    await _cancelSnoozes();
    await NotificationService.instance.scheduleOnce(
      id: idSnoozeBase,
      category: NotifCategory.reminders,
      title: 'Supplements',
      body: 'Still not marked - take them when you get a moment.',
      at: DateTime.now().add(by),
      route: '/today',
    );
    debugPrint('[supplements] snoozed ${by.inMinutes}m');
  }

  // ── scheduling ─────────────────────────────────────────────────────────────

  static Future<void> reschedule() async {
    final svc = NotificationService.instance;
    await svc.cancel(idDaily);
    await _cancelSnoozes();
    if (!await enabled()) return;

    final t = await time();
    await svc.scheduleDaily(
      id: idDaily,
      category: NotifCategory.reminders,
      title: 'Supplements',
      body: 'Time to take your supplements.',
      hour: t.hour,
      minute: t.minute,
      route: '/today',
      // Already taken today → start the repeat tomorrow, so enabling the
      // reminder in the evening does not immediately fire for a done task.
      skipToday: await takenToday(),
    );
  }
}
