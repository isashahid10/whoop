// notification_event.dart — the single currency of the notification system.
//
// Everything that wants to reach the user (illness onset, recovery ready, a
// wind-down nudge, a step goal) is expressed as ONE NotificationEvent and handed
// to NotificationCenter.emit(), which decides whether it fires an OS
// notification based on the category + the user's NotificationPrefs. (There
// used to also be an in-app notifications feed/screen — removed; OS
// notifications are the only surface now.)
//
// Categories map 1:1 onto OS notification channels (see notification_service)
// so Android users can mute each kind independently. Priority drives the
// quiet-hours decision: `critical` can break through; everything else respects
// the user's quiet window.

enum NotifCategory { health, recovery, reminders, device }

enum NotifPriority { critical, normal, low }

class NotificationEvent {
  /// Idempotency key — used for the feed row id AND to derive a stable OS id, so
  /// the same logical event (e.g. "2026-06-27:illness") never duplicates and a
  /// re-fire replaces in place. Convention: `"$date:$kind"`.
  final String dedupeKey;
  final NotifCategory category;
  final NotifPriority priority;
  final String title;
  final String body;

  /// Deep-link route to open on tap (e.g. '/heart', '/today', '/recap').
  final String? route;

  /// Calendar day this event belongs to (yyyy-m-d), stored on the feed row.
  final String date;

  const NotificationEvent({
    required this.dedupeKey,
    required this.category,
    required this.title,
    required this.body,
    required this.date,
    this.priority = NotifPriority.normal,
    this.route,
  });

  // The OS notification id is NOT derived here any more. It used to be
  // `categoryBase + dedupeKey.hashCode.abs() % 100000` — a hash modulo, so two
  // distinct dedupeKeys in the same category could map onto the same id, and
  // `_plugin.show` REPLACES rather than stacks: one notification silently
  // vanished. Ids are now allocated collision-free per dedupeKey — see
  // notification_ids.dart (NotificationIds.idFor).
}
