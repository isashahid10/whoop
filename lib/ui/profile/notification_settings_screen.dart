// Notification settings — what reaches the OS shade, and when it may break
// through quiet hours. The in-app feed is always kept regardless of these toggles;
// these only gate OS notifications.
//
// Decision (locked): health-critical alerts (illness, unusual physiology, fever)
// can override quiet hours; recovery + reminders stay silent during the window.
// Presentation: design-system language; prefs/scheduling logic untouched.

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:adhan/adhan.dart' show Madhab;
import '../../notify/prayer_times.dart';
import '../../notify/ramadan.dart';
import '../../notify/supplement_reminder.dart';
import '../../notify/notification_center.dart';
import '../../notify/notification_prefs.dart';
import '../../notify/notification_service.dart';
import '../../state/app_state.dart';
import '../design/design.dart';

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen({super.key});

  @override
  State<NotificationSettingsScreen> createState() =>
      _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState
    extends State<NotificationSettingsScreen> {
  NotificationPrefs _p = const NotificationPrefs();
  bool _loaded = false;

  // Prayer + supplements own their own enable flags rather than living in
  // NotificationPrefs: both are personal opt-ins with their own schedules and
  // their own id bands, and folding them into the shared prefs object would
  // couple every unrelated reminder to their reschedule.
  bool _prayerOn = false;
  bool _suppOn = true;
  ({int hour, int minute}) _suppTime = (
    hour: SupplementReminder.defaultHour,
    minute: SupplementReminder.defaultMinute,
  );
  Madhab _madhab = Madhab.shafi;
  bool _ramadanOn = false;
  ({DateTime start, DateTime end})? _ramadanWindow;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final p = await NotificationPrefs.load();
    final prayerOn = await PrayerTimesService.enabled();
    final madhab = await PrayerTimesService.madhab();
    final suppOn = await SupplementReminder.enabled();
    final suppTime = await SupplementReminder.time();
    final ramadanOn = await RamadanService.enabled();
    final ramadanWindow = await RamadanService.window();
    if (!mounted) return;
    setState(() {
      _p = p;
      _prayerOn = prayerOn;
      _madhab = madhab;
      _suppOn = suppOn;
      _suppTime = suppTime;
      _ramadanOn = ramadanOn;
      _ramadanWindow = ramadanWindow;
      _loaded = true;
    });
    // Surface the OS permission prompt up front so the toggles actually do
    // something once granted.
    await NotificationService.instance.ensurePermission();
  }

  Future<void> _update(NotificationPrefs next,
      {bool reschedule = false}) async {
    setState(() => _p = next);
    await next.save();
    if (reschedule) {
      await NotificationCenter.instance.scheduleStandingReminders(next);
      // Re-arm the in-app strap-buzz timer to match the new schedule.
      if (mounted) await context.read<AppState>().armWaterReminder(next);
    }
  }

  String _fmt(int min) {
    final h = (min ~/ 60) % 24;
    final m = min % 60;
    final t = TimeOfDay(hour: h, minute: m);
    return t.format(context);
  }

  // Selectable hydration intervals (minutes). Modifiable — the user picks one.
  static const List<int> _waterPresets = [30, 60, 90, 120, 180, 240];

  String _fmtInterval(int min) {
    if (min < 60) return '$min min';
    final h = min / 60;
    final label = h == h.roundToDouble() ? '${h.toInt()}' : h.toString();
    return '$label hr${h == 1 ? '' : 's'}';
  }

  Future<void> _pickTime(bool start) async {
    final cur = start ? _p.quietStartMin : _p.quietEndMin;
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: (cur ~/ 60) % 24, minute: cur % 60),
    );
    if (picked == null) return;
    final mins = picked.hour * 60 + picked.minute;
    await _update(start
        ? _p.copyWith(quietStartMin: mins)
        : _p.copyWith(quietEndMin: mins));
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Notifications',
      subtitle: 'Alerts, recovery & reminders',
      actions: const [
        InfoDot(
          title: 'How notifications work',
          bullets: [
            'Everything is generated on this device from your own data - '
                'nothing is sent to a server.',
            'Your in-app history keeps every alert even when a category '
                'is off.',
            'Health alerts can break through quiet hours if you allow it.',
          ],
        ),
      ],
      children: [
        if (!_loaded)
          Skeleton.tileRow(rows: 3)
        else ...[
          const SectionHeader('What you get'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Health alerts',
                subtitle:
                    'Possible illness, unusual overnight physiology and '
                    'elevated temperature. High priority.',
                value: _p.healthEnabled,
                onChanged: (v) => _update(_p.copyWith(healthEnabled: v)),
              ),
              const _HairLine(),
              _toggle(
                title: 'Recovery',
                subtitle:
                    'Your daily recovery readiness and notable shifts in '
                    'your trends.',
                value: _p.recoveryEnabled,
                onChanged: (v) => _update(_p.copyWith(recoveryEnabled: v)),
              ),
              const _HairLine(),
              _toggle(
                title: 'Reminders',
                subtitle:
                    'Wind-down, movement nudges, step goal and the weekly '
                    'recap.',
                value: _p.remindersEnabled,
                onChanged: (v) =>
                    _update(_p.copyWith(remindersEnabled: v), reschedule: true),
              ),
            ]),
          ),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Hydration'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Water reminder',
                subtitle:
                    'A gentle nudge across your waking hours, and a buzz on '
                    'your strap when it\'s connected. Silent in quiet hours.',
                value: _p.waterEnabled,
                onChanged: (v) =>
                    _update(_p.copyWith(waterEnabled: v), reschedule: true),
              ),
              if (_p.waterEnabled) ...[
                const _HairLine(),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.x2),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('How often', style: AppText.title),
                      const SizedBox(height: 2),
                      Text('Every ${_fmtInterval(_p.waterIntervalMin)}.',
                          style: AppText.captionMuted),
                      const SizedBox(height: Sp.x3),
                      Wrap(
                        spacing: Sp.x2,
                        runSpacing: Sp.x2,
                        children: [
                          for (final m in _waterPresets)
                            ToggleChip(
                              _fmtInterval(m),
                              selected: _p.waterIntervalMin == m,
                              onTap: () => _update(
                                  _p.copyWith(waterIntervalMin: m),
                                  reschedule: true),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ]),
          ),
          const SizedBox(height: Sp.x6),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Supplements'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Supplement reminder',
                subtitle:
                    'A daily nudge, with a snooze. Marking it taken stops the '
                    'follow-ups for the rest of the evening.',
                value: _suppOn,
                onChanged: (v) async {
                  setState(() => _suppOn = v);
                  await SupplementReminder.setEnabled(v);
                },
              ),
              if (_suppOn) ...[
                const _HairLine(),
                ListRow(
                  icon: OsIcon.alarm,
                  title: 'Time',
                  value:
                      '${_suppTime.hour.toString().padLeft(2, '0')}:'
                      '${_suppTime.minute.toString().padLeft(2, '0')}',
                  onTap: () async {
                    final picked = await showTimePicker(
                      context: context,
                      initialTime: TimeOfDay(
                          hour: _suppTime.hour, minute: _suppTime.minute),
                    );
                    if (picked == null) return;
                    await SupplementReminder.setTime(
                        picked.hour, picked.minute);
                    setState(() => _suppTime =
                        (hour: picked.hour, minute: picked.minute));
                  },
                ),
              ],
            ]),
          ),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Prayer times'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Prayer reminders',
                subtitle:
                    'The five daily prayers for your location, calculated on '
                    'your phone. Reminders repeat through each prayer window '
                    'until you mark it prayed.',
                value: _prayerOn,
                onChanged: (v) async {
                  setState(() => _prayerOn = v);
                  final ok = await PrayerTimesService.setEnabled(v);
                  if (!context.mounted) return;
                  // A switch that is ON but silently computing nothing is the
                  // worst outcome — say so rather than let the user wait all
                  // day for a notification that can never arrive.
                  if (v && !ok) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text(
                          'Prayer times need location. Enable it for Whoop in '
                          'Settings, then toggle this again.',
                        ),
                      ),
                    );
                  }
                },
              ),
              if (_prayerOn) ...[
                const _HairLine(),
                // Madhab changes the Asr calculation only — worth exposing
                // because the two conventions differ by roughly an hour, which
                // is the difference between a useful reminder and a wrong one.
                ListRow(
                  icon: OsIcon.info,
                  title: 'Asr calculation',
                  subtitle: _madhab == Madhab.hanafi
                      ? 'Hanafi (later Asr)'
                      : 'Standard (Shafi, Maliki, Hanbali)',
                  onTap: () async {
                    final next = _madhab == Madhab.hanafi
                        ? Madhab.shafi
                        : Madhab.hanafi;
                    await PrayerTimesService.setMadhab(next);
                    setState(() => _madhab = next);
                  },
                ),
              ],
            ]),
          ),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Ramadan'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Fasting mode',
                subtitle:
                    'Shows suhoor and iftar, and keeps fasted days out of your '
                    'baselines so a month of fasting is not read as illness.',
                value: _ramadanOn,
                onChanged: (v) async {
                  if (!v) {
                    await RamadanService.clearWindow();
                    setState(() {
                      _ramadanOn = false;
                      _ramadanWindow = null;
                    });
                    return;
                  }
                  // Prefill from the tabular calendar, but make the USER
                  // confirm: the month begins on local moon sighting, which
                  // differs between countries and even between communities.
                  final suggested = RamadanService.suggestedWindow();
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    initialDateRange: DateTimeRange(
                      start: suggested.start,
                      end: suggested.end,
                    ),
                    helpText: 'Confirm your Ramadan dates',
                  );
                  if (picked == null) return;
                  await RamadanService.setWindow(picked.start, picked.end);
                  if (!context.mounted) return;
                  setState(() {
                    _ramadanOn = true;
                    _ramadanWindow = (start: picked.start, end: picked.end);
                  });
                },
              ),
              if (_ramadanOn && _ramadanWindow != null) ...[
                const _HairLine(),
                ListRow(
                  icon: OsIcon.calendar,
                  title: 'Dates',
                  value: '${_ramadanWindow!.start.day}/'
                      '${_ramadanWindow!.start.month} – '
                      '${_ramadanWindow!.end.day}/${_ramadanWindow!.end.month}',
                  subtitle: 'Tap the switch to re-pick',
                ),
              ],
            ]),
          ),
          const SizedBox(height: Sp.x6),
          const SectionHeader('Quiet hours'),
          SurfaceCard(
            child: Column(children: [
              _toggle(
                title: 'Silence during quiet hours',
                subtitle: 'Recovery and reminders stay silent in this window.',
                value: _p.quietEnabled,
                onChanged: (v) => _update(_p.copyWith(quietEnabled: v)),
              ),
              if (_p.quietEnabled) ...[
                const _HairLine(),
                ListRow(
                  title: 'From',
                  value: _fmt(_p.quietStartMin),
                  divider: true,
                  onTap: () => _pickTime(true),
                ),
                ListRow(
                  title: 'To',
                  value: _fmt(_p.quietEndMin),
                  divider: true,
                  onTap: () => _pickTime(false),
                ),
                _toggle(
                  title: 'Let health alerts through',
                  subtitle:
                      'Illness and temperature alerts can still notify you '
                      'during quiet hours.',
                  value: _p.criticalOverridesQuiet,
                  onChanged: (v) =>
                      _update(_p.copyWith(criticalOverridesQuiet: v)),
                ),
              ],
            ]),
          ),
          const SizedBox(height: Sp.x4),
        ],
      ],
    );
  }

  Widget _toggle({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(vertical: Sp.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: AppText.title),
                  const SizedBox(height: 2),
                  Text(subtitle, style: AppText.captionMuted),
                ],
              ),
            ),
            const SizedBox(width: Sp.x3),
            Switch(
              value: value,
              activeThumbColor: AppColors.accent,
              onChanged: onChanged,
            ),
          ],
        ),
      );
}

class _HairLine extends StatelessWidget {
  const _HairLine();
  @override
  Widget build(BuildContext context) =>
      Divider(height: Sp.x4, thickness: 1, color: AppColors.divider);
}
