// MetricScreen — the ONE reusable screen every metric (Sleep/Heart/Body/…)
// plugs into, rebuilt on the design language. AppScaffold chrome (correct back
// button for free), a full-width SegmentedControl period switcher
// (Today·Week·Month·3M), and the over-time view as a [TrendBoard]: a BentoTile
// hero with a BigStat average + delta and clean tappable bars. Inline drill:
// tap a month bar → its weeks expand below → tap a week → its 7 days → tap a
// day → the metric's rich detail. Explanations live behind the (i).

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../../state/prefs.dart';
import '../design/design.dart';
import 'metric_row.dart' show infoFor;

typedef DetailBuilder = Widget Function(BuildContext context);
typedef DayDetailBuilder = Widget Function(BuildContext context, String date);

const _tabs = ['Today', 'Week', 'Month', '3M'];
const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

class MetricScreen extends StatefulWidget {
  final String title;
  final String metric; // /trend key for the bars
  final OsIcon icon;

  /// Illustrated domain icon — shown (over [icon]) on the trend board header.
  final Color accent;
  final String Function(double v)? valueFmt;
  final DetailBuilder todayDetail;
  final DayDetailBuilder dayDetail;
  final Widget? action; // optional top-right action (e.g. AI coach button)
  const MetricScreen({
    super.key,
    required this.title,
    required this.metric,
    required this.icon,
    required this.accent,
    required this.todayDetail,
    required this.dayDetail,
    this.valueFmt,
    this.action,
  });

  @override
  State<MetricScreen> createState() => _MetricScreenState();
}

class _MetricScreenState extends State<MetricScreen> {
  // Per-metric range toggle (Today/Week/Month/3M) — Sleep, Heart, Body etc.
  // each remember their own scale independently across launches.
  late int _tab =
      Prefs.getInt(Prefs.metricTab(widget.metric), 0).clamp(0, _tabs.length - 1);
  int _refresh = 0; // bumped on pull-to-refresh → woven into child keys

  Future<void> _onRefresh() async {
    setState(() => _refresh++);
    await Future<void>.delayed(const Duration(milliseconds: 600));
  }

  @override
  Widget build(BuildContext context) {
    final scale = _tab == 1 ? 'week' : _tab == 2 ? 'month' : 'quarter';
    return AppScaffold(
      title: widget.title,
      actions: [if (widget.action != null) widget.action!],
      header: SegmentedControl(
        options: _tabs,
        index: _tab,
        expanded: true,
        onChanged: (i) {
          setState(() => _tab = i);
          Prefs.setInt(Prefs.metricTab(widget.metric), i);
        },
      ),
      body: RefreshIndicator(
        onRefresh: _onRefresh,
        color: widget.accent,
        child: ListView(
          physics: const BouncingScrollPhysics(
            parent: AlwaysScrollableScrollPhysics(),
          ),
          padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x3, Sp.screen, 120),
          children: [
            if (_tab == 0)
              KeyedSubtree(
                key: ValueKey('today-$_refresh'),
                child: widget.todayDetail(context),
              )
            else
              _DrillLevel(
                key: ValueKey('$scale-$_refresh-root'),
                title: widget.title,
                icon: widget.icon,
                metric: widget.metric,
                scale: scale,
                anchor: null,
                accent: widget.accent,
                valueFmt: widget.valueFmt,
                dayDetail: widget.dayDetail,
              ),
          ],
        ),
      ),
    );
  }
}

/// One level of the drill (a /trend call). Fetches, then renders a pure
/// [TrendBoard]; tapping a bar expands a finer level (quarter→month→week) or,
/// at week, the day detail — inline below the board.
class _DrillLevel extends StatefulWidget {
  final String title;
  final OsIcon icon;
  final String metric;
  final String scale; // 'week' | 'month' | 'quarter'
  final String? anchor;
  final Color accent;
  final String Function(double v)? valueFmt;
  final DayDetailBuilder dayDetail;
  const _DrillLevel({
    super.key,
    required this.title,
    required this.icon,
    required this.metric,
    required this.scale,
    required this.anchor,
    required this.accent,
    required this.dayDetail,
    this.valueFmt,
  });

