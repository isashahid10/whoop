// backup_service.dart — rolling local snapshots of the SQLite store.
//
// WHY THIS EXISTS. Most of what the database holds cannot be re-fetched:
//
//   * BAND RECORDS. The strap's flash is a ring buffer — once drained and
//     overwritten, the only copy of that night is the one on the phone.
//   * BASELINES. Rebuildable in principle, but only by re-deriving from those
//     same records, so they die with them.
//   * JOURNAL + HEVY IMPORT. Re-importable from source, but tediously.
//
// A manual "Export data (.db)" already existed in Profile, which is the right
// escape hatch but only helps if you remembered to run it before the thing you
// needed it for.
//
// WHERE SNAPSHOTS GO, and what that does and does not protect against.
// Application Support inside the app container. That directory IS included in
// the device's normal iCloud/Finder backup, so a snapshot here survives:
//
//   ✓ database corruption
//   ✓ a bad schema migration (a snapshot is taken BEFORE each one)
//   ✓ losing or replacing the phone, via a device restore
//   ✗ DELETING the app — that removes the whole container, snapshots included
//
// The last one is the reason the manual off-device export still matters, and
// why [shouldNudgeExport] exists to ask for one periodically. iCloud Drive
// would close that gap, but the container entitlement is not available on a
// free Personal Team (the same constraint that removed the HealthKit Access
// key from Runner.entitlements).

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Database, getDatabasesPath;

import 'db.dart';

class BackupInfo {
  final String path;
  final DateTime takenAt;
  final int bytes;

  const BackupInfo({
    required this.path,
    required this.takenAt,
    required this.bytes,
  });

  String get sizeLabel => bytes >= 1024 * 1024
      ? '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB'
      : '${(bytes / 1024).round()} KB';
}

class BackupService {
  BackupService._();

  /// How many snapshots to keep.
  ///
  /// Enough to step back past a bad run without unbounded growth: corruption
  /// or a bad migration is usually noticed within a day or two, and each
  /// snapshot is a full copy of the store.
  static const int keep = 5;

  /// Minimum gap between automatic snapshots.
  static const Duration interval = Duration(hours: 20);

  /// How often to ask for an OFF-DEVICE export. Local snapshots do not survive
  /// deleting the app, so this is the only protection against that.
  static const Duration exportNudgeInterval = Duration(days: 30);

  static const _kLastAuto = 'backup_last_auto_ms';
  static const _kLastExport = 'backup_last_export_ms';

  /// A store this small is a fresh install with nothing worth preserving —
  /// snapshotting it would only push a real backup out of the retention window.
  static const int _minMeaningfulBytes = 64 * 1024;

