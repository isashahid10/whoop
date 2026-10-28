import assert from 'node:assert/strict';
import { test } from 'node:test';

import { SqlGuardError, guardSql } from '../src/sqlguard.ts';

test('allows plain and CTE selects', () => {
  assert.ok(guardSql("SELECT date, value FROM metric WHERE key = 'rhr'"));
  assert.ok(guardSql('WITH d AS (SELECT * FROM metric) SELECT COUNT(*) FROM d;'));
});

test('keywords inside string literals do not trip the deny-list', () => {
  assert.ok(guardSql("SELECT * FROM lift_set WHERE indicator = 'drop' AND exercise_title LIKE '%delete%'"));
});

for (const sql of [
  'DELETE FROM metric',
  'UPDATE metric SET value = 0',
  'DROP TABLE metric',
  'SELECT 1; DELETE FROM metric',
  'WITH x AS (SELECT 1) DELETE FROM metric',
  'SELECT * FROM metric -- sneaky',
  'SELECT * FROM metric /* x */',
  'PRAGMA table_info(metric)',
  'SELECT * FROM sqlite_master',
  'SELECT * FROM "metric"',
  "SELECT 'unterminated",
  'INSERT INTO metric VALUES (1,2,3) RETURNING *',
]) {
  test(`refuses: ${sql}`, () => {
    assert.throws(() => guardSql(sql), SqlGuardError);
  });
}
