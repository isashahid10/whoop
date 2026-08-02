// day_details_sheet.dart — the "what else is true right now" sheet.
//
// A place for the contextual facts that matter but do not deserve permanent
// space on the home screen: prayer times, what you have eaten, the weather you
// will train in, how booked the day is.
//
// Two rules keep it from becoming a dumping ground:
//
//   1. ANSWER THE QUESTION, don't print a table. "Asr in 40 min" beats a list
//      of five times you have to read and subtract from.
//   2. A SECTION WITH NOTHING TO SAY DOES NOT RENDER. Every row here comes
//      from an optional source — Health may be unauthorised, weather needs a
//      location, the calendar needs a grant — and five headings above five
//      dashes reads as a broken screen rather than an empty one.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../compute/caffeine_service.dart';
import '../../data/db.dart';
import '../../platform/alarm_intents.dart';
import 'package:openstrap_analytics/onehz.dart' as ana;
import '../../notify/prayer_times.dart';
import '../../notify/ramadan.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

/// [bandAlarmEpoch] is the alarm currently armed on the STRAP (unix seconds),
/// or null. Passed in rather than read from a provider so the sheet does not
/// depend on where in the tree it was opened from.
Future<void> showDayDetailsSheet(
  BuildContext context, {
  int? bandAlarmEpoch,
  Future<void> Function()? onCancelAlarm,
}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: AppColors.surface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(R.card)),
    ),
    builder: (_) => _DayDetailsSheet(
      bandAlarmEpoch: bandAlarmEpoch,
      onCancelAlarm: onCancelAlarm,
    ),
  );
}

class _DayDetailsSheet extends StatefulWidget {
  final int? bandAlarmEpoch;

  /// Cancels BOTH sides. Null when the caller has no alarm control (the sheet
  /// then shows the times without an action, rather than a dead button).
  final Future<void> Function()? onCancelAlarm;

  const _DayDetailsSheet({this.bandAlarmEpoch, this.onCancelAlarm});

  @override
  State<_DayDetailsSheet> createState() => _DayDetailsSheetState();
}

class _DayDetailsSheetState extends State<_DayDetailsSheet> {
  List<PrayerSlot>? _slots;
  Map<Prayer5, bool> _done = const {};
  bool _prayerOn = false;
  bool _loaded = false;
  Map<String, double> _ctx = const {};
  List<DateTime> _phoneAlarms = const [];