  /// Total on-disk size of the store, WAL SIDECARS INCLUDED.
  ///
  /// [LocalDb.databaseFileBytes] measures only the main `.db` file, and this
  /// database runs in WAL mode — so recent writes sit in `-wal` and the main
  /// file can stay small for a long time. Gating on that alone silently
  /// skipped snapshots on exactly the stores that had just accumulated new
  /// data, which is the opposite of what a backup is for.
  static Future<int> storeBytes() async {
    try {
      final dir = await getDatabasesPath();
      var total = 0;
      for (final suffix in const ['', '-wal', '-shm']) {
        final f = File(p.join(dir, '${LocalDb.dbName}$suffix'));
        if (await f.exists()) total += await f.length();
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  static Future<Directory> _dir() async {
    final base = await getApplicationSupportDirectory();
    final d = Directory(p.join(base.path, 'backups'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// Existing snapshots, newest first.
  static Future<List<BackupInfo>> list() async {
    try {
      final d = await _dir();
      final out = <BackupInfo>[];
      await for (final e in d.list()) {
        if (e is! File || !e.path.endsWith('.db')) continue;
        final stat = await e.stat();
        out.add(BackupInfo(
          path: e.path,
          takenAt: stat.modified,
          bytes: stat.size,
        ));
      }
      out.sort((a, b) => b.takenAt.compareTo(a.takenAt));
      return out;
    } catch (e) {
      debugPrint('[backup] list failed: $e');
      return const [];
    }
  }

  /// Take a snapshot now. Returns its path, or null when skipped or failed.
  ///
  /// [reason] is folded into the filename so a pre-migration snapshot is
  /// distinguishable from a routine one when you are choosing what to restore.
  /// [db] lets a caller that ALREADY holds an open handle pass it in.
  ///
  /// This matters inside `onUpgrade`: the database is mid-open there, and
  /// reaching for `LocalDb.instance` re-enters that same open. Observed
  /// failure was not a hang but a corrupted migration — the re-entrant call
  /// closed the handle underneath the upgrade, and the next statement died
  /// with "This database has already been closed", leaving the schema half
  /// migrated. A backup must never be able to damage the thing it protects.
  static Future<String?> snapshot({
    String reason = 'auto',
    Database? db,
  }) async {
    try {
      final bytes = await storeBytes();
      if (bytes < _minMeaningfulBytes) {
        debugPrint('[backup] store is only $bytes B - skipped');
        return null;
      }

      final handle = db ?? await LocalDb.instance;
      final d = await _dir();
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(':', '')
          .replaceAll('-', '')
          .split('.')
          .first;
      final dest = p.join(d.path, 'whoop_${reason}_$stamp.db');
      final f = File(dest);
      if (await f.exists()) await f.delete(); // VACUUM INTO needs a fresh path

      // VACUUM INTO, not a file copy: it is transactionally consistent, so the
      // snapshot cannot catch a half-written page mid-write, and it compacts
      // free space out at the same time.
      await handle.execute('VACUUM INTO ?', [dest]);

      await _prune();
      debugPrint('[backup] wrote $dest');
      return dest;
    } catch (e) {
      // A failed backup must never break the app that triggered it.
      debugPrint('[backup] snapshot failed: $e');
      return null;
    }
  }

  /// Drop the oldest snapshots beyond [keep].
  static Future<void> _prune() async {
    try {
      final all = await list();
      for (final b in all.skip(keep)) {
        await File(b.path).delete();
      }
    } catch (e) {
      debugPrint('[backup] prune failed: $e');
    }
  }

  /// Snapshot at most once per [interval]. Safe to call on every launch.
  static Future<void> maybeSnapshot() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_kLastAuto) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < interval.inMilliseconds) return;
      // Stamp BEFORE the work, so a snapshot that fails does not retry on
      // every single launch.
      await prefs.setInt(_kLastAuto, now);
      await snapshot();
    } catch (e) {
      debugPrint('[backup] maybeSnapshot failed: $e');
    }
  }

  // ── off-device export nudge ────────────────────────────────────────────────

  /// Record that the user shared an export somewhere off this device.
  static Future<void> markExported() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _kLastExport, DateTime.now().millisecondsSinceEpoch);
  }

  /// Whether it is worth asking for an off-device export.
  ///
  /// True on a store that has real data and has never been exported, or not
  /// exported within [exportNudgeInterval].
  static Future<bool> shouldNudgeExport() async {
    try {
      if (await storeBytes() < _minMeaningfulBytes) return false;
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_kLastExport);
      if (last == null) return true;
      final age = DateTime.now().millisecondsSinceEpoch - last;
      return age >= exportNudgeInterval.inMilliseconds;
    } catch (_) {
      return false;
    }
  }

  // ── restore ────────────────────────────────────────────────────────────────

  /// Replace the live store with [backupPath].
  ///
  /// The CURRENT store is snapshotted first, under the `prerestore` reason. A
  /// restore is destructive and irreversible otherwise — and the most likely
  /// moment to restore the wrong file is when you are already panicking about
  /// data loss.
  ///
  /// The caller must restart the app afterwards: every open handle, cached
  /// query and in-memory baseline still refers to the replaced file.
  static Future<bool> restore(String backupPath) async {
    try {
      final src = File(backupPath);
      if (!await src.exists()) return false;

      await snapshot(reason: 'prerestore');

      await LocalDb.close();
      final dir = await getDatabasesPath();
      final live = File(p.join(dir, LocalDb.dbName));

      // Remove the WAL/SHM sidecars too. Left behind, SQLite would replay them
      // over the restored file and resurrect the very data being rolled back.
      for (final suffix in const ['', '-wal', '-shm']) {
        final f = File('${live.path}$suffix');
        if (await f.exists()) await f.delete();
      }

      await src.copy(live.path);
      debugPrint('[backup] restored from $backupPath');
      return true;
    } catch (e) {
      debugPrint('[backup] restore failed: $e');
      return false;
    }
  }
}
