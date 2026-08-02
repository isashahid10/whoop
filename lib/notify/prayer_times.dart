// prayer_times.dart — the five daily prayers, computed on-device and nagged
// until marked done.
//
// WHY OFFLINE, NOT AN API. There are free prayer-time web APIs, and the first
// instinct is to call one. That is the wrong trade here for three reasons:
// a notification has to be SCHEDULED AHEAD, so it must survive having no
// signal at 4am; a hosted service can rate-limit or disappear (§8.5 of the
// project notes is a list of exactly that happening); and the astronomy is
// settled maths, not data that needs fetching. The `adhan` package is a port of
// the widely-used Adhan library and computes everything locally from
// coordinates.
//
// THE REMINDER CADENCE is derived, not hardcoded. Each prayer's window runs
// until the next prayer begins, and those windows differ enormously — Fajr to
// sunrise can be 70 minutes in summer, while Dhuhr to Asr is often four hours.
// So the follow-up interval comes from the measured window: a short window gets
// tight nudges, a long one gets sparse ones. Hardcoding "Fajr = 15 min" would
// be wrong half the year at Melbourne's latitude, and very wrong further south.
//
// Reminders stop the moment the prayer is marked done. That is the entire point
// of the feature — an alarm you cannot silence by doing the thing it is asking
// for is just noise.

import 'package:adhan/adhan.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/db.dart';
import 'notification_event.dart';
import 'notification_service.dart';

enum Prayer5 { fajr, dhuhr, asr, maghrib, isha }

extension Prayer5X on Prayer5 {
  String get label => switch (this) {
        Prayer5.fajr => 'Fajr',
        Prayer5.dhuhr => 'Dhuhr',
        Prayer5.asr => 'Asr',
        Prayer5.maghrib => 'Maghrib',
        Prayer5.isha => 'Isha',
      };

  /// Fixed id band, 10 slots per prayer:
  ///   +0                       today's on-time
  ///   +1 .. +maxFollowUps      today's follow-ups
  ///   +maxFollowUps+1 ..       the look-ahead days' on-time slots
  /// The cap never reaches 10, so bands cannot collide (pinned by a test).
  int get idBase => PrayerTimesService.idBase + index * 10;
}

/// One prayer, with the window it stays valid for.
class PrayerSlot {
  final Prayer5 prayer;
  final DateTime at;

  /// When the window closes — the next prayer's start (or, for Fajr, sunrise).
  final DateTime until;

  /// True for a MARKER rather than a prayer: sunrise ends Fajr's window but is
  /// not itself something you pray, so it is shown for orientation and is
  /// never checkable and never notified.
  final bool isMarker;

  /// What to call this row. Markers override the prayer's own name — a second
  /// row reading "Fajr" would be baffling.
  String get label => isMarker ? 'Sunrise' : prayer.label;

  const PrayerSlot({
    required this.prayer,
    required this.at,
    required this.until,
    this.isMarker = false,
  });

  Duration get window => until.difference(at);

  /// Follow-up spacing, derived from the window rather than assumed.
  ///
  /// Under two hours the window is tight enough that a half-hour gap could fit
  /// only one reminder in, so nudge every 15 minutes; longer windows get 30 so
  /// a four-hour afternoon does not turn into eight notifications.
  Duration get reminderInterval =>
      window < const Duration(hours: 2)
          ? const Duration(minutes: 15)
          : const Duration(minutes: 30);
}

class PrayerTimesService {
  PrayerTimesService._();

  /// Base OS notification id. Sits above the water band (2100 + 24 slots) and
  /// the stillness nudge (2200), below the allocated category bands (100000+).
  static const int idBase = 2400;

