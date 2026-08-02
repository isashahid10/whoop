// Weight re-check nudge: rate-limiting and ESCALATION.
//
// The bug this guards against is subtle. FiredKeyStore is a fire-ONCE guard, so
// the obvious implementation (a static dedupe key) asks once, gets dismissed,
// and then never asks again - leaving the stale weight in place forever, which
// is the exact failure the nudge exists to prevent. These tests pin the
// re-arming behaviour so a later "simplification" back to a static key fails
// loudly here instead of silently in production.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:openstrap_edge/notify/notification_center.dart';
import 'package:openstrap_edge/notify/profile_nudges.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> presented;

  /// Preference seed that makes these tests independent of the wall clock.
  ///
  /// NotificationCenter suppresses non-critical events during quiet hours,
  /// which default to 22:00-07:00 LOCAL. Without disabling that, every
  /// expectation below depends on what time of day the suite happens to run:
  /// green in the afternoon, red overnight. CI runs around 02:00 UTC, so this
  /// file failed there while passing on a developer machine in AEST.
  ///
  /// Quiet hours have their own tests. These are about the nudge's rate
  /// limiting and escalation, so the gate is taken out of the picture.
  Map<String, Object> prefs([Map<String, Object> extra = const {}]) => {
        'notif_quiet_enabled': false,
        ...extra,
      };

  setUp(() {
    presented = [];
    SharedPreferences.setMockInitialValues(prefs());
    // Capture instead of hitting the OS.
    NotificationCenter.instance.presentSink =
        (e, {bool allowPermissionPrompt = true}) async {
      presented.add(e.dedupeKey);
      return true;
    };
  });

  test('first run seeds the clock instead of nagging immediately', () async {
    final shown = await ProfileNudges.maybePromptWeight();
    expect(shown, isFalse, reason: 'a day-one nag reads as a broken app');
    expect(presented, isEmpty);

    // The clock must now be set, so the 2-month countdown actually starts.
    final p = await SharedPreferences.getInstance();
    expect(p.getInt('weight_confirmed_at'), isNotNull);
  });

  test('stays quiet while the weight is fresh', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    SharedPreferences.setMockInitialValues(prefs({
      'weight_confirmed_at': now - const Duration(days: 30).inSeconds,
    }));
    expect(await ProfileNudges.maybePromptWeight(), isFalse);
    expect(presented, isEmpty);
  });

  test('prompts once the weight is over two months old', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    SharedPreferences.setMockInitialValues(prefs({
      'weight_confirmed_at': now - const Duration(days: 70).inSeconds,
    }));
    expect(await ProfileNudges.maybePromptWeight(), isTrue);
    expect(presented.length, 1);
    expect(presented.single, contains('weight_recheck'));
  });

  test('does not ask twice in the same day', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    SharedPreferences.setMockInitialValues(prefs({
      'weight_confirmed_at': now - const Duration(days: 70).inSeconds,
    }));
    expect(await ProfileNudges.maybePromptWeight(), isTrue);
    expect(await ProfileNudges.maybePromptWeight(), isFalse);
    expect(presented.length, 1);
  });

  test('confirming resets the clock AND the escalation counter', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    SharedPreferences.setMockInitialValues(prefs({
      'weight_confirmed_at': now - const Duration(days: 70).inSeconds,
      'weight_prompt_count': 3,
    }));
    expect(await ProfileNudges.maybePromptWeight(), isTrue);

    await ProfileNudges.markWeightConfirmed();
    final p = await SharedPreferences.getInstance();
    expect(p.getInt('weight_prompt_count'), 0);

    // Freshly confirmed - must go quiet again.
    presented.clear();
    expect(await ProfileNudges.maybePromptWeight(), isFalse);
    expect(presented, isEmpty);
  });

  test(
    're-arms after an ignored prompt - the whole point of the day-keyed '
    'dedupe key, since a static key would be consumed forever',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      // Asked once, 5 days ago, never answered. Back-off for count=1 is 3 days,
      // so it is due again.
      final fiveDaysAgo = DateTime.now().subtract(const Duration(days: 5));
      final stamp = '${fiveDaysAgo.year.toString().padLeft(4, '0')}-'
          '${fiveDaysAgo.month.toString().padLeft(2, '0')}-'
          '${fiveDaysAgo.day.toString().padLeft(2, '0')}';
      SharedPreferences.setMockInitialValues(prefs({
        'weight_confirmed_at': now - const Duration(days: 70).inSeconds,
        'weight_prompted_day': stamp,
        'weight_prompt_count': 1,
      }));

      expect(await ProfileNudges.maybePromptWeight(), isTrue,
          reason: 'an ignored prompt must come back, not disappear');
      expect(presented.length, 1);
    },
  );

  test('backs off rather than nagging daily', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // Asked yesterday, count=2 → back-off is 7 days, so it is NOT due.
    final yesterday = DateTime.now().subtract(const Duration(days: 1));
    final stamp = '${yesterday.year.toString().padLeft(4, '0')}-'
        '${yesterday.month.toString().padLeft(2, '0')}-'
        '${yesterday.day.toString().padLeft(2, '0')}';
    SharedPreferences.setMockInitialValues(prefs({
      'weight_confirmed_at': now - const Duration(days: 70).inSeconds,
      'weight_prompted_day': stamp,
      'weight_prompt_count': 2,
    }));

    expect(await ProfileNudges.maybePromptWeight(), isFalse);
    expect(presented, isEmpty);
  });
}
