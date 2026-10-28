// The MCP tools Claude sees. Read-only, every one of them.
//
// Grounding rule carried over from the app's coach (CLAUDE.md §7): every answer
// should trace to rows returned here. So tools return the data plus enough
// context to read it honestly: units, coverage, and an explicit note when a
// range is empty instead of a silent [].

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { z } from 'zod';

import { HEADLINE, METRICS, describe } from './metrics';
import { QUERYABLE, SqlGuardError, guardSql } from './sqlguard';

const DATE = z.string().regex(/^\d{4}-\d{2}-\d{2}$/, 'YYYY-MM-DD');
const MAX_SQL_ROWS = 500;
const MAX_DAYS = 120;

type Row = Record<string, unknown>;

const json = (data: unknown) => ({
  content: [{ type: 'text' as const, text: JSON.stringify(data) }],
});
const fail = (message: string) => ({
  content: [{ type: 'text' as const, text: message }],
  isError: true,
});

function daysBetween(start: string, end: string): number {
  return Math.round((Date.parse(end) - Date.parse(start)) / 86_400_000) + 1;
}

/** Local calendar date for the user, not the Worker's UTC clock. */
function today(tz: string): string {
  return new Intl.DateTimeFormat('en-CA', { timeZone: tz }).format(new Date());
}

function shiftDay(day: string, delta: number): string {
  const d = new Date(`${day}T12:00:00Z`);
  d.setUTCDate(d.getUTCDate() + delta);
  return d.toISOString().slice(0, 10);
}

async function all(db: D1Database, sql: string, ...params: unknown[]): Promise<Row[]> {
  const res = await db.prepare(sql).bind(...params).all<Row>();
  return res.results ?? [];
}

/** Round floats so a payload of averages is not 70% trailing digits. */
function tidy(v: unknown): unknown {
  return typeof v === 'number' && !Number.isInteger(v) ? Math.round(v * 100) / 100 : v;
}

function mean(xs: number[]): number | null {
  return xs.length === 0 ? null : xs.reduce((a, b) => a + b, 0) / xs.length;
}