  @override
  State<_DrillLevel> createState() => _DrillLevelState();
}

class _DrillLevelState extends State<_DrillLevel> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  int? _selected;
  Widget? _child;
  String? _childLabel;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = context.read<AppState>().repo;
    if (api == null) return;
    try {
      final d = await api.getTrend(widget.metric,
          scale: widget.scale, anchor: widget.anchor);
      if (!mounted) return;
      setState(() { _data = d; _loading = false; });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  void _tap(int i, List<dynamic> buckets) {
    if (i >= buckets.length) return;
    final b = buckets[i] as Map<String, dynamic>;
    final endTs = (b['t_end'] as num?)?.toInt();
    if (endTs == null) return;
    final lastDay =
        DateTime.fromMillisecondsSinceEpoch((endTs - 86400) * 1000, isUtc: true)
            .toIso8601String()
            .substring(0, 10);
    setState(() {
      if (_selected == i) { _selected = null; _child = null; return; }
      _selected = i;
      _childLabel = trendBarLabel(widget.scale, i, b);
      if (widget.scale == 'week') {
        final d = DateTime.fromMillisecondsSinceEpoch(
            (endTs - 86400) * 1000, isUtc: true);
        _childLabel = '${_wd[(d.weekday - 1) % 7]}, ${_mon[d.month - 1]} ${d.day}';
        _child = KeyedSubtree(
            key: ValueKey('day-$lastDay'),
            child: widget.dayDetail(context, lastDay));
      } else {
        _child = _DrillLevel(
          key: ValueKey('${widget.scale}-$lastDay'),
          title: widget.title, icon: widget.icon,
          metric: widget.metric,
          scale: widget.scale == 'quarter' ? 'month' : 'week',
          anchor: lastDay, accent: widget.accent,
          valueFmt: widget.valueFmt, dayDetail: widget.dayDetail,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Skeleton.chart(height: 220);
    final buckets = (_data?['buckets'] as List?) ?? const [];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TrendBoard(
          data: _data ?? const {},
          title: widget.title,
          icon: widget.icon,
          metric: widget.metric,
          scale: widget.scale,
          accent: widget.accent,
          valueFmt: widget.valueFmt,
          selected: _selected,
          onTapBar: (i) => _tap(i, buckets),
        ).dsEnter(),
        if (_child != null) ...[
          const SizedBox(height: Sp.x6),
          SectionHeader(_childLabel ?? 'Detail'),
          _child!,
        ],
      ],
    );
  }
}

/// Bar label for a /trend bucket at a given scale ('week' → weekday initials,
/// 'month' → the window's END date, 'quarter' → month names). Pure; shared
/// with tests.
///
/// 'month' buckets are NOT calendar weeks — the repository builds four ROLLING
/// 7-day windows ending at the anchor day, so 'W1…W4' was a lie (W1 of a month
/// it may not even overlap). Labelling by the window's last day is the only
/// honest short form.
String trendBarLabel(String scale, int i, Map b) {
  final ts = (b['t_start'] as num?)?.toInt();
  if (ts == null) return b['label']?.toString() ?? '';
  final d = DateTime.fromMillisecondsSinceEpoch(ts * 1000, isUtc: true);
  switch (scale) {
    case 'week':
      return _wd[(d.weekday - 1) % 7];
    case 'month':
      final end = trendBucketEnd(b) ?? d.add(const Duration(days: 6));
      return '${_mon[end.month - 1]} ${end.day}';
    default: // quarter → month
      return _mon[d.month - 1];
  }
}

/// Last day (inclusive, UTC) covered by a /trend bucket. `t_end` is exclusive.
DateTime? trendBucketEnd(Map b) {
  final end = (b['t_end'] as num?)?.toInt();
  if (end == null) return null;
  return DateTime.fromMillisecondsSinceEpoch((end - 86400) * 1000, isUtc: true);
}

/// The value a /trend bucket actually carries, or NULL when the repository
/// marked the bucket absent.
///
/// The repository writes `{'value': v ?? 0.0, 'has': v != null}` — the 0.0 is
/// pure padding and `has` is the only truth. Reading `value` alone turns every
/// unworn day into a measured zero. Payloads that predate `has` fall back to
/// value-presence.
double? trendBucketValue(Map b) {
  final v = (b['value'] as num?)?.toDouble();
  if (b.containsKey('has')) return b['has'] == true ? v : null;
  return v;
}

/// Display (label, unit) for a trend series, correcting the repository's
/// nominal naming where the stored series does not contain what the name says.
///
/// `spo2` is the only such series: the on-device 1 Hz pipeline writes
/// `scalars['spo2'] = null` and `odi_per_hour = null`, so nothing local ever
/// populates it. Its ONLY writer is the cloud importer, which stores the
/// vendor's `spo2_idx` — a relative saturation index in the 90s, not a dip
/// rate. Presenting it as "95.3 dips/h" is a category error on top of a
/// three-orders-of-magnitude wrong number.
({String label, String unit}) trendDisplay(
  String metric,
  String label,
  String unit,
) {
  if (metric == 'spo2') {
    return (label: 'imported oxygen index', unit: '');
  }
  return (label: label, unit: unit);
}

/// Metrics where a DOWNWARD move is the good one (for delta-chip colouring).
bool trendGoodIsUp(String metric) => switch (metric) {
  'resting_hr' || 'stress' || 'spo2' || 'debt' => false,
  _ => true,
};

/// TrendBoard — the pure over-time hero of the rebuilt MetricScreen: one
/// BentoTile with a whispered header + (i) definition, a BigStat average with
/// its week-over-week delta, and the period's tappable bars underneath.
/// Honest: an all-empty period says so instead of drawing a flat floor.
class TrendBoard extends StatelessWidget {
  /// The raw /trend payload ({buckets, unit, label, summary}).
  final Map<String, dynamic> data;
  final String title;
  final OsIcon icon;
  final String metric;
  final String scale; // 'week' | 'month' | 'quarter'
  final Color accent;
  final String Function(double v)? valueFmt;
  final int? selected;
  final ValueChanged<int>? onTapBar;

  const TrendBoard({
    super.key,
    required this.data,
    required this.title,
    required this.icon,
    required this.metric,
    required this.scale,
    required this.accent,
    this.valueFmt,
    this.selected,
    this.onTapBar,
  });

  /// Generic name for the window's LENGTH. Never "this week"/"this month":
  /// with no explicit anchor the repository anchors on the LAST DAY WITH DATA,
  /// so after five unsynced days "this week" is a fortnight ago. [_periodOf]
  /// prefers the buckets' real dates; this is only the fallback.
  String get _period => scale == 'week'
      ? '7 days'
      : scale == 'month'
      ? '4 weeks'
      : '3 months';

  /// The window the bars ACTUALLY cover, read off the buckets ('Jul 15–21').
  String _periodOf(List buckets) {
    if (buckets.isEmpty) return _period;
    final firstTs = ((buckets.first as Map)['t_start'] as num?)?.toInt();
    final last = trendBucketEnd(buckets.last as Map);
    if (firstTs == null || last == null) return _period;
    final start = DateTime.fromMillisecondsSinceEpoch(
      firstTs * 1000,
      isUtc: true,
    );
    final s = '${_mon[start.month - 1]} ${start.day}';
    final e = start.month == last.month
        ? '${last.day}'
        : '${_mon[last.month - 1]} ${last.day}';
    return '$s–$e';
  }

  String _fmtAvg(num v) {
    // Sleep + wear avgs come in minutes → show as Hh Mm in the hero.
    if (metric == 'sleep' || metric == 'wear') {
      final m = v.round();
      return '${m ~/ 60}h ${(m % 60).toString().padLeft(2, '0')}m';
    }
    final d = v.toDouble();
    return d == d.roundToDouble() ? d.toStringAsFixed(0) : d.toStringAsFixed(1);
  }

  @override
  Widget build(BuildContext context) {
    final buckets = (data['buckets'] as List?) ?? const [];
    final display = trendDisplay(
      metric,
      data['label']?.toString() ?? title,
      data['unit']?.toString() ?? '',
    );
    final unit = display.unit;
    final label = display.label;
    final summary = (data['summary'] as Map?)?.cast<String, dynamic>();
    // NULL for an absent bucket — see [trendBucketValue]. Coercing to 0.0 here
    // is what made an unworn Tuesday draw a real bar (and, for oxygen, print a
    // literal "0" SpO₂) under a tooltip promising "empty periods stay empty".
    final List<double?> values = [
      for (final b in buckets) trendBucketValue(b as Map),
    ];
    final labels = [
      for (var i = 0; i < buckets.length; i++)
        trendBarLabel(scale, i, buckets[i] as Map),
    ];
    // "No data" means NO bucket carried a measurement — not "every measurement
    // happened to be zero", which is itself a finding worth drawing.
    final noData = values.every((v) => v == null);
    final avg = summary?['avg'] as num?;
    final delta = summary?['delta_vs_prev'] as num?;
    final met = summary?['met_count'] as num?;
    final total = summary?['total'] as num?;
    final showUnit = unit.isNotEmpty && metric != 'sleep' && metric != 'wear';
    final info = infoFor(metric);
    final period = _periodOf(buckets);
    // /trend's `delta_vs_prev` is `avg - prevAvg` — an ABSOLUTE difference in
    // the metric's own unit. Sleep/wear averages travel in minutes even though
    // their display unit is 'h', so the chip must say 'min'.
    final deltaUnit = (metric == 'sleep' || metric == 'wear') ? 'min' : unit;

    return BentoTile(
      accent: accent,
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          TileHeader(
            '$label · $period',
            icon: icon,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (met != null && total != null && total > 0)
                  StatusChip('${met.toInt()}/${total.toInt()} met',
                      tone: ChipTone.neutral),
                InfoDot(
                  title: title,
                  body: info ??
                      'Your $label, averaged across the last $_period. Tap a '
                          'bar to drill into a finer period.',
                  methodNote: metric == 'spo2'
                      ? 'This series is the IMPORTED vendor oxygen index — a '
                            'relative saturation number, not a dip rate and '
                            'not an absolute SpO₂. On-device decoding writes '
                            'nothing here. Bars show each period’s value; '
                            'periods with no measurement stay empty.'
                      : 'Bars show each period’s value; periods with no '
                            'measurement stay empty — a gap is a gap, never '
                            'a zero.',
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x2),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Flexible(
                child: BigStat(
                  value: avg == null ? null : _fmtAvg(avg),
                  unit: showUnit ? unit : null,
                  caption: 'average',
                  size: BigStatSize.xl,
                ),
              ),
              if (delta != null && delta != 0) ...[
                const SizedBox(width: Sp.x3),
                BaselineDeltaChip(
                  delta,
                  unit: deltaUnit,
                  goodIsUp: trendGoodIsUp(metric),
                  showVsNormal: false,
                  vsLabel: 'vs prev',
                ),
              ],
            ],
          ),
          const SizedBox(height: Sp.x5),
          if (noData)
            SizedBox(
              height: 120,
              child: Center(
                child: Text('No data in this period',
                    style: AppText.captionMuted),
              ),
            )
          else ...[
            LabeledBars(
              values: values,
              labels: labels,
              color: accent,
              highlight: selected,
              valueFmt: valueFmt,
              onTapBar: onTapBar,
            ),
            const SizedBox(height: Sp.x3),
            Center(
              child: Text(
                scale == 'week'
                    ? 'Tap a day for the full breakdown'
                    : 'Tap a bar to drill in',
                style: AppText.captionMuted,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
