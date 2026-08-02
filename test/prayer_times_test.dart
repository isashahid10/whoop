// Prayer times.
//
// The astronomy is the adhan package's job and is not re-tested here. What IS
// tested is the part this app decides: how long each window actually is, how
// often to nag inside it, and that the id bands cannot collide with each other
// or with the reminder ids already in use.

import 'package:adhan/adhan.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/notify/prayer_times.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/supplement_reminder.dart';

PrayerSlot _slot(Prayer5 p, DateTime at, Duration window) =>
    PrayerSlot(prayer: p, at: at, until: at.add(window));

void main() {
  group('reminder cadence', () {
    final t = DateTime(2026, 7, 28, 5, 30);

    test('a short window nags every 15 minutes', () {
      // Fajr → sunrise is often around an hour.
      final s = _slot(Prayer5.fajr, t, const Duration(minutes: 70));
      expect(s.reminderInterval, const Duration(minutes: 15));
    });

    test('a long window nags every 30 minutes', () {
      // Dhuhr → Asr in summer.
      final s = _slot(Prayer5.dhuhr, t, const Duration(hours: 4));
      expect(s.reminderInterval, const Duration(minutes: 30));
    });

    test('the boundary is two hours', () {
      expect(
        _slot(Prayer5.asr, t, const Duration(minutes: 119)).reminderInterval,
        const Duration(minutes: 15),
      );
      expect(
        _slot(Prayer5.asr, t, const Duration(hours: 2)).reminderInterval,
        const Duration(minutes: 30),
      );
    });

    test('the interval is DERIVED, so the same prayer differs by season', () {
      // Maghrib → Isha is short in winter and long near midsummer at high
      // latitude. Hardcoding a per-prayer interval would be wrong half the year.
      final winter = _slot(Prayer5.maghrib, t, const Duration(minutes: 75));
      final summer = _slot(Prayer5.maghrib, t, const Duration(hours: 3));
      expect(winter.reminderInterval, isNot(summer.reminderInterval));
    });
  });

  group('notification ids', () {
    test('every prayer gets a disjoint band', () {
      final bases = {for (final p in Prayer5.values) p.idBase};
      expect(bases.length, Prayer5.values.length);
      // Each band must hold the on-time notification plus every follow-up
      // without reaching into the next prayer's band.
      final sorted = bases.toList()..sort();
      for (var i = 1; i < sorted.length; i++) {
        expect(sorted[i] - sorted[i - 1],
            greaterThan(PrayerTimesService.maxFollowUps));
      }
    });

    test('the band clears the reminder ids already in use', () {
      // Water occupies idWaterBase..+maxWaterSlots and stillness sits at 2200;
      // a prayer landing on either would silently replace it in the shade.
      final top = NotificationService.idWaterBase +
          NotificationService.maxWaterSlots;
      expect(PrayerTimesService.idBase, greaterThan(top));
      expect(PrayerTimesService.idBase,
          greaterThan(NotificationService.idStillness));
    });

    test('a band holds today AND the look-ahead days without colliding', () {
      // idBase steps by 10 per prayer. Today needs 1 + maxFollowUps slots and
      // each look-ahead day needs one more; if that total ever reached 10 a
      // prayer would start overwriting the next one's notifications.
      final used = 1 + PrayerTimesService.maxFollowUps +
          (PrayerTimesService.daysAhead - 1);
      expect(used, lessThan(10),
          reason: 'per-prayer id band overflows into the next prayer');
    });

    test('the whole prayer range stays below the allocated category bands', () {
      // NotificationIds allocates from 100000 upward; overlapping would let an
      // allocated id collide with a fixed one.
      final highest = Prayer5.values.last.idBase + PrayerTimesService.maxFollowUps;
      expect(highest, lessThan(100000));
    });
  });

  group('OS notification budget', () {
    test('the whole app stays under the iOS 64-pending ceiling', () {
      // iOS keeps only the soonest 64 pending local notifications and SILENTLY
      // drops the rest - no throw, no log, reminders just stop arriving. This
      // pins the arithmetic so adding a new recurring reminder cannot quietly
      // push hydration or the wind-down nudge off the end.
      final prayer =
          Prayer5.values.length * (1 + PrayerTimesService.maxFollowUps);
      const water = NotificationService.maxWaterSlots;
      const supplement = 1 + SupplementReminder.maxSnoozes;
      const misc = 6; // wind-down, recap, journal, 2 briefs, stillness

      final worstCase = prayer + water + supplement + misc;
      expect(worstCase, lessThan(PrayerTimesService.iosPendingLimit),
          reason: 'worst-case pending count $worstCase exceeds the OS ceiling; '
              'something will be silently dropped');
    });
  });

  group('defaults', () {
    test('the calculation method enum round-trips by name', () {
      // Settings persist the enum NAME, so a rename upstream would silently
      // fall back to the default rather than crash - this pins the one we use.
      final m = CalculationMethod.values
          .firstWhere((m) => m.name == 'muslim_world_league');
      expect(m, CalculationMethod.muslim_world_league);
    });

    test('both madhabs exist and differ', () {
      expect(Madhab.values, contains(Madhab.shafi));
      expect(Madhab.values, contains(Madhab.hanafi));
    });
  });

  group('sunrise marker', () {
    test('a marker is labelled Sunrise, not by its prayer', () {
      final m = PrayerSlot(
        prayer: Prayer5.fajr,
        at: DateTime(2026, 7, 28, 7),
        until: DateTime(2026, 7, 28, 12),
        isMarker: true,
      );
      expect(m.label, 'Sunrise');
      expect(m.isMarker, isTrue);
      // Two rows both reading "Fajr" would be baffling.
      expect(m.label, isNot(Prayer5.fajr.label));
    });

    test('an ordinary slot is labelled by its prayer', () {
      final p = _slot(Prayer5.fajr, DateTime(2026, 7, 28, 5), const Duration(hours: 2));
      expect(p.label, 'Fajr');
      expect(p.isMarker, isFalse);
    });
  });

  group('windows', () {
    test('window length is end minus start', () {
      final s = _slot(Prayer5.isha, DateTime(2026, 7, 28, 20), const Duration(hours: 8));
      expect(s.window, const Duration(hours: 8));
    });

    test('labels are the conventional names', () {
      expect(Prayer5.values.map((p) => p.label).toList(),
          ['Fajr', 'Dhuhr', 'Asr', 'Maghrib', 'Isha']);
    });
  });
}