export function buildServer(env: { DB: D1Database; USER_TZ?: string }): McpServer {
  const db = env.DB;
  const tz = env.USER_TZ || 'Australia/Melbourne';
  const server = new McpServer(
    { name: 'whoop', version: '1.0.0' },
    {
      instructions:
        "Isa's personal health data: a WHOOP 4.0 band (recovery, HRV, sleep, strain), " +
        'Hevy resistance training, Apple Health (nutrition, weight, phone steps), ' +
        'weather and calendar load. Start with `overview`. Dates are local (YYYY-MM-DD, ' +
        `${tz}). Only state what the returned rows support; if a range is empty or ` +
        'coverage is thin, say so instead of guessing. Not medical advice.',
    },
  );
  const readOnly = { readOnlyHint: true, openWorldHint: false } as const;

  // ── overview ──────────────────────────────────────────────────────────────
  server.registerTool(
    'overview',
    {
      title: 'Overview',
      description:
        'Start here. How fresh the data is, what date ranges each source covers, the ' +
        'latest day, and 7-day vs 28-day averages for the headline metrics.',
      inputSchema: {},
      annotations: readOnly,
    },
    async () => {
      const now = today(tz);
      const from28 = shiftDay(now, -27);
      const from7 = shiftDay(now, -6);
      const [meta, coverage, lifts, recent] = await Promise.all([
        all(db, 'SELECT key, value FROM meta'),
        // substr, not LIKE: in LIKE '_' is a wildcard, so 'cal_%' also matched
        // the band's 'calories' and reported it as calendar coverage.
        all(db, `SELECT CASE WHEN substr(key, 1, 3) = 'hk_' THEN 'apple_health'
                  WHEN substr(key, 1, 3) = 'wx_' THEN 'weather'
                  WHEN substr(key, 1, 4) = 'cal_' THEN 'calendar' ELSE 'band' END AS source,
                  MIN(date) AS first, MAX(date) AS last, COUNT(DISTINCT date) AS days
                 FROM metric GROUP BY source`),
        all(db, 'SELECT MIN(day) AS first, MAX(day) AS last, COUNT(*) AS workouts FROM lift_session'),
        all(db, `SELECT date, key, value FROM metric
                 WHERE date BETWEEN ? AND ? AND key IN (SELECT value FROM json_each(?))`,
          from28, now, JSON.stringify(HEADLINE)),
      ]);

      const byKey = new Map<string, { date: string; value: number }[]>();
      let latestDay = '';
      for (const r of recent) {
        if (typeof r.value !== 'number') continue;
        const k = r.key as string;
        if (!byKey.has(k)) byKey.set(k, []);
        byKey.get(k)!.push({ date: r.date as string, value: r.value });
        if ((r.date as string) > latestDay) latestDay = r.date as string;
      }
      const headline: Row[] = [];
      for (const k of HEADLINE) {
        const pts = byKey.get(k) ?? [];
        if (pts.length === 0) continue;
        const info = describe(k);
        const last = pts.reduce((a, b) => (b.date > a.date ? b : a));
        headline.push({
          key: k,
          label: info?.label,
          unit: info?.unit,
          latest: tidy(last.value),
          latest_date: last.date,
          avg_7d: tidy(mean(pts.filter((p) => p.date >= from7).map((p) => p.value))),
          avg_28d: tidy(mean(pts.map((p) => p.value))),
          days_with_data_28d: pts.length,
        });
      }
      const metaMap = Object.fromEntries(meta.map((m) => [m.key, m.value]));
      return json({
        today: now,
        last_push: metaMap.last_push ?? null,
        app_version: metaMap.app_version ?? null,
        coverage: { metrics: coverage, hevy: lifts[0] ?? null },
        latest_day_with_data: latestDay || null,
        headline,
        note:
          headline.length === 0
            ? 'No headline data in the last 28 days. The phone may not have pushed recently.'
            : 'avg_7d and avg_28d only count days that have a value.',
      });
    },
  );

  // ── days ──────────────────────────────────────────────────────────────────
  server.registerTool(
    'get_days',
    {
      title: 'Daily metrics',
      description:
        'Per-day values for a date range (max 120 days). With no metrics given, returns ' +
        `the headline set: ${HEADLINE.join(', ')}. Name metrics to get others ` +
        '(see list_metrics), e.g. hk_carbs_g or deep_min.',
      inputSchema: {
        start_date: DATE,
        end_date: DATE,
        metrics: z.array(z.string()).max(40).optional(),
      },
      annotations: readOnly,
    },
    async ({ start_date, end_date, metrics }) => {
      if (end_date < start_date) return fail('end_date is before start_date.');
      if (daysBetween(start_date, end_date) > MAX_DAYS) {
        return fail(`At most ${MAX_DAYS} days per call. Use get_metric_series for one metric over a longer span.`);
      }
      const keys = metrics && metrics.length > 0 ? metrics : HEADLINE;
      const rows = await all(db,
        `SELECT date, key, value FROM metric WHERE date BETWEEN ? AND ?
         AND key IN (SELECT value FROM json_each(?)) ORDER BY date`,
        start_date, end_date, JSON.stringify(keys));
      const days = new Map<string, Row>();
      for (const r of rows) {
        const d = r.date as string;
        if (!days.has(d)) days.set(d, { date: d });
        days.get(d)![r.key as string] = tidy(r.value);
      }
      const units = Object.fromEntries(keys.map((k) => [k, describe(k)?.unit ?? 'unknown']));
      return json({
        units,
        days: [...days.values()],
        missing_days: daysBetween(start_date, end_date) - days.size,
        note: 'A metric absent from a day was not measured or not logged that day. Do not treat it as zero.',
      });
    },
  );

  server.registerTool(
    'get_metric_series',
    {
      title: 'One metric over time',
      description: 'Every recorded value of one metric between two dates, for trends over long spans.',
      inputSchema: { metric: z.string(), start_date: DATE, end_date: DATE },
      annotations: readOnly,
    },
    async ({ metric, start_date, end_date }) => {
      const rows = await all(db,
        'SELECT date, value FROM metric WHERE key = ? AND date BETWEEN ? AND ? ORDER BY date',
        metric, start_date, end_date);
      const values = rows.map((r) => r.value).filter((v): v is number => typeof v === 'number');
      return json({
        metric,
        info: describe(metric) ?? null,
        points: rows.map((r) => [r.date, tidy(r.value)]),
        summary: values.length
          ? { n: values.length, mean: tidy(mean(values)), min: Math.min(...values), max: Math.max(...values) }
          : null,
        note: rows.length === 0 ? `No values for ${metric} in this range. Check list_metrics for the exact key.` : undefined,
      });
    },
  );

  server.registerTool(
    'list_metrics',
    {
      title: 'Available metrics',
      description: 'Every metric key that has data, with its meaning, unit, source and date coverage.',
      inputSchema: { search: z.string().optional() },
      annotations: readOnly,
    },
    async ({ search }) => {
      const rows = await all(db,
        'SELECT key, COUNT(*) AS days, MIN(date) AS first, MAX(date) AS last FROM metric GROUP BY key ORDER BY key');
      const q = search?.toLowerCase();
      const out = rows
        .map((r) => ({
          key: r.key as string,
          days: r.days,
          first: r.first,
          last: r.last,
          ...(describe(r.key as string) ?? { label: null, note: 'Undocumented app metric.' }),
        }))
        .filter((r) => !q || `${r.key} ${r.label ?? ''}`.toLowerCase().includes(q));
      return json({ metrics: out, documented_but_absent: Object.keys(METRICS).filter((k) => !rows.some((r) => r.key === k)) });
    },
  );

  // ── sleep ─────────────────────────────────────────────────────────────────
  server.registerTool(
    'get_sleep',
    {
      title: 'One night of sleep',
      description:
        'Sleep stages for the night that ENDS on `date` (the app files a night under the ' +
        'morning it finishes), plus that day\'s sleep metrics.',
      inputSchema: { date: DATE },
      annotations: readOnly,
    },
    async ({ date }) => {
      const [stages, metrics] = await Promise.all([
        all(db, 'SELECT start_ts, end_ts, stage FROM sleep_stage WHERE date = ? ORDER BY start_ts', date),
        all(db, `SELECT key, value FROM metric WHERE date = ? AND key IN
                 ('tst_min','efficiency','sleep_score','sleep_score_coverage','deep_min','rem_min',
                  'light_min','waso_min','nap_min','resp_rate','rmssd','rhr','dip_pct','spo2','odi_per_hour')`, date),
      ]);
      const fmt = (ts: unknown) =>
        typeof ts === 'number'
          ? new Intl.DateTimeFormat('en-AU', { timeZone: tz, hour: '2-digit', minute: '2-digit', hour12: false })
              .format(new Date(ts * (ts < 1e12 ? 1000 : 1)))
          : ts;
      return json({
        date,
        metrics: Object.fromEntries(metrics.map((m) => [m.key, tidy(m.value)])),
        stages: stages.map((s) => ({ from: fmt(s.start_ts), to: fmt(s.end_ts), stage: s.stage })),
        note: stages.length === 0 ? 'No staged sleep recorded for this date.' : undefined,
      });
    },
  );

  // ── training ──────────────────────────────────────────────────────────────
  server.registerTool(
    'get_lift_sessions',
    {
      title: 'Hevy workouts',
      description: 'One row per Hevy workout: name, duration, total volume, sets, muscles hit.',
      inputSchema: { start_date: DATE, end_date: DATE },
      annotations: readOnly,
    },
    async ({ start_date, end_date }) => {
      const rows = await all(db,
        `SELECT day, name, round(duration_min) AS duration_min, total_volume_kg, set_count,
                exercise_count, muscle_groups, description
         FROM lift_session WHERE day BETWEEN ? AND ? ORDER BY start_ts`, start_date, end_date);
      return json({ workouts: rows, note: rows.length === 0 ? 'No Hevy workouts in this range.' : undefined });
    },
  );

  server.registerTool(
    'get_lifts',
    {
      title: 'Hevy sets',
      description:
        'Set-level Hevy data: exercise, weight, reps, RPE, volume. Filter by exercise ' +
        '(case-insensitive substring, e.g. "squat") and/or muscle group. Max 120 days.',
      inputSchema: {
        start_date: DATE,
        end_date: DATE,
        exercise: z.string().optional(),
        muscle_group: z.string().optional(),
      },
      annotations: readOnly,
    },
    async ({ start_date, end_date, exercise, muscle_group }) => {
      if (daysBetween(start_date, end_date) > MAX_DAYS) return fail(`At most ${MAX_DAYS} days per call.`);
      const rows = await all(db,
        `SELECT day, workout_name, exercise_title, muscle_group, indicator, set_idx,
                weight_kg, reps, rpe, volume_kg, duration_s, distance_m
         FROM lift_set
         WHERE day BETWEEN ? AND ?
           AND (? IS NULL OR lower(exercise_title) LIKE '%' || lower(?) || '%')
           AND (? IS NULL OR lower(muscle_group) LIKE '%' || lower(?) || '%')
         ORDER BY day, workout_id, exercise_idx, set_idx`,
        start_date, end_date, exercise ?? null, exercise ?? null, muscle_group ?? null, muscle_group ?? null);
      return json({
        sets: rows,
        note: rows.length === 0
          ? 'No matching sets. Exercise names are Hevy titles, e.g. "Squat (Barbell)".'
          : 'indicator marks warmup / drop / failure sets where Hevy recorded one.',
      });
    },
  );

  server.registerTool(
    'get_workouts',
    {
      title: 'Band workouts',
      description:
        'Sessions the band tracked or auto-detected (walks, padel, runs...) with strain, ' +
        'calories, max HR and heart-rate recovery. Hevy lifts also appear here as type strength.',
      inputSchema: { start_date: DATE, end_date: DATE },
      annotations: readOnly,
    },
    async ({ start_date, end_date }) => {
      const rows = await all(db,
        `SELECT date, type, source, status, duration_min, strain, calories, max_hr, hrr_bpm, steps, zone_min
         FROM workout WHERE date BETWEEN ? AND ? ORDER BY start_ts`, start_date, end_date);
      return json({ workouts: rows.map((r) => ({ ...r, strain: tidy(r.strain), calories: tidy(r.calories) })) });
    },
  );

  // ── baselines and alerts ─────────────────────────────────────────────────
  server.registerTool(
    'get_baselines',
    {
      title: 'Baselines and illness watch',
      description:
        "The app's rolling personal baselines (28-day RHR, HRV, readiness) and its " +
        'illness/anomaly watch state. Use to judge whether a day is unusual for Isa.',
      inputSchema: {},
      annotations: readOnly,
    },
    async () => {
      const rows = await all(db, 'SELECT key, payload, updated_at FROM baseline');
      const out: Row = {};
      for (const r of rows) {
        try {
          out[r.key as string] = JSON.parse(r.payload as string);
        } catch {
          out[r.key as string] = r.payload;
        }
      }
      return json({ baselines: out, note: rows.length === 0 ? 'No baselines pushed yet.' : undefined });
    },
  );

  server.registerTool(
    'get_insights',
    {
      title: 'App alerts',
      description: "Alerts and insights the app itself raised (illness watch, anomalies, recovery).",
      inputSchema: { start_date: DATE, end_date: DATE },
      annotations: readOnly,
    },
    async ({ start_date, end_date }) => {
      const rows = await all(db,
        'SELECT date, kind, title, body FROM insight WHERE date BETWEEN ? AND ? ORDER BY created_at',
        start_date, end_date);
      return json({ insights: rows });
    },
  );

  // ── escape hatch ─────────────────────────────────────────────────────────
  server.registerTool(
    'run_sql',
    {
      title: 'Read-only SQL',
      description:
        `One read-only SELECT over the tables ${QUERYABLE.join(', ')} (SQLite). ` +
        'metric(date,key,value) is long-form: pivot with MAX(CASE WHEN key=... THEN value END). ' +
        'lift_set(day,workout_id,workout_name,exercise_idx,set_idx,exercise_title,muscle_group,' +
        'equipment,exercise_type,indicator,weight_kg,reps,rpe,volume_kg,distance_m,duration_s). ' +
        'lift_session(day,workout_id,name,description,start_ts,end_ts,duration_min,total_volume_kg,' +
        'set_count,exercise_count,muscle_groups). workout(date,id,start_ts,end_ts,type,status,' +
        'calories,strain,max_hr,duration_min,steps,hrr_bpm,source,zone_min). ' +
        'sleep_stage(date,start_ts,end_ts,stage). Use for joins the other tools cannot do, ' +
        `e.g. protein vs next-day readiness. At most ${MAX_SQL_ROWS} rows come back.`,
      inputSchema: { sql: z.string() },
      annotations: readOnly,
    },
    async ({ sql }) => {
      let safe: string;
      try {
        safe = guardSql(sql);
      } catch (e) {
        if (e instanceof SqlGuardError) return fail(e.message);
        throw e;
      }
      try {
        const rows = await all(db, safe);
        return json({
          rows: rows.slice(0, MAX_SQL_ROWS).map((r) =>
            Object.fromEntries(Object.entries(r).map(([k, v]) => [k, tidy(v)]))),
          truncated: rows.length > MAX_SQL_ROWS,
        });
      } catch (e) {
        return fail(`SQL error: ${(e as Error).message}`);
      }
    },
  );

  return server;
}