  /// Most follow-ups to schedule for one prayer.
  ///
  /// IOS KEEPS ONLY 64 PENDING LOCAL NOTIFICATIONS. Past that it silently
  /// drops the surplus — nothing throws, nothing logs, reminders just stop
  /// arriving. The app's standing budget is roughly:
  ///
  ///     water      up to 24   (maxWaterSlots)
  ///     prayer     5 x (1 + maxFollowUps)
  ///     supplement 1 + 4 snoozes
  ///     wind-down / recap / journal / briefs / stillness   ~6
  ///
  /// At the original maxFollowUps of 6 that totalled ~70 and quietly pushed
  /// other reminders off the end whenever hydration was also on. Four keeps
  /// the worst case near 55 with headroom.
  ///
  /// Coverage is not really reduced: [reschedule] only ever queues follow-ups
  /// for prayers still AHEAD, so the practical count falls through the day.
  static const int maxFollowUps = 3;

  /// How many days ahead to arm the on-time notification.
  ///
  /// Prayer times move a minute or two daily, so unlike the wind-down nudge
  /// they CANNOT use a repeating daily schedule — every one is a one-shot at an
  /// absolute time. Arming only today meant that if the app was not opened for
  /// a day, the next day had nothing scheduled and the reminders simply stopped
  /// with no error. iOS background refresh is opportunistic and cannot be
  /// relied on to close that gap.
  ///
  /// Two days of on-time notifications means a full day can be missed without
  /// losing coverage; follow-ups stay TODAY-only, because they are the
  /// expensive part of the budget and a stale follow-up for a day already gone
  /// is worse than useless.
  static const int daysAhead = 2;

  /// The OS ceiling this budget is sized against.
  static const int iosPendingLimit = 64;

  static const _kEnabled = 'prayer_enabled';
  static const _kMethod = 'prayer_method';
  static const _kMadhab = 'prayer_madhab';
  static const _kLat = 'prayer_last_lat';
  static const _kLon = 'prayer_last_lon';

  // ── settings ───────────────────────────────────────────────────────────────

  static Future<bool> enabled() async {
    final p = await SharedPreferences.getInstance();
    return p.getBool(_kEnabled) ?? false;
  }

