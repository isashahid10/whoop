// notification_center.dart — the single emitter.
//
// Every insight, alert and nudge goes through emit(). OS-level notifications
// are the ONLY surface now — the in-app notifications feed/screen was
// removed (it duplicated the OS notification with no independent value).
// Whether an event fires an OS notification is decided by NotificationPrefs:
//   • category must be enabled, AND
//   • either we're outside quiet hours, or the event is critical and the user
//     allowed critical-overrides-quiet.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ai/ai_prefs.dart';
import '../ai/reminder_plan.dart';
import 'fired_keys.dart';
import 'notification_event.dart';
import 'notification_prefs.dart';
import 'notification_service.dart';

class NotificationCenter {
  NotificationCenter._();
  static final NotificationCenter instance = NotificationCenter._();

  /// The persistent "already fired this dedupeKey" guard. See [FiredKeyStore].
  final FiredKeyStore _fired = const FiredKeyStore();

  /// Tail of a chained-Future lock that serialises the claim-present-release
  /// critical section in [emit]. It keeps two overlapping emits in THIS isolate
  /// from interleaving their presents — more likely now the UI-thread stress
  /// alert can race the background derive loop.
  ///
  /// It is not what enforces fire-once. This lock can only order emits WITHIN
  /// this isolate; derivation also runs in the WorkManager isolate, which it
  /// cannot see. Fire-once across both is enforced by the atomic
  /// [FiredKeyStore.claim] below — one SQLite INSERT OR IGNORE, one winner.
  Future<void> _lock = Future<void>.value();

  /// Run [action] after any in-flight critical section completes, exclusively.
  Future<void> _synchronized(Future<void> Function() action) async {
    final prev = _lock;
    final done = Completer<void>();
    _lock = done.future; // installed synchronously — orders concurrent callers
    await prev;
    try {
      await action();
    } finally {
      done.complete();
    }
  }

  /// The OS presentation sink. Returns true when the event was actually shown
  /// (permission granted, no error). Overridable in tests to assert call counts
  /// without a device; defaults to the real service.
  @visibleForTesting
  Future<bool> Function(NotificationEvent e, {bool allowPermissionPrompt})
      presentSink = NotificationService.instance.presentEvent;

  /// Present to the OS (if allowed). Never throws.
  ///
  /// [allowPermissionPrompt]: Apple's notification docs document that
  /// authorization must be requested IN CONTEXT, from an active foreground
  /// scene — never from a background execution context (a headless
  /// BGTaskScheduler run or Dart background isolate has none to present
  /// from). Callers that know they're running headless (see
  /// background_sync.dart's checkSyncStaleness) MUST pass `false`, so a
  /// not-yet-decided permission is checked, not requested, and never gets
  /// permanently mis-cached as "denied" by a background attempt.
  ///
  /// Returns TRUE only when the event actually reached the OS. Callers that
  /// keep their own "already fired today" guard (see [emitOncePerDay]) MUST key
  /// it off this, never off the mere fact that emit was called: the event is
  /// dropped outright when [NotificationPrefs.shouldFireOs] says no (quiet
  /// hours, category muted) or when the OS present fails.
  Future<bool> emit(
    NotificationEvent e, {
    bool allowPermissionPrompt = true,
  }) async {
    var presented = false;
    try {
      final prefs = await NotificationPrefs.load();
      final now = DateTime.now();
      final minuteOfDay = now.hour * 60 + now.minute;
      if (!prefs.shouldFireOs(e, minuteOfDay)) return false;
      // Enforce the dedupeKey's "fires at most once" contract (issue #136).
      // The OS id only REPLACES a prior post of the same key — it still
      // re-alerts — and derivation re-runs on every BLE sync, so an insight
      // whose condition holds all day would otherwise buzz over and over. The
      // guard resets itself per new day via the date-prefixed keys.
      //
      // CLAIM, don't check. A check-then-record pair is not atomic: the two
      // derivation isolates can both read "not fired" before either records and
      // both alert. [FiredKeyStore.claim] decides ownership in ONE atomic
      // operation, so exactly one caller — in either isolate — ever proceeds.
      //
      // A claim we don't spend is given straight back: a permission-denied
      // no-op or a throwing present must NOT consume the key, or that insight
      // stays silent for the rest of the day. Release on every non-present path
      // (hence the finally), which restores the pre-existing
      // "record only after a real present" semantics.
      await _synchronized(() async {
        if (!await _fired.claim(e.dedupeKey)) return;
        var shown = false;
        try {
          shown = await presentSink(
            e,
            allowPermissionPrompt: allowPermissionPrompt,
          );
        } finally {
          if (!shown) await _fired.release(e.dedupeKey);
        }
        presented = shown;
      });
    } catch (_) {/* OS present best-effort */}
    return presented;
  }

