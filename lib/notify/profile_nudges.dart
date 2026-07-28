// profile_nudges.dart — nudges about the PROFILE itself, not the biometrics.
//
// Currently one: a weight re-check every 2 months.
//
// WHY IT MATTERS: `weight_kg` feeds the Keytel calorie model and TRIMP training
// load. A stale weight does not fail loudly — it silently biases every derived
// energy number, with no visible symptom. That is exactly the kind of quiet
// wrongness the app's honesty rule exists to prevent, and the user cannot spot
// it by looking at the app.
//
// WHY IT ESCALATES: [FiredKeyStore] is a fire-ONCE guard by design, so the
// obvious implementation (one dedupe key) would ask once, be dismissed, and
// then never ask again — leaving the stale weight in place forever, which is
// the failure this is meant to prevent. Instead the dedupe key carries the
// *day*, so an unanswered prompt re-arms and asks again on a widening cadence
// until it is actually answered.
//
// CONFIRMED vs EDITED is tracked separately on purpose: opening the profile
// screen, or an unrelated edit, must not count as "yes, 75kg is still right".

import 'package:shared_preferences/shared_preferences.dart';

import '../data/day_label.dart';
import 'notification_center.dart';
import 'notification_event.dart';

class ProfileNudges {
  /// Epoch seconds when the user last CONFIRMED their weight (entered or
  /// explicitly re-affirmed it) — never merely viewed it.
  static const String _kWeightConfirmedAt = 'weight_confirmed_at';

  /// Day-id of the last weight prompt, so a re-arm cannot fire twice in a day.
  static const String _kWeightPromptedDay = 'weight_prompted_day';

  /// How many times we have asked without an answer. Drives the back-off.
  static const String _kWeightPromptCount = 'weight_prompt_count';

  static const int _twoMonthsSeconds = 60 * 60 * 24 * 61;

  /// Record that the user actually confirmed their weight. Call this from the
  /// profile editor on save, NOT on open.
  static Future<void> markWeightConfirmed() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setInt(
          _kWeightConfirmedAt, DateTime.now().millisecondsSinceEpoch ~/ 1000);
      await p.setInt(_kWeightPromptCount, 0); // answered — reset the escalation
    } catch (_) {/* best effort */}
  }

  /// Days to wait before asking again after an ignored prompt. Widens so an
  /// uninterested user is not nagged daily, but is never fully forgotten —
  /// capped at a fortnight so it cannot drift into never asking again.
  static int _backoffDays(int promptCount) {
    if (promptCount <= 1) return 3;
    if (promptCount == 2) return 7;
    return 14;
  }

  /// Fire the weight re-check if it is due. Safe to call on every sync; it is
  /// its own rate-limiter.
  ///
  /// [allowPermissionPrompt] must be false from a headless/background context
  /// (see NotificationCenter.emit) — a background permission request has no
  /// foreground scene to present from and can get mis-cached as "denied".
  static Future<bool> maybePromptWeight({
    bool allowPermissionPrompt = true,
  }) async {
    final SharedPreferences p;
    try {
      p = await SharedPreferences.getInstance();
    } catch (_) {
      return false;
    }

    final now = DateTime.now();
    final nowSec = now.millisecondsSinceEpoch ~/ 1000;
    final today = dayLabelOf(now);

    // First run: seed the clock rather than prompting immediately. A nag on
    // day one, before the user has done anything, reads as broken.
    final confirmedAt = p.getInt(_kWeightConfirmedAt);
    if (confirmedAt == null) {
      await p.setInt(_kWeightConfirmedAt, nowSec);
      return false;
    }

    if (nowSec - confirmedAt < _twoMonthsSeconds) return false;

    // Already asked today.
    if (p.getString(_kWeightPromptedDay) == today) return false;

    // Respect the escalation back-off.
    final count = p.getInt(_kWeightPromptCount) ?? 0;
    final lastDay = p.getString(_kWeightPromptedDay);
    if (lastDay != null && count > 0) {
      final last = DateTime.tryParse(lastDay);
      if (last != null && now.difference(last).inDays < _backoffDays(count)) {
        return false;
      }
    }

    final months = ((nowSec - confirmedAt) / (60 * 60 * 24 * 30.44)).floor();
    final shown = await NotificationCenter.instance.emit(
      NotificationEvent(
        // Day in the key so an unanswered prompt RE-ARMS. A static key would
        // be permanently consumed by FiredKeyStore after the first fire.
        dedupeKey: '$today:weight_recheck',
        category: NotifCategory.reminders,
        priority: NotifPriority.low,
        title: 'Still $months months on the same weight?',
        body: 'Your calorie and training-load numbers use your body weight. '
            'Update it if it has changed.',
        route: '/profile',
        date: today,
      ),
      allowPermissionPrompt: allowPermissionPrompt,
    );

    if (shown) {
      await p.setString(_kWeightPromptedDay, today);
      await p.setInt(_kWeightPromptCount, count + 1);
    }
    return shown;
  }
}
