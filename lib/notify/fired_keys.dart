// fired_keys.dart — the persistent, cross-isolate "already fired this key" record.
//
// A NotificationEvent's dedupeKey (by convention "$date:$kind") promises the
// event fires at most once. The OS notification id alone does NOT enforce this:
// re-showing the same id only REPLACES the prior post in the shade — it still
// re-alerts (sound/buzz). Since derivation re-runs on every BLE sync, an insight
// whose condition holds all day (e.g. today's low-readiness or irregular-rhythm
// flag) would fire over and over (issue #136). This store makes emit() honour the
// promise: a key that has already fired is skipped until a *new* key comes along.
//
// CROSS-ISOLATE. Derivation runs in TWO isolates: the long-lived
// foreground pass (kept alive for BLE) and the WorkManager background pass
// (background_derivation.dart) — both call emit()/this store, ~every drain and
// ~every 15 min. The NotificationCenter lock only orders emits WITHIN one
// isolate; it can't coordinate across them. The original store defeated its own
// guard two ways here, so a same-day key re-fired all day:
//   1. Stale read cache. The legacy SharedPreferences instance loads a snapshot
//      once and never re-reads disk. The long-lived foreground isolate loaded
//      prefs before today's key existed, so after the background isolate recorded
//      it, hasFired() still read the stale snapshot as "not fired" → re-alert.
//      FIX: reload() before every read so a write from the other isolate is seen.
//   2. Lost-update clobber. Keys lived in ONE shared list mutated via
//      read-modify-write (getStringList → add → setStringList). With no
//      cross-process lock, whichever isolate wrote last rewrote the WHOLE list
//      from its own (stale) copy, dropping the other's keys — including a
//      just-recorded one, which then re-fired. FIX: one independent bool flag per
//      key. Native SharedPreferences merges single-key writes, so two isolates
//      recording different keys can't clobber each other, and recording the same
//      key twice is idempotent.
//
// Reset is automatic: keys are date-prefixed, so tomorrow's "2026-07-24:low_read"
// is a fresh key that fires once. Growth is bounded by _prune(): date-prefixed
// flags older than [retentionDays] are dropped (the dedupe only needs today, so a
// fortnight is ample). Keys without a leading date (e.g. "alarm_fired:<epoch>")
// are rare and self-limiting, so they're left alone.

import 'package:shared_preferences/shared_preferences.dart';

class FiredKeyStore {
  const FiredKeyStore();

  /// Per-key flag namespace. Each fired dedupeKey is its own bool at
  /// "$_prefix$dedupeKey" — never a shared list (see the clobber note above).
  static const String _prefix = 'notif_fired:';

  /// How long a date-prefixed fired flag is retained before [_prune] drops it.
  /// The guard only needs the current day; a fortnight is a generous margin.
  static const int retentionDays = 14;

  /// Whether [dedupeKey] has already fired an OS notification.
  ///
  /// Reloads from the platform first: this isolate's in-memory snapshot can be
  /// stale relative to a record from the OTHER derivation isolate, and reading
  /// stale is exactly what let an already-fired key re-alert across isolates.
  Future<bool> hasFired(String dedupeKey) async {
    final p = await SharedPreferences.getInstance();
    await _reload(p);
    return p.getBool('$_prefix$dedupeKey') ?? false;
  }

  /// Record [dedupeKey] as fired — one independent flag, so a concurrent record
  /// of a different key from the other isolate can't clobber it. Recording the
  /// same key again is a harmless idempotent no-op. Prunes stale flags after.
  Future<void> recordFired(String dedupeKey) async {
    final p = await SharedPreferences.getInstance();
    // Reload first so both the write and the prune below act on the latest
    // cross-isolate state (and so _prune enumerates the other isolate's keys).
    await _reload(p);
    await p.setBool('$_prefix$dedupeKey', true);
    await _prune(p);
  }

  Future<void> _reload(SharedPreferences p) async {
    try {
      await p.reload();
    } catch (_) {/* reload is best-effort freshness, never fatal */}
  }

  /// Drop date-prefixed flags older than [retentionDays]. Best-effort and cheap:
  /// it only runs after a real fire (rare), and a slightly stale key view just
  /// prunes a little late. Keys without a leading YYYY-MM-DD are left untouched.
  Future<void> _prune(SharedPreferences p) async {
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: retentionDays));
      for (final k in p.getKeys()) {
        if (!k.startsWith(_prefix)) continue;
        final d = _leadingDate(k.substring(_prefix.length));
        if (d != null && d.isBefore(cutoff)) await p.remove(k);
      }
    } catch (_) {/* bounding is best-effort — never break a record on it */}
  }

  /// Parse a leading "YYYY-MM-DD" from a dedupeKey, or null if it isn't dated.
  static DateTime? _leadingDate(String dedupeKey) {
    if (dedupeKey.length < 10) return null;
    final head = dedupeKey.substring(0, 10);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(head)) return null;
    return DateTime.tryParse(head);
  }
}
