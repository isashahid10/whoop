import assert from 'node:assert/strict';
import { test } from 'node:test';

import { PushError, parsePush, statementsFor } from '../src/schema.ts';

const metricPush = (rows: unknown[][], days = ['2026-10-25']) => ({
  version: 1,
  tables: [{ table: 'metric', days, rows }],
});

test('accepts a well-formed push', () => {
  const body = parsePush(metricPush([['2026-10-25', 'rhr', 58.2], ['2026-10-25', 'hk_kcal_in', null]]));
  assert.equal(body.tables[0].rows.length, 2);
});

test('rejects an unknown table rather than writing anywhere it names', () => {
  assert.throws(() => parsePush({ version: 1, tables: [{ table: 'meta', days: [], rows: [] }] }), PushError);
  assert.throws(() => parsePush({ version: 1, tables: [{ table: 'metric; DROP TABLE metric', days: ['2026-10-25'], rows: [] }] }), PushError);
});

test('rejects a row whose day was not declared, which would survive the delete', () => {
  assert.throws(() => parsePush(metricPush([['2026-10-24', 'rhr', 58]])), /outside the pushed days/);
});

test('rejects rows of the wrong width and non-scalar values', () => {
  assert.throws(() => parsePush(metricPush([['2026-10-25', 'rhr']])), PushError);
  assert.throws(() => parsePush(metricPush([['2026-10-25', 'rhr', { v: 1 }]])), PushError);
});

test('rejects malformed days', () => {
  assert.throws(() => parsePush(metricPush([], ['25/10/2026'])), PushError);
});

test('a day-keyed table must say which days it replaces', () => {
  assert.throws(() => parsePush(metricPush([], [])), /needs the days/);
});

test('an empty day list entry clears that day', () => {
  const [del, ...rest] = statementsFor({ table: 'metric', days: ['2026-10-25'], rows: [] });
  assert.match(del.sql, /^DELETE FROM metric WHERE date IN/);
  assert.equal(rest.length, 0);
});

test('rows travel as one JSON parameter, so a push costs two queries per table', () => {
  const rows = Array.from({ length: 1000 }, (_, i) => ['2026-10-25', `k${i}`, i]);
  const stmts = statementsFor({ table: 'metric', days: ['2026-10-25'], rows });
  assert.equal(stmts.length, 2);
  assert.equal(stmts[1].params.length, 1);
  assert.deepEqual(JSON.parse(stmts[1].params[0] as string).length, 1000);
});

test('the baseline table is replaced wholesale', () => {
  const stmts = statementsFor({ table: 'baseline', days: [], rows: [['rolling', '{}', 1]] });
  assert.equal(stmts[0].sql, 'DELETE FROM baseline');
});
