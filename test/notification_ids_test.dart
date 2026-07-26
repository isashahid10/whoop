// Regression tests for the OS notification id ALLOCATOR (notification_ids.dart).
//
// Ids used to be DERIVED as `categoryBase + dedupeKey.hashCode.abs() % 100000`.
// That is a hash modulo: two distinct dedupeKeys in the same category whose
// hashes agree mod 100000 produced the SAME id, and `FlutterLocalNotifications
// .show` REPLACES a post with the same id rather than stacking beside it — so
// one of the two notifications vanished with no trace. (The "partitioned so a
// health alert can never overwrite a reminder" comment only ever covered
// CROSS-category collisions.)
//
// The first test below FINDS a real collision under the old formula and proves
// the allocator keeps those two keys apart.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:openstrap_edge/data/day_label.dart';
import 'package:openstrap_edge/notify/notification_event.dart';
import 'package:openstrap_edge/notify/notification_ids.dart';

/// Dated keys, anchored to TODAY so the retention prune (14 days) can never
/// make this suite time-dependent.
final String kToday = todayLabel();

NotificationEvent _ev(String key,
        [NotifCategory c = NotifCategory.reminders]) =>
    NotificationEvent(
      dedupeKey: key,
      category: c,
      title: 't',
      body: 'b',
      date: kToday,
    );

/// The pre-fix id formula, kept here purely as the thing we regress against.
int _legacySlot(String dedupeKey) => dedupeKey.hashCode.abs() % 100000;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    NotificationIds.instance.resetForTest();
  });

  test('two same-category keys that COLLIDE under the old hash get distinct ids',
      () async {
    // Search for a genuine collision (birthday bound: ~450 keys over 100k slots).
    String? a, b;
    final bySlot = <int, String>{};
    for (var i = 0; i < 200000 && b == null; i++) {
      final k = '$kToday:probe$i';
      final prior = bySlot[_legacySlot(k)];
      if (prior != null) {
        a = prior;
        b = k;
      } else {
        bySlot[_legacySlot(k)] = k;
      }
    }
    expect(b, isNotNull,
        reason: 'expected a hashCode%100000 collision within the probe budget');

    // Precondition: the OLD scheme really did hand these two the same id.
    expect(_legacySlot(a!), equals(_legacySlot(b!)));

    final ids = NotificationIds.instance;
    final idA = await ids.idFor(_ev(a));
    final idB = await ids.idFor(_ev(b));
    expect(idA, isNot(equals(idB)),
        reason: 'colliding keys must not share an OS id — one would '
            'silently REPLACE the other in the shade');
    // Both still inside the reminders band.
    expect(idA ~/ NotificationIds.bandSize, equals(4));
    expect(idB ~/ NotificationIds.bandSize, equals(4));
  });

  test('a batch of distinct keys gets a fully distinct set of ids', () async {
    final ids = NotificationIds.instance;
    final out = <int>{};
    for (var i = 0; i < 500; i++) {
      out.add(await ids.idFor(_ev('$kToday:k$i')));
    }
    expect(out.length, 500);
  });

  test('the same dedupeKey keeps its id — a re-post replaces in place',
      () async {
    final ids = NotificationIds.instance;
    final first = await ids.idFor(_ev('$kToday:recovery_ready'));
    final again = await ids.idFor(_ev('$kToday:recovery_ready'));
    expect(again, equals(first));
  });

  test('an allocation survives a process restart (persisted, not memoized)',
      () async {
    final first =
        await NotificationIds.instance.idFor(_ev('$kToday:illness'));
    // Simulate a fresh process: in-memory maps gone, shared_preferences intact.
    NotificationIds.instance.resetForTest();
    final afterRestart =
        await NotificationIds.instance.idFor(_ev('$kToday:illness'));
    expect(afterRestart, equals(first));
  });

  test('categories stay in disjoint bands', () async {
    final ids = NotificationIds.instance;
    expect(await ids.idFor(_ev('k', NotifCategory.device)) ~/ 100000, 1);
    expect(await ids.idFor(_ev('k', NotifCategory.recovery)) ~/ 100000, 2);
    expect(await ids.idFor(_ev('k', NotifCategory.health)) ~/ 100000, 3);
    expect(await ids.idFor(_ev('k', NotifCategory.reminders)) ~/ 100000, 4);
  });

  test('the SAME key in two categories gets two ids, one per band', () async {
    final ids = NotificationIds.instance;
    final health = await ids.idFor(_ev('$kToday:x', NotifCategory.health));
    final rem = await ids.idFor(_ev('$kToday:x', NotifCategory.reminders));
    expect(health, isNot(equals(rem)));
  });
}
