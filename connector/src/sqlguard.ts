// Read-only gate for the run_sql tool.
//
// D1 has no read-only connection, so this is the only thing between Claude and
// a DELETE. The stakes are bounded (every table is a copy the phone can re-push
// in full), but a tool that can silently wipe the data it answers from is still
// a bad tool. Same posture as the app's coach guard (lib/coach/coach_db.dart):
// one statement, SELECT only, no comments, an explicit deny-list.
//
// Pure module: runs under `node --test`.

export class SqlGuardError extends Error {}

const DENY = [
  'insert', 'update', 'delete', 'drop', 'alter', 'create', 'replace',
  'attach', 'detach', 'pragma', 'vacuum', 'reindex', 'analyze', 'begin',
  'commit', 'rollback', 'savepoint', 'release', 'returning',
];

export const QUERYABLE = [
  'metric', 'lift_set', 'lift_session', 'workout', 'sleep_stage', 'insight',
  'baseline', 'meta',
];

/** Blank out string literals so their contents cannot trip the keyword scan
 *  ("drop set" is a lifting term, not DDL). Quoted identifiers are refused. */
function stripStrings(sql: string): string {
  let out = '';
  let i = 0;
  while (i < sql.length) {
    const c = sql[i];
    if (c === '"' || c === '`' || c === '[') {
      throw new SqlGuardError('Quoted identifiers are not allowed; use bare table and column names.');
    }
    if (c === "'") {
      out += "''";
      i++;
      while (i < sql.length) {
        if (sql[i] === "'" && sql[i + 1] === "'") {
          i += 2;
          continue;
        }
        if (sql[i] === "'") break;
        i++;
      }
      if (i >= sql.length) throw new SqlGuardError('Unterminated string literal.');
      i++;
      continue;
    }
    out += c;
    i++;
  }
  return out;
}

/** Returns the statement to run, or throws [SqlGuardError] saying why not. */
export function guardSql(input: string): string {
  let sql = input.trim();
  if (sql.length === 0) throw new SqlGuardError('Empty query.');
  if (sql.length > 4000) throw new SqlGuardError('Query too long (4000 characters max).');
  if (sql.endsWith(';')) sql = sql.slice(0, -1).trimEnd();

  const bare = stripStrings(sql);
  if (bare.includes('--') || bare.includes('/*')) throw new SqlGuardError('Comments are not allowed.');
  if (bare.includes(';')) throw new SqlGuardError('Only one statement is allowed.');

  const lower = bare.toLowerCase();
  if (!/^(select|with)\b/.test(lower)) throw new SqlGuardError('Only SELECT (or WITH ... SELECT) is allowed.');
  for (const word of DENY) {
    if (new RegExp(`\\b${word}\\b`).test(lower)) {
      throw new SqlGuardError(`Disallowed keyword: ${word.toUpperCase()}.`);
    }
  }
  if (/\bsqlite_|\b_cf_|\bd1_/.test(lower)) {
    throw new SqlGuardError(`Internal tables are not queryable. Tables: ${QUERYABLE.join(', ')}.`);
  }
  return sql;
}
