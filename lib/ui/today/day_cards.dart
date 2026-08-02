// day_cards.dart — the "my day" cards under the score rings.
//
// These are the things that are TRUE OF TODAY and actionable right now, as
// opposed to the rings above them, which describe a state. Each one either
// tells you something you did or asks you for something you have not done yet.
//
// One rule holds the section together: a card that has nothing to say does not
// render. An app full of empty placeholders reads as broken, and the cost of a
// missing card is far lower than the cost of five cards all saying "—".

import 'package:flutter/material.dart';

import '../../data/db.dart';
import '../../state/app_state.dart';
import '../../notify/prayer_times.dart';
import '../../notify/supplement_reminder.dart';
import '../design/design.dart';

// ── last lift ────────────────────────────────────────────────────────────────

/// The most recent Hevy session, if there is one.
class LastLiftCard extends StatefulWidget {
  final VoidCallback? onTap;
  const LastLiftCard({super.key, this.onTap});

  @override
  State<LastLiftCard> createState() => _LastLiftCardState();
}

class _LastLiftCardState extends State<LastLiftCard> {
  Map<String, Object?>? _row;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
    // Rebuilding this widget does NOT re-run initState — Flutter reuses the
    // State — so without an explicit signal the card kept showing the previous
    // workout after a Hevy sync while the Workouts tab showed the new one.
    AppState.dataRevision.addListener(_load);
  }

  @override
  void dispose() {
    AppState.dataRevision.removeListener(_load);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final db = await LocalDb.instance;
      final rows = await db.rawQuery('''
        SELECT w.day, w.name, w.duration_s, w.total_volume_kg, w.set_count,
               (SELECT COUNT(DISTINCT exercise_title) FROM hevy_set
                  WHERE workout_id = w.id) AS exercises
        FROM hevy_workout w
        -- `day` is the authoritative LOCAL calendar day; start_ts is an epoch
        -- whose day depends on the offset at import time. Ordering by day first
        -- means a workout logged late in the evening cannot sort behind one
        -- from the previous day.
        ORDER BY w.day DESC, w.start_ts DESC
        LIMIT 1
      ''');
      if (mounted) {
        setState(() {
          _row = rows.isEmpty ? null : rows.first;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loaded = true);
    }
  }

  /// "Today" / "Yesterday" / "3 days ago" — relative reads better than a date
  /// for something this recent, and the exact date is on the detail screen.
  static String _ago(String? day) {
    if (day == null) return '';
    final d = DateTime.tryParse(day);
    if (d == null) return day;
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    return switch (days) {
      <= 0 => 'Today',
      1 => 'Yesterday',
      < 7 => '$days days ago',
      < 14 => 'Last week',
      _ => '${(days / 7).floor()} weeks ago',
    };
  }

  @override
  Widget build(BuildContext context) {
    // Nothing synced yet → no card at all. A "no workouts" placeholder on the
    // home screen every day is noise, and the Workouts tab already says it.
    if (!_loaded || _row == null) return const SizedBox.shrink();

    final r = _row!;
    final volume = (r['total_volume_kg'] as num?)?.toDouble() ?? 0;
    final sets = (r['set_count'] as num?)?.toInt() ?? 0;
    final exercises = (r['exercises'] as num?)?.toInt() ?? 0;
    final mins = ((r['duration_s'] as num?)?.toInt() ?? 0) ~/ 60;

    return Pressable(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(R.card),
      child: SurfaceCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                AppIcon(OsIcon.strength, size: 16,
                    color: DomainAccent.strain),
                const SizedBox(width: Sp.x2),
                Text('LAST LIFT',
                    style: AppText.overline.copyWith(
                        color: DomainAccent.strain, letterSpacing: 1.1)),
                const Spacer(),
                Text(_ago(r['day'] as String?), style: AppText.captionMuted),
              ],
            ),
            const SizedBox(height: Sp.x3),
            Text(
              (r['name'] as String?)?.trim().isNotEmpty == true
                  ? r['name'] as String
                  : 'Workout',
              style: AppText.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: Sp.x3),
            Row(
              children: [
                _stat('$sets', sets == 1 ? 'set' : 'sets'),
                _stat('$exercises', 'exercises'),
                _stat(
                  volume >= 1000
                      ? '${(volume / 1000).toStringAsFixed(1)}t'
                      : '${volume.round()}kg',
                  'volume',
                ),
                if (mins > 0) _stat('${mins}m', 'duration'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _stat(String v, String label) => Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(v, style: AppText.metricSm.copyWith(fontSize: 20)),
            Text(label, style: AppText.captionMuted),
          ],
        ),
      );
}