  /// Fire [e] at most once per [dayId], with the persisted day-guard at
  /// [prefsKey] consumed ONLY when the notification was actually presented.
  /// Returns true iff it fired.
  ///
  /// The callers of this (recovery-ready, step-goal) used to write the guard
  /// FIRST and then emit. [emit] drops the event outright when
  /// [NotificationPrefs.shouldFireOs] is false, so a band that syncs at 06:40 —
  /// inside the DEFAULT 22:00–07:00 quiet window — computed the new day's
  /// recovery, burned the guard, got suppressed, and then had every retry that
  /// day blocked by the guard it never earned: "Your recovery is ready" simply
  /// never fired. Claiming the guard only on a real present makes the retry
  /// (the next derive pass, after 07:00) work.
  Future<bool> emitOncePerDay({
    required String prefsKey,
    required String dayId,
    required NotificationEvent e,
    bool allowPermissionPrompt = true,
  }) async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      prefs = null; // no store — [emit]'s own FiredKeyStore still dedupes
    }
    if (prefs != null && prefs.getString(prefsKey) == dayId) return false;
    final shown = await emit(e, allowPermissionPrompt: allowPermissionPrompt);
    if (shown && prefs != null) {
      try {
        await prefs.setString(prefsKey, dayId);
      } catch (_) {/* guard is an optimisation; FiredKeyStore is the truth */}
    }
    return shown;
  }

  // Default schedule for standing reminders (user-overridable via prefs UI).
  static const int windDownHour = 21; // 21:00
  static const int windDownMinute = 0;
  static const int recapWeekday = DateTime.sunday;
  static const int recapHour = 18; // Sunday 18:00
  static const int recapMinute = 0;

  /// (Re)register the recurring wall-clock nudges as real OS-scheduled
  /// notifications, so they fire even when the app is closed. Idempotent: cancels
  /// then re-schedules per the current prefs. Call after pairing and whenever the
  /// user changes notification prefs.
  Future<void> scheduleStandingReminders(NotificationPrefs prefs,
      {double? bedtimeMinOfDay}) async {
    final svc = NotificationService.instance;
    await svc.cancel(NotificationService.idWindDown);
    await svc.cancel(NotificationService.idWeeklyRecap);
    // Always clear the hydration band first so a disabled/retuned reminder never
    // leaves stale OS-scheduled slots behind.
    for (var i = 0; i < NotificationService.maxWaterSlots; i++) {
      await svc.cancel(NotificationService.idWaterBase + i);
    }
    if (!prefs.remindersEnabled) return;

    // "Time to sleep" — at the Sleep Coach's recommended bedtime when known
    // (tracks the user's schedule + sleep need), else the fixed default.
    var bedHour = windDownHour, bedMin = windDownMinute;
    if (bedtimeMinOfDay != null && bedtimeMinOfDay >= 0) {
      final m = bedtimeMinOfDay.round() % 1440;
      bedHour = m ~/ 60;
      bedMin = m % 60;
    }
    await svc.scheduleDaily(
      id: NotificationService.idWindDown,
      category: NotifCategory.reminders,
      title: 'Time to sleep',
      body: bedtimeMinOfDay != null
          ? 'To meet your sleep need, aim to be in bed around now — a consistent '
              'bedtime steadies your recovery.'
          : 'A consistent bedtime steadies your recovery — start easing off '
              'screens and lights now.',
      hour: bedHour,
      minute: bedMin,
      route: '/sleep',
    );
    // NOTE: the "log your day" journal nudge moved to scheduleAiReminders —
    // it is now the pre-sleep journaling prompt (bedtime-aware, deep-links
    // into the compose screen, honours the once-per-night done flag).
    await svc.scheduleWeekly(
      id: NotificationService.idWeeklyRecap,
      category: NotifCategory.reminders,
      title: 'Your week in review',
      body: 'A new weekly recap is ready — see how your sleep, strain and '
          'recovery trended.',
      weekday: recapWeekday,
      hour: recapHour,
      minute: recapMinute,
      route: '/recap',
    );

    // Hydration nudges — one daily-repeating slot every `waterIntervalMin`
    // across the waking window.
    await _scheduleWaterReminders(prefs, svc);
  }

  // Default waking window when quiet hours are off (so we never ping at 3am).
  static const int _waterDayStartMin = 8 * 60; // 08:00
  static const int _waterDayEndMin = 22 * 60; // 22:00

  /// The wall-clock fire times (minutes-from-midnight, ascending) for the
  /// hydration reminder — one per slot across the waking window, spaced by the
  /// (clamped) interval, capped at [NotificationService.maxWaterSlots]. Returns
  /// empty when hydration is off. PURE — single source of truth shared by the OS
  /// scheduler here and the strap-buzz timer in AppState.
  static List<int> waterSlotMinutes(NotificationPrefs prefs) {
    if (!prefs.remindersEnabled || !prefs.waterEnabled) return const [];

    final interval = prefs.waterIntervalMin.clamp(
        NotificationPrefs.waterIntervalMinAllowed,
        NotificationPrefs.waterIntervalMaxAllowed);

    // Waking window = outside quiet hours when enabled, else the daytime default.
    // quietEnd is wake-up; quietStart is bedtime. Fall back to 08:00–22:00 if the
    // window is degenerate (start <= end, or quiet hours disabled).
    var startMin = _waterDayStartMin, endMin = _waterDayEndMin;
    if (prefs.quietEnabled && prefs.quietStartMin > prefs.quietEndMin) {
      startMin = prefs.quietEndMin; // wake
      endMin = prefs.quietStartMin; // bed
    }
    if (endMin - startMin < interval) {
      // Window too short for even one spaced slot — fire once mid-window.
      startMin = (startMin + endMin) ~/ 2;
      endMin = startMin + 1;
    }

    final slots = <int>[];
    for (var t = startMin;
        t < endMin && slots.length < NotificationService.maxWaterSlots;
        t += interval) {
      slots.add(t);
    }
    return slots;
  }

  /// (Re)register the AI-feature nudges (morning briefing, evening recap,
  /// pre-sleep journal prompt) per the pure [aiReminderPlan]. Idempotent:
  /// cancels the three slots, then schedules whatever the plan says. Briefing
  /// slots only exist while a BYOK key is configured ([aiConfigured]); the
  /// journal prompt fires ~30 min before the recommended bedtime (or the
  /// user's explicit time) and skips tonight when already logged.
  Future<void> scheduleAiReminders(
    NotificationPrefs prefs,
    AiPrefs ai, {
    required bool aiConfigured,
    double? bedtimeMinOfDay,
    required bool journalDoneToday,
  }) async {
    final svc = NotificationService.instance;
    await svc.cancel(NotificationService.idMorningBrief);
    await svc.cancel(NotificationService.idEveningBrief);
    await svc.cancel(NotificationService.idJournalLog);
    final plan = aiReminderPlan(
      ai,
      remindersEnabled: prefs.remindersEnabled,
      aiConfigured: aiConfigured,
      bedtimeMinOfDay: bedtimeMinOfDay,
      journalDoneToday: journalDoneToday,
    );
    for (final s in plan) {
      await svc.scheduleDaily(
        id: s.id,
        category: NotifCategory.reminders,
        title: s.title,
        body: s.body,
        hour: s.hour,
        minute: s.minute,
        route: s.route,
        skipToday: s.skipToday,
      );
    }
  }

  /// Schedule the hydration reminders as a band of daily-repeating OS slots, one
  /// per [waterSlotMinutes] entry.
  Future<void> _scheduleWaterReminders(
      NotificationPrefs prefs, NotificationService svc) async {
    final slots = waterSlotMinutes(prefs);
    for (var i = 0; i < slots.length; i++) {
      final t = slots[i];
      await svc.scheduleDaily(
        id: NotificationService.idWaterBase + i,
        category: NotifCategory.reminders,
        title: 'Time to hydrate',
        body: 'A quick glass of water keeps your recovery and focus steady.',
        hour: (t ~/ 60) % 24,
        minute: t % 60,
        route: '/today',
      );
    }
  }
}
