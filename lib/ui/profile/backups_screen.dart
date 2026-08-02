// backups_screen.dart — see and restore the automatic local snapshots.
//
// The list is deliberately blunt about what these protect against. A backup
// screen that implies "your data is safe" while the snapshots live in the same
// container the app does is worse than no screen: it converts a real risk into
// a false sense of security.

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/backup_service.dart';
import '../../data/drive_backup.dart';
import '../design/design.dart';

class BackupsScreen extends StatefulWidget {
  const BackupsScreen({super.key});

  @override
  State<BackupsScreen> createState() => _BackupsScreenState();
}

class _BackupsScreenState extends State<BackupsScreen> {
  List<BackupInfo> _items = const [];
  bool _loading = true;
  bool _busy = false;
  String? _driveAccount;
  bool _driveOn = false;
  DateTime? _driveLast;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final l = await BackupService.list();
    final acct = await DriveBackup.currentAccount();
    final on = await DriveBackup.enabled();
    final last = await DriveBackup.lastUpload();
    if (mounted) {
      setState(() {
        _items = l;
        _driveAccount = acct;
        _driveOn = on;
        _driveLast = last;
        _loading = false;
      });
    }
  }

  Future<void> _driveSignIn() async {
    setState(() => _busy = true);
    final email = await DriveBackup.signIn();
    if (email != null) await DriveBackup.setEnabled(true);
    if (!mounted) return;
    setState(() => _busy = false);
    if (email == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Google sign-in cancelled or failed.')),
      );
    }
    await _load();
  }

  Future<void> _driveUploadNow() async {
    setState(() => _busy = true);
    final r = await DriveBackup.uploadLatest();
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(switch (r) {
        DriveResult.uploaded => 'Uploaded to Google Drive.',
        DriveResult.notSignedIn => 'Sign in to Google first.',
        DriveResult.noBackup => 'No snapshot to upload yet.',
        DriveResult.skipped => 'Google Drive is not configured in this build.',
        DriveResult.failed => 'Upload failed - check your connection.',
      })),
    );
    await _load();
  }

  static String _when(DateTime d) {
    final now = DateTime.now();
    final days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
    final t = '$h:${d.minute.toString().padLeft(2, '0')}'
        '${d.hour < 12 ? 'am' : 'pm'}';
    return switch (days) {
      0 => 'Today $t',
      1 => 'Yesterday $t',
      < 7 => '$days days ago, $t',
      _ => '${d.day}/${d.month} $t',
    };
  }

  /// "premigrate_v27" / "prerestore" / "auto" — carried in the filename so a
  /// snapshot taken because something risky was about to happen is
  /// recognisable when choosing what to roll back to.
  static String _reason(String path) {
    final name = path.split('/').last;
    if (name.contains('premigrate')) return 'before a schema upgrade';
    if (name.contains('prerestore')) return 'before a restore';
    return 'routine';
  }

  Future<void> _restore(BackupInfo b) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        backgroundColor: AppColors.surface,
        title: const Text('Restore this backup?'),
        content: Text(
          'Everything recorded since ${_when(b.takenAt)} will be replaced - '
          'band records, workouts, journal entries.\n\n'
          'The current data is snapshotted first, so this is reversible. '
          'Close and reopen the app afterwards.',
          style: AppText.bodySoft,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text('Restore', style: TextStyle(color: AppColors.bad)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _busy = true);
    final done = await BackupService.restore(b.path);
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(done
            ? 'Restored. Close and reopen the app now.'
            : 'Restore failed - nothing was changed.'),
      ),
    );
    await _load();
  }

  /// The only copy that survives the app being deleted.
  Widget _driveCard() {
    if (!DriveBackup.configured) {
      return SurfaceCard(
        child: Text(
          'Not configured in this build - GOOGLE_CLIENT_ID is missing from '
          '.env, so Drive backup is unavailable.',
          style: AppText.captionMuted,
        ),
      );
    }
    final signedIn = _driveAccount != null;
    return SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  signedIn ? _driveAccount! : 'Not connected',
                  style: AppText.body.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (signedIn && _driveOn)
                AppIcon(OsIcon.check, size: 16, color: AppColors.good),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            signedIn
                ? (_driveLast == null
                    ? 'Connected - nothing uploaded yet'
                    : 'Last upload ${_when(_driveLast!)}')
                : 'Uploads the newest snapshot daily. This is the only copy '
                    'that survives deleting the app.',
            style: AppText.captionMuted,
          ),
          const SizedBox(height: Sp.x3),
          Row(
            children: [
              Expanded(
                child: Pressable(
                  onTap: _busy
                      ? null
                      : (signedIn ? _driveUploadNow : _driveSignIn),
                  borderRadius: BorderRadius.circular(R.pill),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppColors.tonalFill(AppColors.accent),
                      borderRadius: BorderRadius.circular(R.pill),
                    ),
                    child: Text(
                      signedIn ? 'Back up now' : 'Connect Google Drive',
                      style: AppText.label.copyWith(
                        color: AppColors.accent,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
              if (signedIn) ...[
                const SizedBox(width: Sp.x2),
                Pressable(
                  onTap: () async {
                    await DriveBackup.signOut();
                    await DriveBackup.setEnabled(false);
                    await _load();
                  },
                  borderRadius: BorderRadius.circular(R.pill),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: Sp.x3, vertical: 10),
                    child: Text('Disconnect',
                        style:
                            AppText.label.copyWith(color: AppColors.inkMuted)),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: 'Backups',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(Sp.screen, Sp.x2, Sp.screen, Sp.x6),
        children: [
          SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('What these cover', style: AppText.title),
                const SizedBox(height: Sp.x2),
                Text(
                  'A snapshot is taken automatically each day, and before any '
                  'schema upgrade. They live on this phone, so they are '
                  'included in your normal iPhone backup and survive losing or '
                  'replacing the device.',
                  style: AppText.bodySoft,
                ),
                const SizedBox(height: Sp.x3),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AppIcon(OsIcon.info, size: 15, color: AppColors.warn),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: Text(
                        'They do NOT survive deleting the app - that removes '
                        'them with everything else. For that, use Export data '
                        '(.db) and keep the file somewhere off this phone.',
                        style: AppText.captionMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x4),
          const SectionHeader('Google Drive'),
          _driveCard(),
          const SizedBox(height: Sp.x4),
          const SectionHeader('Snapshots'),
          if (_loading)
            Skeleton.tileRow(rows: 3)
          else if (_items.isEmpty)
            SurfaceCard(
              child: Text(
                'No snapshots yet. The first one is taken once there is a '
                'meaningful amount of data to protect.',
                style: AppText.captionMuted,
              ),
            )
          else
            SurfaceCard(
              child: Column(
                children: [
                  for (var i = 0; i < _items.length; i++)
                    ListRow(
                      icon: OsIcon.history,
                      title: _when(_items[i].takenAt),
                      subtitle:
                          '${_items[i].sizeLabel} · ${_reason(_items[i].path)}',
                      value: 'Restore',
                      onTap: _busy ? null : () => _restore(_items[i]),
                      divider: i < _items.length - 1,
                    ),
                ],
              ),
            ),
          const SizedBox(height: Sp.x4),
          // Sharing a snapshot off-device is the only thing that survives the
          // app being deleted, so it gets its own action rather than being
          // buried in the restore flow.
          if (_items.isNotEmpty)
            Builder(
              builder: (c) => SurfaceCard(
                child: ListRow(
                  icon: OsIcon.share,
                  title: 'Share newest snapshot',
                  subtitle: 'Save it off this phone',
                  onTap: () async {
                    final box = c.findRenderObject() as RenderBox?;
                    await Share.shareXFiles(
                      [XFile(_items.first.path)],
                      text: 'Whoop backup',
                      sharePositionOrigin: box != null
                          ? box.localToGlobal(Offset.zero) & box.size
                          : null,
                    );
                    await BackupService.markExported();
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