// ── prayer times ─────────────────────────────────────────────────────────────

/// Today's five prayers, each tappable to mark prayed.
///
/// Marking is the whole point: it is what stops the follow-up reminders, so
/// the card has to make it a single tap and show the result immediately.
class PrayerCard extends StatefulWidget {
  const PrayerCard({super.key});

  @override
  State<PrayerCard> createState() => _PrayerCardState();
}

class _PrayerCardState extends State<PrayerCard> {
  List<PrayerSlot>? _slots;
  Map<Prayer5, bool> _done = const {};
  bool _enabled = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await PrayerTimesService.enabled();
    if (!on) {
      if (mounted) setState(() { _enabled = false; _loaded = true; });
      return;
    }
    final slots = await PrayerTimesService.slotsFor(DateTime.now());
    final done = await PrayerTimesService.todayStatus();
    if (mounted) {
      setState(() {
        _enabled = true;
        _slots = slots;
        _done = done;
        _loaded = true;
      });
    }
  }

  Future<void> _toggle(Prayer5 p) async {
    final now = DateTime.now();
    if (_done[p] == true) {
      await PrayerTimesService.undoDone(now, p);
    } else {
      await PrayerTimesService.markDone(now, p);
    }
    await _load();
  }

  static String _hm(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} '
        '${d.hour < 12 ? 'am' : 'pm'}';
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || !_enabled) return const SizedBox.shrink();

    final slots = _slots;
    if (slots == null) {
      // Location is genuinely required — prayer times are a function of it —
      // so say that rather than showing times for the wrong place.
      return SurfaceCard(
        child: Row(
          children: [
            AppIcon(OsIcon.info, size: 16, color: AppColors.warn),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                'Prayer times need your location. Grant it in Settings and '
                'they will appear here.',
                style: AppText.captionMuted,
              ),
            ),
          ],
        ),
      );
    }

    final now = DateTime.now();
    // The prayer whose window we are inside — highlighted, because that is the
    // only row that is actionable right now. Markers are skipped: sunrise
    // cannot be "current" in the sense of something to do.
    PrayerSlot? current;
    for (final s in slots) {
      if (!s.isMarker && !s.at.isAfter(now) && s.until.isAfter(now)) {
        current = s;
      }
    }

    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              AppIcon(OsIcon.calm, size: 16, color: AppColors.accent),
              const SizedBox(width: Sp.x2),
              Text('PRAYER',
                  style: AppText.overline
                      .copyWith(color: AppColors.accent, letterSpacing: 1.1)),
              const Spacer(),
              Text(
                '${_done.values.where((v) => v).length} of 5',
                style: AppText.captionMuted,
              ),
            ],
          ),
          const SizedBox(height: Sp.x3),
          for (final s in slots)
            _row(s, done: _done[s.prayer] ?? false, isCurrent: s == current),
        ],
      ),
    );
  }

  /// Sunrise: the time only, no checkbox — it marks the end of Fajr rather
  /// than being something to do.
  Widget _markerRow(PrayerSlot s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            SizedBox(
              width: 18,
              child: Icon(Icons.wb_twilight_rounded,
                  size: 15, color: AppColors.inkMuted),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Text(s.label,
                  style: AppText.captionMuted.copyWith(fontSize: 13)),
            ),
            Text(_hm(s.at), style: AppText.captionMuted),
          ],
        ),
      );

  Widget _row(PrayerSlot s, {required bool done, required bool isCurrent}) {
    if (s.isMarker) return _markerRow(s);
    final color = done
        ? AppColors.good
        : (isCurrent ? AppColors.accent : AppColors.inkMuted);
    return Pressable(
      onTap: () => _toggle(s.prayer),
      borderRadius: BorderRadius.circular(R.chip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 18,
              color: color,
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Text(
                s.label,
                style: (isCurrent && !done
                        ? AppText.body.copyWith(fontWeight: FontWeight.w700)
                        : AppText.body)
                    .copyWith(
                  color: done ? AppColors.inkMuted : AppColors.ink,
                  // Struck through when done: the row stays readable but is
                  // visibly out of the way, which is what "handled" should
                  // look like.
                  decoration: done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            Text(_hm(s.at),
                style: AppText.captionMuted.copyWith(
                    color: isCurrent && !done ? AppColors.accent : null)),
          ],
        ),
      ),
    );
  }
}

