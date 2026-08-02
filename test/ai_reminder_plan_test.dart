// Tests for the pure AI notification schedule + the tap-route resolver.

import 'package:flutter_test/flutter_test.dart';

import 'package:openstrap_edge/ai/ai_prefs.dart';
import 'package:openstrap_edge/ai/reminder_plan.dart';
import 'package:openstrap_edge/notify/notification_service.dart';
import 'package:openstrap_edge/notify/tap_router.dart';

void main() {
  group('aiReminderPlan', () {
    test('all three slots when configured + reminders on', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
      );
      final ids = plan.map((s) => s.id).toSet();
      expect(ids, contains(NotificationService.idMorningBrief));
      expect(ids, contains(NotificationService.idEveningBrief));
      expect(ids, contains(NotificationService.idJournalLog));
    });

    test('the MORNING briefing needs a key; the evening recap does NOT', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: false,
        journalDoneToday: false,
      );
      final ids = plan.map((s) => s.id).toSet();
      // The morning slot exists to deliver WRITTEN analysis, so without a key
      // it has nothing to deliver and stays away.
      expect(ids, isNot(contains(NotificationService.idMorningBrief)));
      // The evening slot summarises a day of MEASURED numbers, which exist
      // with or without a coach - suppressing it only meant the day ended
      // silently for anyone who never configured one.
      expect(ids, contains(NotificationService.idEveningBrief));
      expect(ids, contains(NotificationService.idJournalLog));
    });

    test('the evening recap deep-links to the coach only when there IS one',
        () {
      AiReminderSlot evening(bool configured) => aiReminderPlan(
            const AiPrefs(),
            remindersEnabled: true,
            aiConfigured: configured,
            journalDoneToday: false,
          ).firstWhere((s) => s.id == NotificationService.idEveningBrief);

      // Routing to the AI breakdown with no key would open a screen that can
      // only apologise.
      expect(evening(false).route, '/recap');
      expect(evening(true).route, isNot('/recap'));
    });

    test('nothing scheduled when reminders are off entirely', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: false,
        aiConfigured: true,
        journalDoneToday: false,
      );
      expect(plan, isEmpty);
    });

    test('per-feature toggles honoured', () {
      final plan = aiReminderPlan(
        const AiPrefs(morningEnabled: false, journalEnabled: false),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
      );
      final ids = plan.map((s) => s.id).toSet();
      expect(ids, {NotificationService.idEveningBrief});
    });

    test('journalDoneToday flags the journal slot to skip tonight', () {
      final done = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: true,
      ).firstWhere((s) => s.id == NotificationService.idJournalLog);
      expect(done.skipToday, isTrue);
    });

    test('journal fires ~30min before bedtime in AUTO mode', () {
      final slot = aiReminderPlan(
        const AiPrefs(), // journalMin defaults to AUTO
        remindersEnabled: true,
        aiConfigured: true,
        bedtimeMinOfDay: 23 * 60, // 23:00
        journalDoneToday: false,
      ).firstWhere((s) => s.id == NotificationService.idJournalLog);
      expect(slot.hour, 22);
      expect(slot.minute, 30);
      expect(slot.route, kRouteJournalCompose);
    });

    test('explicit journal time overrides bedtime', () {
      final slot = aiReminderPlan(
        const AiPrefs(journalMin: 21 * 60 + 15),
        remindersEnabled: true,
        aiConfigured: true,
        bedtimeMinOfDay: 23 * 60,
        journalDoneToday: false,
      ).firstWhere((s) => s.id == NotificationService.idJournalLog);
      expect(slot.hour, 21);
      expect(slot.minute, 15);
    });

    test('morning/evening carry their deep-link routes', () {
      final plan = aiReminderPlan(
        const AiPrefs(),
        remindersEnabled: true,
        aiConfigured: true,
        journalDoneToday: false,
      );
      expect(plan.firstWhere((s) => s.id == NotificationService.idMorningBrief).route,
          kRouteAiMorning);
      expect(plan.firstWhere((s) => s.id == NotificationService.idEveningBrief).route,
          kRouteAiEvening);
    });
  });

  group('resolveTapRoute', () {
    test('tab routes resolve to their index with no sub-screen', () {
      expect(resolveTapRoute('/today').tab, 0);
      expect(resolveTapRoute('/sleep').tab, 1);
      expect(resolveTapRoute('/today').screen, isNull);
    });

    test('AI + journal routes land on Today and request a sub-screen', () {
      final m = resolveTapRoute(kRouteAiMorning);
      expect(m.tab, 0);
      expect(m.screen, kRouteAiMorning);
      expect(resolveTapRoute(kRouteAiEvening).screen, kRouteAiEvening);
      expect(resolveTapRoute(kRouteJournalCompose).screen, kRouteJournalCompose);
    });

    test('unknown routes fall back to Today, no crash', () {
      final r = resolveTapRoute('/recap');
      expect(r.tab, 0);
      expect(r.screen, isNull);
    });
  });

  group('AiPrefs', () {
    test('resolvedJournalMin: explicit > bedtime-lead > fallback', () {
      expect(const AiPrefs(journalMin: 1300).resolvedJournalMin(), 1300);
      expect(
          const AiPrefs()
              .resolvedJournalMin(bedtimeMinOfDay: 22 * 60), // 22:00
          21 * 60 + 30); // 30 min before
      expect(const AiPrefs().resolvedJournalMin(), AiPrefs.journalFallbackMin);
    });
  });
}