  /// Turn the feature on or off.
  ///
  /// Turning it ON also REQUESTS location, because prayer times are a pure
  /// function of coordinates and there is nothing to compute without them.
  /// [_coordinates] deliberately never prompts (it runs on background paths
  /// where a permission dialog would be an ambush), so without this the switch
  /// flipped, nothing was scheduled, and no notification ever arrived — a
  /// feature that silently did nothing.
  ///
  /// Returns false when it was enabled but location was refused, so the caller
  /// can say so rather than leaving a switch on that cannot work.
  static Future<bool> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
    if (!v) {
      await cancelAll();
      return true;
    }
    final located = await ensureLocationPermission();
    await reschedule();
    return located;
  }

  /// Ask for location, once, as a user gesture.
  static Future<bool> ensureLocationPermission() async {
    try {
      var perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      return perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse;
    } catch (_) {
      return false;
    }
  }

  /// Whether times can actually be computed right now — a location fix exists
  /// (live or cached). The settings UI uses this to explain a switch that is
  /// on but producing nothing.
  static Future<bool> hasLocation() async => (await _coordinates()) != null;

  /// Calculation method. Defaults to Muslim World League — the most widely
  /// used general-purpose method, and the sane default when the user's local
  /// mosque convention is unknown. Settable, because it genuinely varies.
  static Future<CalculationMethod> method() async {
    final p = await SharedPreferences.getInstance();
    final name = p.getString(_kMethod);
    return CalculationMethod.values.firstWhere(
      (m) => m.name == name,
      orElse: () => CalculationMethod.muslim_world_league,
    );
  }

  static Future<void> setMethod(CalculationMethod m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMethod, m.name);
    await reschedule();
  }

  /// Madhab, which changes the Asr calculation only.
  static Future<Madhab> madhab() async {
    final p = await SharedPreferences.getInstance();
    return p.getString(_kMadhab) == 'hanafi' ? Madhab.hanafi : Madhab.shafi;
  }

  static Future<void> setMadhab(Madhab m) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_kMadhab, m.name);
    await reschedule();
  }

  // ── location ───────────────────────────────────────────────────────────────

  /// Resolve coordinates without prompting, caching the last good fix.
  ///
  /// Same posture as the weather client: never triggers a permission dialog on
  /// its own. Prayer times are wrong if the location is wrong, so a cached fix
  /// from the right city beats no times at all, and a wildly stale one is still
  /// better than silently defaulting to Mecca.
  static Future<Coordinates?> _coordinates() async {
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.always ||
          perm == LocationPermission.whileInUse) {
        final pos = await Geolocator.getLastKnownPosition() ??
            await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.low,
                timeLimit: Duration(seconds: 10),
              ),
            );
        await LocalDb.setCursor(_kLat, pos.latitude.toString());
        await LocalDb.setCursor(_kLon, pos.longitude.toString());
        return Coordinates(pos.latitude, pos.longitude);
      }
    } catch (_) {
      // fall through to the cache
    }
    final lat = double.tryParse(await LocalDb.getCursor(_kLat) ?? '');
    final lon = double.tryParse(await LocalDb.getCursor(_kLon) ?? '');
    if (lat != null && lon != null) return Coordinates(lat, lon);
    return null;
  }

  // ── computation ────────────────────────────────────────────────────────────

  /// The five prayers for [day], with their windows. Null when there is no
  /// usable location — the caller must show "location needed", never guess.
  static Future<List<PrayerSlot>?> slotsFor(DateTime day) async {
    final coords = await _coordinates();
    if (coords == null) return null;

    final params = (await method()).getParameters()..madhab = await madhab();
    final times = PrayerTimes(
      coords,
      DateComponents.from(day),
      params,
    );
    // Tomorrow's Fajr closes Isha's window; without it Isha would have no end
    // and its interval could not be derived.
    final tomorrow = PrayerTimes(
      coords,
      DateComponents.from(day.add(const Duration(days: 1))),
      params,
    );

    return [
      // Fajr's window ends at SUNRISE, not at Dhuhr — praying it after sunrise
      // is not the same thing, so the reminders must stop there.
      PrayerSlot(
        prayer: Prayer5.fajr,
        at: times.fajr,
        until: times.sunrise,
      ),
      // SUNRISE — the end of Fajr, shown so the deadline is visible rather
      // than implied by Fajr's row alone. Not a prayer: `isMarker` keeps it
      // out of the notification scheduler and out of the "n of 5" count.
      PrayerSlot(
        prayer: Prayer5.fajr,
        at: times.sunrise,
        until: times.dhuhr,
        isMarker: true,
      ),
      PrayerSlot(prayer: Prayer5.dhuhr, at: times.dhuhr, until: times.asr),
      PrayerSlot(prayer: Prayer5.asr, at: times.asr, until: times.maghrib),
      PrayerSlot(
        prayer: Prayer5.maghrib,
        at: times.maghrib,
        until: times.isha,
      ),
      PrayerSlot(
        prayer: Prayer5.isha,
        at: times.isha,
        until: tomorrow.fajr,
      ),
    ];
  }

  // ── "I prayed" ─────────────────────────────────────────────────────────────

  static String _doneKey(DateTime day, Prayer5 p) =>
      'prayer_done:${day.year}-${day.month}-${day.day}:${p.name}';

  static Future<bool> isDone(DateTime day, Prayer5 p) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_doneKey(day, p)) ?? false;
  }

  /// Mark a prayer prayed and silence the rest of its follow-ups immediately.
  static Future<void> markDone(DateTime day, Prayer5 p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_doneKey(day, p), true);
    await _cancelToday(p);
  }

  static Future<void> undoDone(DateTime day, Prayer5 p) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_doneKey(day, p));
    await reschedule();
  }

  /// Today's completion state, for the home-screen card.
  static Future<Map<Prayer5, bool>> todayStatus() async {
    final now = DateTime.now();
    final out = <Prayer5, bool>{};
    for (final p in Prayer5.values) {
      out[p] = await isDone(now, p);
    }
    return out;
  }

  // ── scheduling ─────────────────────────────────────────────────────────────

  /// Silence TODAY only — the on-time slot and today's follow-ups.
  ///
  /// Deliberately leaves the look-ahead slots armed: marking today's Fajr
  /// prayed says nothing about tomorrow's, and cancelling the whole band here
  /// would quietly disarm the next day every time a prayer was marked.
  static Future<void> _cancelToday(Prayer5 p) async {
    final svc = NotificationService.instance;
    for (var i = 0; i <= maxFollowUps; i++) {
      await svc.cancel(p.idBase + i);
    }
  }

  /// Clear a prayer's ENTIRE id band, look-ahead included. For a full
  /// reschedule or when the feature is switched off.
  static Future<void> _cancelPrayer(Prayer5 p) async {
    final svc = NotificationService.instance;
    for (var i = 0; i < 10; i++) {
      await svc.cancel(p.idBase + i);
    }
  }

  static Future<void> cancelAll() async {
    for (final p in Prayer5.values) {
      await _cancelPrayer(p);
    }
  }

  /// Rebuild every pending prayer notification.
  ///
  /// Cancel-then-reschedule, matching the convention the rest of the reminder
  /// system uses: a moved location or a changed method must not leave
  /// yesterday's times pending.
  static Future<void> reschedule() async {
    if (!await enabled()) {
      await cancelAll();
      return;
    }
    final now = DateTime.now();
    await cancelAll();

    final svc = NotificationService.instance;

    // Tomorrow (and beyond) — the ON-TIME notification only. Armed first so a
    // missed day still fires; the follow-up machinery below belongs to today.
    for (var d = 1; d < daysAhead; d++) {
      final day = now.add(Duration(days: d));
      final ahead = await slotsFor(day);
      if (ahead == null) continue;
      for (final slot in ahead) {
        if (slot.isMarker) continue;
        await svc.scheduleOnce(
          id: slot.prayer.idBase + maxFollowUps + d,
          category: NotifCategory.reminders,
          title: slot.prayer.label,
          body: 'It is time for ${slot.prayer.label}.',
          at: slot.at,
          route: '/today',
        );
      }
    }

    final slots = await slotsFor(now);
    if (slots == null) {
      debugPrint('[prayer] no location - nothing scheduled');
      return;
    }

    for (final slot in slots) {
      if (slot.isMarker) continue; // sunrise is orientation, not a reminder
      if (await isDone(now, slot.prayer)) continue;
      // A window that has already closed is not worth a notification: the
      // reminder would fire for a prayer whose time has passed.
      if (!slot.until.isAfter(now)) continue;

      final name = slot.prayer.label;
      var id = slot.prayer.idBase;

      // The on-time notification, unless the prayer already started — in which
      // case the follow-ups below pick it up from the next interval.
      if (slot.at.isAfter(now)) {
        await svc.scheduleOnce(
          id: id,
          category: NotifCategory.reminders,
          title: name,
          body: 'It is time for $name.',
          at: slot.at,
          route: '/today',
        );
      }
      id++;

      // Follow-ups across the window, stopping short of its close so the last
      // nudge still leaves time to actually pray.
      final interval = slot.reminderInterval;
      final deadline = slot.until.subtract(const Duration(minutes: 5));
      var t = slot.at.add(interval);
      var n = 0;
      while (n < maxFollowUps && t.isBefore(deadline)) {
        if (t.isAfter(now)) {
          final left = slot.until.difference(t).inMinutes;
          await svc.scheduleOnce(
            id: id,
            category: NotifCategory.reminders,
            title: '$name - not marked yet',
            body: left >= 60
                ? 'About ${(left / 60).floor()}h ${left % 60}m left for $name.'
                : 'About $left min left for $name.',
            at: t,
            route: '/today',
          );
          id++;
          n++;
        }
        t = t.add(interval);
      }
    }
    debugPrint('[prayer] scheduled for ${slots.length} prayers');
  }
}
