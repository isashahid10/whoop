// Regression tests for the once-per-day notification guard.
//
// AppState's "your recovery is ready" (_kLastRecoveryNotifDay) and "step goal
// reached" (_kLastStepGoalDay) used to write their persisted day-guard BEFORE
// calling NotificationCenter.emit. emit DROPS the event outright when
// NotificationPrefs.shouldFireOs says no — and the DEFAULT quiet window is
// 22:00–07:00, which a band syncing at 06:40 (the heavy finalize that computes
// the new day's recovery) sits squarely inside. So the guard was burned on a
// notification that never reached the user, and it then blocked every retry for
// the rest of the day: "Your recovery is ready" simply never fired.
//
// NotificationCenter.emitOncePerDay is the fixed sequencing (claim the guard
// only on a real present) and emit now REPORTS whether it presented.
//
// NOTE — no sqlite factory is registered here, so FiredKeyStore runs in its
// degraded shared_preferences mode. That's fine: this suite is about the DAY
// guard, not the cross-isolate claim (see notification_claim_atomic_test.dart).

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';
import 'package:openstrap_edge/notify/notification_service.dart';

const String kGuardKey = 'last_recovery_notif_day';
final String kDay = todayLabel();
final String kTomorrow = dayLabelOf(DateTime.now().add(const Duration(days: 1)));

NotificationEvent _recoveryReady({String? day}) {
  final d = day ?? kDay;
  return NotificationEvent(
    dedupeKey: '$d:recovery_ready',
    category: NotifCategory.recovery,
    priority: NotifPriority.normal,
    title: 'Your recovery is ready',
    body: 'Recovery 71. Tap to see today.',
    date: d,
    route: '/today',
  );
}

class _Sink {
  final List<String> shown = [];
  bool grant;
  _Sink({this.grant = true});
  Future<bool> call(NotificationEvent e,
      {bool allowPermissionPrompt = true}) async {
    if (!grant) return false;
    shown.add(e.dedupeKey);
    return true;
  }
}

/// Prefs values that make the quiet window cover the entire 24 h, so a
/// non-critical event is deterministically suppressed regardless of the
/// wall-clock the test happens to run at.
Map<String, Object> _quietAllDay() => {
      'notif_quiet_enabled': true,
      'notif_quiet_start': 0,
      'notif_quiet_end': 1440,
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final original = NotificationCenter.instance.presentSink;
  tearDown(() => NotificationCenter.instance.presentSink = original);

  setUp(() {
    NotificationIds.instance.resetForTest();
  });

  group('emit reports whether the event actually reached the OS', () {
    test('returns false when quiet hours suppress it', () async {
      SharedPreferences.setMockInitialValues(_quietAllDay());
      final sink = _Sink();
      NotificationCenter.instance.presentSink = sink.call;
      expect(await NotificationCenter.instance.emit(_recoveryReady()), isFalse);
      expect(sink.shown, isEmpty);
    });

    test('returns false when the OS present is refused (permission denied)',
        () async {
      SharedPreferences.setMockInitialValues({});
      final sink = _Sink(grant: false);
      NotificationCenter.instance.presentSink = sink.call;
      expect(await NotificationCenter.instance.emit(_recoveryReady()), isFalse);
    });

    test('returns true on a real present', () async {
      SharedPreferences.setMockInitialValues({});
      final sink = _Sink();
      NotificationCenter.instance.presentSink = sink.call;
      expect(await NotificationCenter.instance.emit(_recoveryReady()), isTrue);
      expect(sink.shown, ['$kDay:recovery_ready']);
    });
  });

  group('emitOncePerDay consumes the guard only on a real present', () {
    test('a quiet-hours suppression does NOT burn the day guard, and the '
        'retry once quiet hours end still fires', () async {
      SharedPreferences.setMockInitialValues(_quietAllDay());
      final sink = _Sink();
      NotificationCenter.instance.presentSink = sink.call;

      // 06:40 sync inside the quiet window → suppressed.
      final firstTry = await NotificationCenter.instance.emitOncePerDay(
        prefsKey: kGuardKey,
        dayId: kDay,
        e: _recoveryReady(),
      );
      expect(firstTry, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kGuardKey), isNull,
          reason: 'the guard must not be consumed by an event that never '
              'reached the user');

      // Quiet hours over — the next derive pass must still be able to fire.
      await prefs.setBool('notif_quiet_enabled', false);
      final retry = await NotificationCenter.instance.emitOncePerDay(
        prefsKey: kGuardKey,
        dayId: kDay,
        e: _recoveryReady(),
      );
      expect(retry, isTrue);
      expect(sink.shown, ['$kDay:recovery_ready']);
      expect(prefs.getString(kGuardKey), kDay);
    });

    test('a permission-denied no-op does NOT burn the day guard either',
        () async {
      SharedPreferences.setMockInitialValues({});
      final sink = _Sink(grant: false);
      NotificationCenter.instance.presentSink = sink.call;

      expect(
        await NotificationCenter.instance.emitOncePerDay(
            prefsKey: kGuardKey, dayId: kDay, e: _recoveryReady()),
        isFalse,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kGuardKey), isNull);

      sink.grant = true;
      expect(
        await NotificationCenter.instance.emitOncePerDay(
            prefsKey: kGuardKey, dayId: kDay, e: _recoveryReady()),
        isTrue,
      );
      expect(prefs.getString(kGuardKey), kDay);
    });

    test('a real present consumes the guard, and the same day never re-fires',
        () async {
      SharedPreferences.setMockInitialValues({});
      final sink = _Sink();
      NotificationCenter.instance.presentSink = sink.call;

      expect(
        await NotificationCenter.instance.emitOncePerDay(
            prefsKey: kGuardKey, dayId: kDay, e: _recoveryReady()),
        isTrue,
      );
      expect(
        await NotificationCenter.instance.emitOncePerDay(
            prefsKey: kGuardKey, dayId: kDay, e: _recoveryReady()),
        isFalse,
      );
      expect(sink.shown.length, 1);
    });

    test('a NEW day is a fresh guard', () async {
      SharedPreferences.setMockInitialValues({kGuardKey: kDay});
      final sink = _Sink();
      NotificationCenter.instance.presentSink = sink.call;

      expect(
        await NotificationCenter.instance.emitOncePerDay(
            prefsKey: kGuardKey, dayId: kDay, e: _recoveryReady()),
        isFalse,
      );
      expect(
        await NotificationCenter.instance.emitOncePerDay(
            prefsKey: kGuardKey,
            dayId: kTomorrow,
            e: _recoveryReady(day: kTomorrow)),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(kGuardKey), kTomorrow);
    });
  });

  // Sanity: the service singleton's permission cache must not leak between the
  // suites in this file (emitOncePerDay never touches it, but presentSink does
  // in production).
  tearDownAll(() => NotificationService.instance.invalidatePermissionCache());
}
