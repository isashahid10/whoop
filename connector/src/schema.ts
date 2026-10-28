// The upload contract between the app (lib/connector/connector_sync.dart) and
// this Worker. Both sides list the same columns in the same order; a row
// travels as a bare JSON array to keep pushes small.
//
// Pure module: no Cloudflare imports, so it runs under `node --test`.

export interface TableSpec {
  /** Column that holds the local calendar day. Uploads replace whole days. */
  dayColumn: string | null;
  columns: readonly string[];
}

export const TABLES = {
  metric: { dayColumn: 'date', columns: ['date', 'key', 'value'] },
  lift_set: {
    dayColumn: 'day',
    columns: [
      'day', 'workout_id', 'workout_name', 'exercise_idx', 'set_idx',
      'exercise_title', 'muscle_group', 'equipment', 'exercise_type',
      'indicator', 'weight_kg', 'reps', 'rpe', 'volume_kg', 'distance_m',
      'duration_s',
    ],
  },
  lift_session: {
    dayColumn: 'day',
    columns: [
      'day', 'workout_id', 'name', 'description', 'start_ts', 'end_ts',
      'duration_min', 'total_volume_kg', 'set_count', 'exercise_count',
      'muscle_groups',
    ],
  },
  workout: {
    dayColumn: 'date',
    columns: [
      'date', 'id', 'start_ts', 'end_ts', 'type', 'status', 'calories',
      'strain', 'max_hr', 'duration_min', 'steps', 'hrr_bpm', 'source',
      'zone_min',
    ],
  },
  sleep_stage: { dayColumn: 'date', columns: ['date', 'start_ts', 'end_ts', 'stage'] },
  insight: {
    dayColumn: 'date',
    columns: ['date', 'id', 'kind', 'title', 'body', 'created_at'],
  },
  baseline: { dayColumn: null, columns: ['key', 'payload', 'updated_at'] },
} as const satisfies Record<string, TableSpec>;

export type TableName = keyof typeof TABLES;

/** One table's slice of a push: these days are replaced by these rows. */
export interface TablePush {
  table: TableName;
  /** Days being replaced. A day listed here with no rows is cleared. */
  days: string[];
  rows: unknown[][];
}

export interface PushBody {
  version: 1;
  app_version?: string;
  tables: TablePush[];
}

const DAY = /^\d{4}-\d{2}-\d{2}$/;

/** Per-push ceilings. Each push becomes one D1 batch, so these bound its size. */
export const MAX_ROWS_PER_PUSH = 5000;
export const MAX_DAYS_PER_TABLE = 400;

export class PushError extends Error {}

/**
 * Validate an upload. Throws [PushError] on anything malformed rather than
 * writing part of it: a half-applied push would leave a day with some of its
 * rows deleted and none re-inserted.
 */
export function parsePush(raw: unknown): PushBody {
  if (typeof raw !== 'object' || raw === null) throw new PushError('body must be an object');
  const body = raw as Record<string, unknown>;
  if (body.version !== 1) throw new PushError('unsupported version');
  if (!Array.isArray(body.tables)) throw new PushError('tables must be an array');

  let totalRows = 0;
  const seen = new Set<string>();
  const tables: TablePush[] = [];
  for (const t of body.tables) {
    if (typeof t !== 'object' || t === null) throw new PushError('table entry must be an object');
    const entry = t as Record<string, unknown>;
    const name = entry.table;
    if (typeof name !== 'string' || !(name in TABLES)) {
      throw new PushError(`unknown table: ${String(name)}`);
    }
    if (seen.has(name)) throw new PushError(`table listed twice: ${name}`);
    seen.add(name);
    const spec: TableSpec = TABLES[name as TableName];

    const days = entry.days ?? [];
    if (!Array.isArray(days) || days.length > MAX_DAYS_PER_TABLE) {
      throw new PushError(`${name}: days must be an array of at most ${MAX_DAYS_PER_TABLE}`);
    }
    for (const d of days) {
      if (typeof d !== 'string' || !DAY.test(d)) throw new PushError(`${name}: bad day ${String(d)}`);
    }
    if (spec.dayColumn !== null && days.length === 0) {
      throw new PushError(`${name}: a day-keyed table needs the days it replaces`);
    }

    const rows = entry.rows;
    if (!Array.isArray(rows)) throw new PushError(`${name}: rows must be an array`);
    totalRows += rows.length;
    if (totalRows > MAX_ROWS_PER_PUSH) throw new PushError(`more than ${MAX_ROWS_PER_PUSH} rows in one push`);

    const daySet = new Set(days as string[]);
    const dayIdx = spec.dayColumn === null ? -1 : spec.columns.indexOf(spec.dayColumn);
    for (const r of rows) {
      if (!Array.isArray(r) || r.length !== spec.columns.length) {
        throw new PushError(`${name}: each row needs ${spec.columns.length} values`);
      }
      for (const v of r) {
        if (v !== null && typeof v !== 'string' && typeof v !== 'number') {
          throw new PushError(`${name}: values must be strings, numbers or null`);
        }
      }
      // A row outside the declared days would survive the delete and then be
      // duplicated by the next push of its own day.
      if (dayIdx >= 0 && !daySet.has(r[dayIdx] as string)) {
        throw new PushError(`${name}: row for ${String(r[dayIdx])} is outside the pushed days`);
      }
    }
    tables.push({ table: name as TableName, days: days as string[], rows: rows as unknown[][] });
  }
  return {
    version: 1,
    app_version: typeof body.app_version === 'string' ? body.app_version.slice(0, 40) : undefined,
    tables,
  };
}

/**
 * The two statements that apply one table's push: clear the days, then insert
 * the rows. Rows go in as ONE JSON parameter expanded by json_each, so a push
 * costs two D1 queries per table however many rows it carries (the free plan
 * caps queries per invocation, not rows).
 */
export function statementsFor(push: TablePush): { sql: string; params: unknown[] }[] {
  const spec: TableSpec = TABLES[push.table];
  const out: { sql: string; params: unknown[] }[] = [];
  if (spec.dayColumn === null) {
    out.push({ sql: `DELETE FROM ${push.table}`, params: [] });
  } else {
    out.push({
      sql: `DELETE FROM ${push.table} WHERE ${spec.dayColumn} IN (SELECT value FROM json_each(?))`,
      params: [JSON.stringify(push.days)],
    });
  }
  if (push.rows.length > 0) {
    const cols = spec.columns.join(', ');
    const picks = spec.columns.map((_, i) => `json_extract(value, '$[${i}]')`).join(', ');
    out.push({
      sql: `INSERT OR REPLACE INTO ${push.table} (${cols}) SELECT ${picks} FROM json_each(?)`,
      params: [JSON.stringify(push.rows)],
    });
  }
  return out;
}
