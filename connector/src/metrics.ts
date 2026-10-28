// What each metric key means, so Claude reads "rmssd 48" as HRV in ms and not a
// guess. Keys come from the app's metric_series. Descriptions are taken from the
// app's derivation code and view comments; where the app does not define a key
// precisely, the entry says so rather than inventing a meaning.
//
// Pure module: runs under `node --test`.

export interface MetricInfo {
  label: string;
  unit: string;
  source: 'band' | 'apple_health' | 'weather' | 'calendar';
  note?: string;
}

const band = (label: string, unit: string, note?: string): MetricInfo => ({ label, unit, source: 'band', note });
const hk = (label: string, unit: string, note?: string): MetricInfo => ({ label, unit, source: 'apple_health', note });

export const METRICS: Record<string, MetricInfo> = {
  // ── recovery (band, overnight) ──
  readiness: band('Readiness / recovery', '0-100', 'Overnight HRV and resting HR against a rolling personal baseline.'),
  rhr: band('Resting heart rate', 'bpm', 'Overnight.'),
  rmssd: band('HRV (RMSSD)', 'ms', 'Overnight. The main HRV figure.'),
  ln_rmssd: band('HRV (ln RMSSD)', 'ln(ms)'),
  sdnn: band('HRV (SDNN)', 'ms'),
  hrv_cv: band('HRV night-to-night variability', '%'),
  lf_hf: band('HRV LF/HF ratio', 'ratio', 'Frequency-domain HRV balance.'),
  resp_rate: band('Respiratory rate', 'breaths/min', 'During sleep.'),
  brv_cv: band('Breathing-rate variability', 'CV'),
  skin_temp_z: band('Skin temperature deviation', 'z-score', 'Versus personal baseline. Raw sensor units are not degrees.'),
  skin_temp_adc: band('Skin temperature (raw sensor)', 'ADC units', 'Uncalibrated. Use skin_temp_z instead.'),
  spo2: band('Blood oxygen', '%'),
  odi_per_hour: band('Oxygen desaturation index', 'events/hour'),
  dip_pct: band('Nocturnal heart rate dip', '%', 'How far HR falls overnight versus daytime.'),
  irregular_rhythm_flag: band('Irregular rhythm screen', '0/1', 'A screen, not a diagnosis.'),
  stress: band('Stress', '0-100', 'Baevsky stress index, windowed median.'),
  // ── sleep (band) ──
  sleep_score: band('Sleep score', '0-100'),
  sleep_score_coverage: band('Sleep score coverage', '0-1', 'Share of the score that was actually measured. Low means a partial figure.'),
  sleep_confidence: band('Sleep staging confidence', '0-1'),
  tst_min: band('Total sleep time', 'min'),
  efficiency: band('Sleep efficiency', '%'),
  waso_min: band('Awake after sleep onset', 'min'),
  deep_min: band('Deep sleep', 'min'),
  rem_min: band('REM sleep', 'min'),
  light_min: band('Light sleep', 'min'),
  nap_min: band('Naps', 'min'),
  cpc_ratio: band('Cardiopulmonary coupling ratio', 'ratio', 'Sleep stability proxy.'),
  // ── load and activity (band) ──
  strain: band('Strain', '0-21', 'Day cardiovascular load, WHOOP-style scale.'),
  strain_effort: band('Effort strain', '0-100', 'Zone-sum effort score beside the 0-21 headline.'),
  trimp: band('Training impulse (TRIMP)', 'a.u.', 'Raw load behind strain.'),
  steps: band('Steps (band estimate)', 'steps', 'Estimated from wrist motion. Compare hk_steps for the phone count.'),
  active_min: band('Active minutes', 'min'),
  calories: band('Active energy', 'kcal'),
  calories_total: band('Total energy expenditure', 'kcal'),
  hrr_bpm: band('Heart rate recovery', 'bpm', 'Drop after an effort bout.'),
  worn_min: band('Band worn', 'min'),
  dyn_p90: band('Motion amplitude (p90)', 'g', 'Internal baseline input for step estimation.'),
  // ── Apple Health ──
  hk_kcal_in: hk('Calories eaten', 'kcal', 'From the food logger via Apple Health. Absent on days nothing was logged.'),
  hk_protein_g: hk('Protein', 'g'),
  hk_carbs_g: hk('Carbohydrate', 'g'),
  hk_fat_g: hk('Fat', 'g'),
  hk_fiber_g: hk('Fibre', 'g'),
  hk_sugar_g: hk('Sugar', 'g'),
  hk_sodium_mg: hk('Sodium', 'mg'),
  hk_caffeine_mg: hk('Caffeine', 'mg'),
  hk_water_l: hk('Water', 'L'),
  hk_weight_kg: hk('Body weight', 'kg'),
  hk_bodyfat_pct: hk('Body fat', '%'),
  hk_bmi: hk('BMI', 'kg/m2'),
  hk_steps: hk('Steps (phone)', 'steps'),
  hk_distance_m: hk('Walking + running distance', 'm'),
  hk_flights: hk('Flights climbed', 'flights'),
  hk_active_kcal: hk('Active energy (phone)', 'kcal'),
  hk_basal_kcal: hk('Resting energy (phone)', 'kcal'),
  hk_exercise_min: hk('Exercise minutes', 'min'),
  hk_mindful_min: hk('Mindful minutes', 'min'),
  hk_sleep_asleep_min: hk('Sleep (Apple Health)', 'min', 'Another source, kept separate from band sleep.'),
  hk_rhr: hk('Resting HR (Apple Health)', 'bpm', 'Another source, kept separate from band data.'),
  hk_hrv_sdnn: hk('HRV SDNN (Apple Health)', 'ms', 'Another source, kept separate from band data.'),
  // ── context ──
  wx_temp_max_c: { label: 'Max temperature', unit: 'C', source: 'weather' },
  wx_temp_min_c: { label: 'Min temperature', unit: 'C', source: 'weather' },
  wx_feels_max_c: { label: 'Max feels-like temperature', unit: 'C', source: 'weather' },
  wx_humidity_pct: { label: 'Humidity', unit: '%', source: 'weather' },
  wx_precip_mm: { label: 'Rain', unit: 'mm', source: 'weather' },
  cal_events: { label: 'Calendar events', unit: 'count', source: 'calendar', note: 'Counts only; titles are never stored.' },
  cal_busy_min: { label: 'Calendar busy time', unit: 'min', source: 'calendar' },
  cal_first_start_min: { label: 'First event start', unit: 'min after midnight', source: 'calendar' },
  cal_last_end_min: { label: 'Last event end', unit: 'min after midnight', source: 'calendar' },
};

/** What get_days returns when no metrics are named: the questions this
 *  connector exists for, without 70 columns of micronutrients. */
export const HEADLINE = [
  'readiness', 'rhr', 'rmssd', 'resp_rate', 'skin_temp_z', 'sleep_score',
  'tst_min', 'efficiency', 'deep_min', 'rem_min', 'strain', 'active_min',
  'calories_total', 'stress', 'hk_steps', 'hk_kcal_in', 'hk_protein_g',
  'hk_weight_kg', 'wx_temp_max_c', 'cal_busy_min',
];

export function describe(key: string): MetricInfo | undefined {
  if (METRICS[key]) return METRICS[key];
  if (key.startsWith('hk_')) return hk(key.slice(3).replace(/_/g, ' '), 'see key suffix', 'Apple Health import.');
  if (key.startsWith('wx_')) return { label: key.slice(3), unit: 'see key suffix', source: 'weather' };
  if (key.startsWith('cal_')) return { label: key.slice(4), unit: 'see key suffix', source: 'calendar' };
  return undefined;
}