  /// Set once cancelled, so the section vanishes without waiting for a
  /// reload — the band write can take a second and a row that lingers after
  /// "Cancel" reads as the cancel having failed.
  bool _alarmCancelled = false;
  ana.CaffeineImpact _caffeine = ana.CaffeineImpact.none;
  bool _fastingToday = false;
  // Permission state, so "not granted" and "granted but nothing recorded" can
  // be told apart. Showing a grant button to someone who already granted is
  // the most confusing possible outcome.
  bool _hasLocation = false;
  bool _hasCalendar = false;
  ({DateTime suhoorEnds, DateTime iftar})? _fastTimes;
  List<({DateTime at, double mg, String? label})> _doses = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final on = await PrayerTimesService.enabled();
    final slots = on ? await PrayerTimesService.slotsFor(DateTime.now()) : null;
    final done =
        on ? await PrayerTimesService.todayStatus() : const <Prayer5, bool>{};
    final ctx = await _loadContext();
    final phone = await AlarmIntents.pendingBackups();
    final caff = await CaffeineService.impactTonight();
    final doses = await CaffeineService.today();
    final fasting = await RamadanService.enabled()
        ? await RamadanService.isFasting(DateTime.now())
        : false;
    final fastTimes =
        fasting ? await RamadanService.timings(DateTime.now()) : null;
    final hasLoc = await PrayerTimesService.hasLocation();
    final hasCal = await AppState.calendarGranted();
    if (!mounted) return;
    setState(() {
      _prayerOn = on;
      _slots = slots;
      _done = done;
      _ctx = ctx;
      _phoneAlarms = phone;
      _caffeine = caff;
      _doses = doses;
      _fastingToday = fasting;
      _fastTimes = fastTimes;
      _hasLocation = hasLoc;
      _hasCalendar = hasCal;
      _loaded = true;
    });
  }

  /// Today's optional context scalars, straight out of metric_series.
  ///
  /// One query for every key rather than a per-section round trip: they all
  /// live in the same table and the sheet needs them together.
  Future<Map<String, double>> _loadContext() async {
    try {
      final db = await LocalDb.instance;
      final now = DateTime.now();
      final day = '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final rows = await db.query(
        'metric_series',
        columns: ['key', 'value'],
        where: 'date = ?',
        whereArgs: [day],
      );
      return {
        for (final r in rows)
          if (r['key'] is String && r['value'] is num)
            r['key'] as String: (r['value'] as num).toDouble(),
      };
    } catch (_) {
      return const {};
    }
  }

  static String _hm(DateTime d) {
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    return '$h:${d.minute.toString().padLeft(2, '0')} '
        '${d.hour < 12 ? 'am' : 'pm'}';
  }

  /// "in 40 min" / "in 2h 10m" — the thing you actually want to know.
  static String _until(DateTime target, DateTime now) {
    final m = target.difference(now).inMinutes;
    if (m < 1) return 'now';
    if (m < 60) return 'in $m min';
    return 'in ${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x3, Sp.screen, Sp.x5),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AppColors.divider,
                  borderRadius: BorderRadius.circular(R.pill),
                ),
              ),
            ),
            const SizedBox(height: Sp.x4),
            Text('Today', style: AppText.h2),
            const SizedBox(height: Sp.x4),
            if (!_loaded)
              Skeleton.tileRow(rows: 3)
            else ...[
              ..._alarmSection(),
              ..._fastingSection(),
              ..._prayerSection(),
              ..._caffeineSection(),
              ..._section('Nutrition', OsIcon.calories, [
                _stat('Calories in', _ctx['hk_kcal_in'], 'kcal'),
                _stat('Protein', _ctx['hk_protein_g'], 'g'),
                _stat('Carbs', _ctx['hk_carbs_g'], 'g'),
                _stat('Fat', _ctx['hk_fat_g'], 'g'),
                _stat('Water', _ctx['hk_water_l'], 'L', decimals: 1),
              ]),
              ..._section(
                'Conditions',
                OsIcon.skinTemperature,
                [
                  _stat('High', _ctx['wx_temp_max_c'], '°C'),
                  _stat('Humidity', _ctx['wx_humidity_pct'], '%'),
                ],
                // Empty here almost always means "location was never
                // granted", so the section offers the GRANT rather than
                // instructions for finding it in Settings. A prompt the user
                // has to go hunting for is one they will not act on.
                emptyNote: _hasLocation
                    ? 'Fetching today\'s conditions - pull to refresh in a '
                        'moment.'
                    : 'Weather needs your location.',
                emptyAction: _hasLocation ? null : 'Allow location',
                onEmptyAction: _hasLocation ? null : _grantLocation,
              ),
              ..._section(
                'Schedule',
                OsIcon.calendar,
                [
                  _stat('Events', _ctx['cal_events'], ''),
                  _stat('Booked', _ctx['cal_busy_min'], 'min'),
                ],
                emptyNote: _hasCalendar
                    ? 'Nothing in your calendar today.'
                    : 'See how booked your day is, and whether a packed '
                        'schedule shows up in your stress and sleep.',
                emptyAction: _hasCalendar ? null : 'Allow calendar',
                onEmptyAction: _hasCalendar ? null : _grantCalendar,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Upcoming alarms, on BOTH sides.
  ///
  /// The band and the phone are armed independently and can genuinely differ —
  /// the band write needs a live connection, the phone one does not — so they
  /// are listed separately rather than merged into one comforting line. Seeing
  /// "phone only" is the whole point: it tells you the strap did not get it.
  List<Widget> _alarmSection() {
    final band = widget.bandAlarmEpoch;
    final bandAt = band == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(band * 1000);
    final now = DateTime.now();
    // A time in the past has already fired; listing it as "upcoming" is a lie.
    final bandUpcoming = bandAt != null && bandAt.isAfter(now) ? bandAt : null;
    final phoneUpcoming = [
      for (final a in _phoneAlarms)
        if (a.isAfter(now)) a,
    ];

    if (_alarmCancelled) return const [];
    if (bandUpcoming == null && phoneUpcoming.isEmpty) return const [];

    return [
      Row(
        children: [
          AppIcon(OsIcon.alarm, size: 16, color: AppColors.inkSoft),
          const SizedBox(width: Sp.x2),
          Text('UPCOMING ALARM',
              style: AppText.overline
                  .copyWith(color: AppColors.inkSoft, letterSpacing: 1.1)),
        ],
      ),
      const SizedBox(height: Sp.x3),
      if (bandUpcoming != null)
        _alarmRow('Band', _hm(bandUpcoming), _until(bandUpcoming, now)),
      for (final a in phoneUpcoming)
        _alarmRow('Phone', _hm(a), _until(a, now)),
      if (widget.onCancelAlarm != null) ...[
        const SizedBox(height: Sp.x2),
        Pressable(
          onTap: () async {
            await widget.onCancelAlarm!();
            if (!mounted) return;
            setState(() => _alarmCancelled = true);
            await _load();
          },
          borderRadius: BorderRadius.circular(R.pill),
          child: Container(
            alignment: Alignment.center,
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: AppColors.tonalFill(AppColors.bad),
              borderRadius: BorderRadius.circular(R.pill),
            ),
            child: Text(
              'Cancel alarm',
              style: AppText.label.copyWith(
                color: AppColors.bad,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ],
      if (bandUpcoming == null)
        Padding(
          padding: const EdgeInsets.only(top: Sp.x2),
          child: Text(
            'Not on the band yet - it arms next time the strap connects.',
            style: AppText.captionMuted,
          ),
        ),
      const SizedBox(height: Sp.x2),
    ];
  }

  Widget _alarmRow(String where, String at, String until) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(child: Text(where, style: AppText.body)),
            Text('$at · $until',
                style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
          ],
        ),
      );

  List<Widget> _prayerSection() {
    if (!_prayerOn) {
      return [
        Text(
          'Prayer reminders are off. Turn them on in Profile → Notifications '
          'and the day\'s times will show here.',
          style: AppText.captionMuted,
        ),
      ];
    }

    final slots = _slots;
    if (slots == null) {
      return [
        Text(
          'Prayer times need your location. Grant it for Whoop in Settings, '
          'then re-open this.',
          style: AppText.captionMuted,
        ),
      ];
    }

    final now = DateTime.now();
    // The next prayer that has not started, for the headline. Isha rolls over
    // to tomorrow's Fajr, which slotsFor does not cover — after the last
    // prayer of the day there is simply no "next" to show, and saying nothing
    // is better than showing a time from this morning.
    // The headline is about the next PRAYER — sunrise is a deadline, not
    // something to be "next" for, and "Next: Sunrise" reads as nonsense.
    PrayerSlot? next;
    for (final s in slots) {
      if (!s.isMarker && s.at.isAfter(now)) {
        next = s;
        break;
      }
    }
    PrayerSlot? current;
    for (final s in slots) {
      if (!s.isMarker && !s.at.isAfter(now) && s.until.isAfter(now)) {
        current = s;
      }
    }

    return [
      Row(
        children: [
          AppIcon(OsIcon.calm, size: 16, color: AppColors.accent),
          const SizedBox(width: Sp.x2),
          Text('PRAYER',
              style: AppText.overline
                  .copyWith(color: AppColors.accent, letterSpacing: 1.1)),
        ],
      ),
      const SizedBox(height: Sp.x3),
      // The headline: what is happening now, or what is next and when.
      if (current != null && _done[current.prayer] != true)
        _headline(
          '${current.label} now',
          'until ${_hm(current.until)}',
          AppColors.accent,
        )
      else if (next != null)
        _headline(
          'Next: ${next.label}',
          '${_hm(next.at)} · ${_until(next.at, now)}',
          AppColors.ink,
        )
      else
        _headline('All prayers done for today', '', AppColors.good),
      const SizedBox(height: Sp.x4),
      for (final s in slots) _row(s, now),
    ];
  }

  /// Ask for location, then pull weather straight away so the section fills
  /// in immediately rather than waiting on the next 3-hourly cadence.
  Future<void> _grantLocation() async {
    final ok = await PrayerTimesService.ensureLocationPermission();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Location denied. Enable it for Whoop in Settings → Privacy → '
            'Location Services.',
          ),
        ),
      );
      return;
    }
    await context.read<AppState>().syncAmbientNow();
    if (mounted) await _load();
  }

  Future<void> _grantCalendar() async {
    final ok = await context.read<AppState>().requestCalendarAccess();
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Calendar denied. Enable it for Whoop in Settings → Privacy → '
            'Calendars.',
          ),
        ),
      );
      return;
    }
    await _load();
  }

  /// Fasting: suhoor and iftar, and how long today's fast actually is.
  ///
  /// Only renders on a day marked fasted — this is the one section that would
  /// be pure noise the other eleven months of the year.
  List<Widget> _fastingSection() {
    if (!_fastingToday) return const [];
    final t = _fastTimes;
    final now = DateTime.now();

    String? headline;
    String? sub;
    if (t != null) {
      if (now.isBefore(t.suhoorEnds)) {
        headline = 'Suhoor ends ${_hm(t.suhoorEnds)}';
        sub = _until(t.suhoorEnds, now);
      } else if (now.isBefore(t.iftar)) {
        headline = 'Iftar at ${_hm(t.iftar)}';
        sub = _until(t.iftar, now);
      } else {
        headline = 'Fast complete';
      }
    }

    final length = t?.iftar.difference(t.suhoorEnds);

    return [
      const SizedBox(height: Sp.x5),
      Row(
        children: [
          AppIcon(OsIcon.calm, size: 16, color: AppColors.good),
          const SizedBox(width: Sp.x2),
          Text('FASTING',
              style: AppText.overline
                  .copyWith(color: AppColors.good, letterSpacing: 1.1)),
          const Spacer(),
          if (length != null)
            Text('${length.inHours}h ${length.inMinutes % 60}m fast',
                style: AppText.captionMuted),
        ],
      ),
      const SizedBox(height: Sp.x3),
      if (headline != null)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(headline, style: AppText.title),
            if (sub != null) Text(sub, style: AppText.captionMuted),
          ],
        )
      else
        Text('Prayer times are needed for suhoor and iftar.',
            style: AppText.captionMuted),
      const SizedBox(height: Sp.x2),
      Text(
        // Says WHY the app cares, so the flag does not look like decoration.
        'Fasted days are kept out of your baselines and correlations, so a '
        'month of fasting is not read as illness.',
        style: AppText.captionMuted.copyWith(fontSize: 11),
      ),
    ];
  }

  /// Caffeine: what is still in you at bedtime, and a one-tap log.
  ///
  /// Always renders, unlike the read-only sections — this one is an INPUT, and
  /// a logging affordance that only appears once you have already logged
  /// something is useless.
  List<Widget> _caffeineSection() {
    final summary = _caffeine.summary;
    return [
      const SizedBox(height: Sp.x5),
      Row(
        children: [
          AppIcon(OsIcon.cardio, size: 16, color: AppColors.inkSoft),
          const SizedBox(width: Sp.x2),
          Text('CAFFEINE',
              style: AppText.overline
                  .copyWith(color: AppColors.inkSoft, letterSpacing: 1.1)),
          const Spacer(),
          if (_doses.isNotEmpty)
            Text('${_caffeine.totalMg.round()} mg today',
                style: AppText.captionMuted),
        ],
      ),
      const SizedBox(height: Sp.x2),
      Text(
        summary ??
            (_doses.isEmpty
                ? 'Nothing logged today.'
                : 'Clear by bedtime - nothing meaningful left.'),
        style: summary == null
            ? AppText.captionMuted
            : AppText.body.copyWith(color: AppColors.warn),
      ),
      const SizedBox(height: Sp.x3),
      // A short row of the drinks actually consumed, rather than a full
      // picker: the common case is two or three taps a day.
      Wrap(
        spacing: Sp.x2,
        runSpacing: Sp.x2,
        children: [
          for (final p in CaffeinePreset.all.take(5))
            Pressable(
              onTap: () async {
                await CaffeineService.log(mg: p.mg, label: p.label);
                await _load();
              },
              borderRadius: BorderRadius.circular(R.pill),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x3, vertical: 7),
                decoration: BoxDecoration(
                  color: AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(R.pill),
                ),
                child: Text('+ ${p.label}',
                    style: AppText.caption.copyWith(fontSize: 12)),
              ),
            ),
        ],
      ),
      if (_doses.isNotEmpty) ...[
        const SizedBox(height: Sp.x3),
        for (final d in _doses)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(
                  child: Text(d.label ?? '${d.mg.round()} mg',
                      style: AppText.captionMuted),
                ),
                Text(_hm(d.at), style: AppText.captionMuted),
                const SizedBox(width: Sp.x3),
                Pressable(
                  onTap: () async {
                    await CaffeineService.remove(d.at);
                    await _load();
                  },
                  child: Icon(Icons.close_rounded,
                      size: 15, color: AppColors.inkMuted),
                ),
              ],
            ),
          ),
      ],
    ];
  }

  /// One label/value pair, or null when there is no value — the null is what
  /// lets an entire section disappear rather than render a row of dashes.
  ({String label, String value})? _stat(
    String label,
    double? v,
    String unit, {
    int decimals = 0,
  }) {
    if (v == null) return null;
    final n = decimals == 0 ? v.round().toString() : v.toStringAsFixed(decimals);
    return (label: label, value: unit.isEmpty ? n : '$n $unit');
  }

  /// A titled group. Returns nothing at all when every row is absent.
  /// [emptyNote] turns an absent section into an EXPLANATION rather than a
  /// silence. Used where absence means "you have not granted something",
  /// which the user can act on; sections whose absence just means "no data
  /// yet" still render nothing.
  List<Widget> _section(
    String title,
    OsIcon icon,
    List<({String label, String value})?> rows, {
    String? emptyNote,
    String? emptyAction,
    Future<void> Function()? onEmptyAction,
  }) {
    final present = rows.nonNulls.toList();
    if (present.isEmpty && emptyNote == null) return const [];
    return [
      const SizedBox(height: Sp.x5),
      Row(
        children: [
          AppIcon(icon, size: 16, color: AppColors.inkSoft),
          const SizedBox(width: Sp.x2),
          Text(title.toUpperCase(),
              style: AppText.overline
                  .copyWith(color: AppColors.inkSoft, letterSpacing: 1.1)),
        ],
      ),
      const SizedBox(height: Sp.x3),
      if (present.isEmpty) ...[
        Text(emptyNote!, style: AppText.captionMuted),
        if (emptyAction != null && onEmptyAction != null) ...[
          const SizedBox(height: Sp.x3),
          Pressable(
            onTap: onEmptyAction,
            borderRadius: BorderRadius.circular(R.pill),
            child: Container(
              alignment: Alignment.center,
              padding: const EdgeInsets.symmetric(vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.tonalFill(AppColors.accent),
                borderRadius: BorderRadius.circular(R.pill),
              ),
              child: Text(
                emptyAction,
                style: AppText.label.copyWith(
                  color: AppColors.accent,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ],
      ] else
        for (final r in present)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(child: Text(r.label, style: AppText.body)),
                Text(r.value,
                    style: AppText.body.copyWith(fontWeight: FontWeight.w700)),
              ],
            ),
          ),
    ];
  }

  Widget _headline(String title, String sub, Color color) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
              style: AppText.title.copyWith(color: color)),
          if (sub.isNotEmpty)
            Text(sub, style: AppText.captionMuted),
        ],
      );

  /// Sunrise and friends: the time, dimmed, with no affordance at all.
  Widget _markerRow(PrayerSlot s) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
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

  Widget _row(PrayerSlot s, DateTime now) {
    if (s.isMarker) return _markerRow(s);
    final done = _done[s.prayer] ?? false;
    final isCurrent = !s.at.isAfter(now) && s.until.isAfter(now);
    final passed = !s.until.isAfter(now);

    return Pressable(
      onTap: () async {
        if (done) {
          await PrayerTimesService.undoDone(DateTime.now(), s.prayer);
        } else {
          await PrayerTimesService.markDone(DateTime.now(), s.prayer);
        }
        await _load();
      },
      borderRadius: BorderRadius.circular(R.chip),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            Icon(
              done ? Icons.check_circle_rounded : Icons.circle_outlined,
              size: 18,
              color: done
                  ? AppColors.good
                  : (isCurrent ? AppColors.accent : AppColors.inkMuted),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Text(
                s.label,
                style: AppText.body.copyWith(
                  fontWeight: isCurrent && !done ? FontWeight.w700 : null,
                  // A missed window is dimmed, not hidden: it still happened
                  // and you may still want to mark it.
                  color: done || passed ? AppColors.inkMuted : AppColors.ink,
                  decoration: done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
            Text(
              _hm(s.at),
              style: AppText.captionMuted.copyWith(
                color: isCurrent && !done ? AppColors.accent : null,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
