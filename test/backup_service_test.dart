// Database snapshots.
//
// This is the code that runs when something has already gone wrong, so the
// properties worth pinning are the ones whose failure you would only discover
// at that exact moment: that a snapshot is a real, openable database; that
// restoring takes a safety copy FIRST; and that retention cannot quietly throw
// away the snapshot you needed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:openstrap_edge/data/backup_service.dart';
import 'package:openstrap_edge/data/db.dart';

/// Write enough rows that the file clears the "not worth snapshotting" floor.
Future<void> _fill({int days = 400}) async {
  final db = await LocalDb.instance;
  final batch = db.batch();
  for (var i = 0; i < days; i++) {
    final d = DateTime(2026, 1, 1).add(Duration(days: i));
    final label = '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    for (final k in const ['rhr', 'rmssd', 'strain', 'steps', 'calories']) {
      batch.insert(
        'metric_series',
        {'date': label, 'key': k, 'value': i.toDouble()},
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }
  }
  await batch.commit(noResult: true);
}

Future<int> _rowCount() async {
  final db = await LocalDb.instance;
  final r = await db.rawQuery('SELECT COUNT(*) c FROM metric_series');
  return (r.first['c'] as num).toInt();
}

/// path_provider has no implementation in the test binding, so every call
/// throws MissingPluginException and the service silently returns null - the
/// snapshot path has to be faked to be testable at all.
class _FakePaths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  final String root;
  _FakePaths(this.root);
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    LocalDb.dbName = 'openstrap_backup_test.db';
    final tmp = await Directory.systemTemp.createTemp('whoop_backup_test');
    PathProviderPlatform.instance = _FakePaths(tmp.path);
  });

  setUp(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
    for (final b in await BackupService.list()) {
      final f = File(b.path);
      if (await f.exists()) await f.delete();
    }
  });

  tearDownAll(() async {
    await LocalDb.close();
    final dir = await databaseFactory.getDatabasesPath();
    await databaseFactory.deleteDatabase(p.join(dir, LocalDb.dbName));
  });

  test('a snapshot is a REAL, openable database with the same rows', () async {
    await _fill();
    final before = await _rowCount();
    final path = await BackupService.snapshot();
    expect(path, isNotNull);

    // The whole point: it can be opened and read independently. A file that
    // merely exists is not a backup.
    final copy = await databaseFactory.openDatabase(path!);
    final r = await copy.rawQuery('SELECT COUNT(*) c FROM metric_series');
    await copy.close();
    expect((r.first['c'] as num).toInt(), before);
  });

  test('an all-but-empty store is NOT snapshotted', () async {
    // A fresh install has nothing worth keeping, and snapshotting it would
    // push a real backup out of the retention window.
    final path = await BackupService.snapshot();
    expect(path, isNull);
    expect(await BackupService.list(), isEmpty);
  });

  test('the reason is carried in the filename', () async {
    await _fill();
    final path = await BackupService.snapshot(reason: 'premigrate_v27');
    // Needed when choosing what to roll back to: a snapshot taken because
    // something risky was about to happen is not the same as a routine one.
    expect(path, contains('premigrate_v27'));
  });

  test('retention keeps the NEWEST and drops the oldest', () async {
    await _fill();
    for (var i = 0; i < BackupService.keep + 3; i++) {
      await BackupService.snapshot(reason: 'n$i');
      // VACUUM INTO needs a distinct path, and the stamp is second-resolution.
      await Future<void>.delayed(const Duration(milliseconds: 1100));
    }
    final list = await BackupService.list();
    expect(list.length, BackupService.keep);
    // Newest first, and the most recent must be among the survivors —
    // pruning the wrong end would discard exactly what you want.
    expect(list.first.path, contains('n${BackupService.keep + 2}'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('restore', () {
    test('rolls the data back', () async {
      await _fill(days: 100);
      final atBackup = await _rowCount();
      final path = (await BackupService.snapshot())!;

      await _fill(days: 400); // more data lands afterwards
      expect(await _rowCount(), greaterThan(atBackup));

      expect(await BackupService.restore(path), isTrue);
      // The live handle now points at a replaced file - reopen, as the UI
      // instructs the user to do.
      await LocalDb.close();
      expect(await _rowCount(), atBackup);
    });

    test('takes a SAFETY snapshot of the current data first', () async {
      await _fill(days: 100);
      final path = (await BackupService.snapshot())!;
      await _fill(days: 400);

      await BackupService.restore(path);
      final list = await BackupService.list();
      // Restoring the wrong file is most likely exactly when you are panicking
      // about data loss; without this the mistake is unrecoverable.
      expect(list.any((b) => b.path.contains('prerestore')), isTrue);
    });

    test('a missing file fails safely and changes nothing', () async {
      await _fill();
      final before = await _rowCount();
      expect(await BackupService.restore('/nope/missing.db'), isFalse);
      expect(await _rowCount(), before);
    });
  });
}
