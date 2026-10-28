-- The connector's copy of the phone's data. The phone is the source of truth:
-- every table here is overwritten day-by-day from the app's coach views
-- (lib/data/db.dart _ensureCoachViews), so nothing in D1 is ever edited in place
-- and the whole database can be rebuilt by a full re-push from the app.

-- Every daily scalar: band-derived (rhr, rmssd, readiness, strain, sleep...),
-- Apple Health (hk_*), weather (wx_*) and calendar counts (cal_*).
-- Mirrors metric_series / v_metric.
CREATE TABLE metric (
  date  TEXT NOT NULL,
  key   TEXT NOT NULL,
  value REAL,
  PRIMARY KEY (date, key)
);
CREATE INDEX idx_metric_key_date ON metric(key, date);

-- One row per Hevy SET. Mirrors v_lifts.
CREATE TABLE lift_set (
  day            TEXT NOT NULL,
  workout_id     TEXT NOT NULL,
  workout_name   TEXT,
  exercise_idx   INTEGER NOT NULL,
  set_idx        INTEGER NOT NULL,
  exercise_title TEXT NOT NULL,
  muscle_group   TEXT,
  equipment      TEXT,
  exercise_type  TEXT,
  indicator      TEXT,
  weight_kg      REAL,
  reps           INTEGER,
  rpe            REAL,
  volume_kg      REAL,
  distance_m     REAL,
  duration_s     REAL
);
CREATE INDEX idx_lift_set_day ON lift_set(day);
CREATE INDEX idx_lift_set_ex ON lift_set(exercise_title, day);

-- One row per Hevy WORKOUT. Mirrors v_lift_sessions.
CREATE TABLE lift_session (
  day             TEXT NOT NULL,
  workout_id      TEXT NOT NULL,
  name            TEXT,
  description     TEXT,
  start_ts        INTEGER,
  end_ts          INTEGER,
  duration_min    REAL,
  total_volume_kg REAL,
  set_count       INTEGER,
  exercise_count  INTEGER,
  muscle_groups   TEXT
);
CREATE INDEX idx_lift_session_day ON lift_session(day);

-- Band-tracked and auto-detected sessions. Mirrors v_sessions.
CREATE TABLE workout (
  date         TEXT NOT NULL,
  id           TEXT NOT NULL,
  start_ts     INTEGER,
  end_ts       INTEGER,
  type         TEXT,
  status       TEXT,
  calories     REAL,
  strain       REAL,
  max_hr       INTEGER,
  duration_min REAL,
  steps        INTEGER,
  hrr_bpm      REAL,
  source       TEXT,
  zone_min     TEXT
);
CREATE INDEX idx_workout_date ON workout(date);

-- Sleep stage segments per night. Mirrors v_hypnogram.
CREATE TABLE sleep_stage (
  date     TEXT NOT NULL,
  start_ts INTEGER,
  end_ts   INTEGER,
  stage    TEXT
);
CREATE INDEX idx_sleep_stage_date ON sleep_stage(date);

-- The app's own alerts and insights. Mirrors v_insights.
CREATE TABLE insight (
  date       TEXT NOT NULL,
  id         TEXT NOT NULL,
  kind       TEXT,
  title      TEXT,
  body       TEXT,
  created_at INTEGER
);
CREATE INDEX idx_insight_date ON insight(date);

-- Rolling baselines and the illness/anomaly watch, as the app's JSON payloads.
-- Not day-keyed: replaced wholesale on every push that carries them.
CREATE TABLE baseline (
  key        TEXT PRIMARY KEY,
  payload    TEXT NOT NULL,
  updated_at INTEGER
);

-- Push bookkeeping, so the tools can say how fresh the data is.
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT
);