// ── supplements ──────────────────────────────────────────────────────────────

class SupplementCard extends StatefulWidget {
  const SupplementCard({super.key});

  @override
  State<SupplementCard> createState() => _SupplementCardState();
}

class _SupplementCardState extends State<SupplementCard> {
  bool _taken = false;
  bool _enabled = true;
  bool _loaded = false;
  ({int hour, int minute})? _time;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await SupplementReminder.enabled();
    final taken = await SupplementReminder.takenToday();
    final t = await SupplementReminder.time();
    if (mounted) {
      setState(() {
        _enabled = on;
        _taken = taken;
        _time = t;
        _loaded = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loaded || !_enabled) return const SizedBox.shrink();

    final t = _time;
    final now = DateTime.now();
    // Before the reminder is due there is nothing to nag about, so the card
    // stays away until its time — and reappears the moment it is relevant.
    final due = t == null ||
        now.hour > t.hour ||
        (now.hour == t.hour && now.minute >= t.minute);
    if (!due && !_taken) return const SizedBox.shrink();

    return SurfaceCard(
      child: Row(
        children: [
          Icon(
            _taken ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 22,
            color: _taken ? AppColors.good : AppColors.accent,
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Supplements',
                  style: AppText.body.copyWith(
                    fontWeight: FontWeight.w700,
                    color: _taken ? AppColors.inkMuted : AppColors.ink,
                    decoration: _taken ? TextDecoration.lineThrough : null,
                  ),
                ),
                Text(
                  _taken ? 'Taken today' : 'Not marked yet',
                  style: AppText.captionMuted,
                ),
              ],
            ),
          ),
          if (!_taken) ...[
            // Snooze sits BESIDE done, not behind a menu: postponing is the
            // honest answer most evenings, and hiding it just trains the user
            // to swipe the notification away instead.
            Pressable(
              onTap: () async {
                await SupplementReminder.snooze();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Reminding you in 30 min')),
                  );
                }
              },
              borderRadius: BorderRadius.circular(R.pill),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x3, vertical: 6),
                child: Text('Snooze',
                    style: AppText.label.copyWith(color: AppColors.inkMuted)),
              ),
            ),
            const SizedBox(width: Sp.x2),
          ],
          Pressable(
            onTap: () async {
              if (_taken) {
                await SupplementReminder.undoTaken();
              } else {
                await SupplementReminder.markTaken();
              }
              await _load();
            },
            borderRadius: BorderRadius.circular(R.pill),
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x3, vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.tonalFill(
                    _taken ? AppColors.inkMuted : AppColors.accent),
                borderRadius: BorderRadius.circular(R.pill),
              ),
              child: Text(
                _taken ? 'Undo' : 'Taken',
                style: AppText.label.copyWith(
                    color: _taken ? AppColors.inkMuted : AppColors.accent),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
