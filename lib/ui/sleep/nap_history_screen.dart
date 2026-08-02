// nap_history_screen.dart — the nap column, over time.
//
// Replaces the route to SleepPeriodsScreen, which fetched from upstream's
// cloud backend (`getDaySleepV2`) and therefore could only ever fail in this
// fork. This reads the same locally derived `nap_min` series the day cards use.
//
// The framing is deliberate: this is a log of DAYTIME SLEEP, kept apart from
// the nightly record throughout. A day with a 90-minute nap and 5 hours of
// night sleep is not the same as a 6.5-hour night, and nothing here implies it
// is.

import 'package:flutter/material.dart';

import '../../compute/nap_service.dart';
import '../design/design.dart';

class NapHistoryScreen extends StatefulWidget {
  const NapHistoryScreen({super.key});

  @override
  State<NapHistoryScreen> createState() => _NapHistoryScreenState();
}

class _NapHistoryScreenState extends State<NapHistoryScreen> {
  Map<String, double> _byDay = const {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final t = await NapService.trend(days: 60);
    if (mounted) {
      setState(() {
        _byDay = t;
        _loading = false;
      });
    }
  }

  static String _dur(int min) {
    if (min < 60) return '${min}m';
    final h = min ~/ 60;
    final m = min % 60;
    return m == 0 ? '${h}h' : '${h}h ${m}m';
  }

  static String _pretty(String iso) {
    final d = DateTime.tryParse(iso);
    if (d == null) return iso;
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${wd[d.weekday - 1]} ${d.day} ${months[d.month - 1]}';
  }

  @override
  Widget build(BuildContext context) {
    // Only days with a nap. A day with no nap is not a zero to be plotted —
    // it is simply a day you did not nap, and filling the chart with zeroes
    // would make an occasional napper look like a failing one.
    final days = _byDay.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.key.compareTo(a.key));

    final total = days.fold<double>(0, (a, e) => a + e.value);

    return AppScaffold(
      title: 'Naps',
      subtitle: 'Daytime sleep, kept separate from your nights',
      body: _loading
          ? Skeleton.tileRow(rows: 3)
          : days.isEmpty
              ? const StateCard(
                  icon: OsIcon.bedtime,
                  title: 'No naps detected',
                  message:
                      'Naps are found from sustained stillness plus a drop in '
                      'heart rate, between 20 minutes and 3 hours. Wear the '
                      'band while you nap and they will appear here.',
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(
                      Sp.screen, Sp.x2, Sp.screen, Sp.x10),
                  children: [
                    SurfaceCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Last 60 days', style: AppText.title),
                          const SizedBox(height: Sp.x3),
                          Row(
                            children: [
                              _stat('${days.length}',
                                  days.length == 1 ? 'day' : 'days with a nap'),
                              _stat(_dur(total.round()), 'total'),
                              _stat(
                                _dur((total / days.length).round()),
                                'typical nap',
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: Sp.x4),
                    const SectionHeader('Every nap'),
                    for (final e in days)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Sp.x2),
                        child: SurfaceCard(
                          padding: const EdgeInsets.symmetric(
                              horizontal: Sp.x4, vertical: Sp.x3),
                          child: Row(
                            children: [
                              AppIcon(OsIcon.bedtime,
                                  size: 18, color: DomainAccent.sleep),
                              const SizedBox(width: Sp.x3),
                              Expanded(
                                child: Text(_pretty(e.key),
                                    style: AppText.body),
                              ),
                              Text(
                                _dur(e.value.round()),
                                style: AppText.body.copyWith(
                                  fontWeight: FontWeight.w800,
                                  color: DomainAccent.sleep,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(height: Sp.x4),
                    Text(
                      'Nap minutes are never added to your nightly sleep '
                      'total. Short naps are mostly light sleep, and a nap '
                      'also spends some of the sleep pressure that drives the '
                      'following night - so the two are counted separately.',
                      style: AppText.captionMuted,
                    ),
                  ],
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
