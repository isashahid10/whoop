// drive_backup.dart — off-device backup to the user's own Google Drive.
//
// WHY THIS EXISTS, when local snapshots already do. BackupService writes into
// the app container. That covers corruption, a bad migration, and a lost or
// replaced phone (the container is in the device backup) — but NOT deleting
// the app, which removes the container and every snapshot in it. Drive is the
// only copy that survives that, and it is the copy that matters if the phone
// is lost and restored to a fresh install.
//
// SCOPE IS `drive.file`, DELIBERATELY. That grants access ONLY to files this
// app itself created — the rest of the Drive is invisible to it, permanently
// and enforceably, not as a promise in a privacy policy. It is also classed
// non-sensitive by Google, so no verification review is needed.
//
// THE ONE-TIME SETUP TRAP. While the OAuth consent screen sits in "Testing",
// Google expires refresh tokens after SEVEN DAYS, so sign-in would silently
// die every week. Publishing the consent screen to "In production" removes
// that, and needs no review for a non-sensitive scope. If uploads start
// failing about a week after they were working, that is the cause.

import 'dart:io';

import 'package:extension_google_sign_in_as_googleapis_auth/extension_google_sign_in_as_googleapis_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:shared_preferences/shared_preferences.dart';

import 'backup_service.dart';

/// Why an upload did not happen. The UI needs to tell these apart: "not signed
/// in" is the user's move to make, "no backup yet" is not a fault at all, and
/// a network failure is worth retrying.
enum DriveResult { uploaded, notSignedIn, noBackup, failed, skipped }

class DriveBackup {
  DriveBackup._();

  /// The iOS OAuth client id, supplied at build time via
  /// `--dart-define-from-file=.env` (`GOOGLE_CLIENT_ID=...apps.googleusercontent.com`).
  ///
  /// Not committed: it is per-project, and hardcoding it would bake one
  /// person's Cloud project into the source.
  static const String clientId =
      String.fromEnvironment('GOOGLE_CLIENT_ID', defaultValue: '');

  /// App-created files only — this app can never see the rest of the Drive.
  static const String _scope = drive.DriveApi.driveFileScope;

  /// Where backups land, so they are findable and deletable by hand.
  static const String folderName = 'Whoop Backups';

  /// How many uploads to keep before pruning the oldest.
  static const int keep = 7;

  static const Duration interval = Duration(hours: 24);
  static const _kLastUpload = 'drive_last_upload_ms';
  static const _kEnabled = 'drive_backup_enabled';

  static bool get configured => clientId.isNotEmpty;

  static GoogleSignIn get _signIn => GoogleSignIn.instance;
  static bool _initialised = false;

  static Future<void> _ensureInit() async {
    if (_initialised) return;
    await _signIn.initialize(clientId: clientId);
    _initialised = true;
  }

  // ── settings ───────────────────────────────────────────────────────────────

  static Future<bool> enabled() async =>
      (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? false;

  static Future<void> setEnabled(bool v) async {
    final p = await SharedPreferences.getInstance();
    await p.setBool(_kEnabled, v);
  }

  static Future<DateTime?> lastUpload() async {
    final ms =
        (await SharedPreferences.getInstance()).getInt(_kLastUpload);
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
  }

  // ── auth ───────────────────────────────────────────────────────────────────

  /// Interactive sign-in. Returns the account email, or null if cancelled.
  static Future<String?> signIn() async {
    if (!configured) return null;
    try {
      await _ensureInit();
      final account = await _signIn.authenticate(scopeHint: const [_scope]);
      return account.email;
    } catch (e) {
      debugPrint('[drive] sign-in failed: $e');
      return null;
    }
  }

  /// Silent re-auth from the stored session. Null when a fresh sign-in is
  /// needed — which is exactly what a Testing-mode consent screen causes every
  /// seven days.
  static Future<GoogleSignInAccount?> _silent() async {
    if (!configured) return null;
    try {
      await _ensureInit();
      return await _signIn.attemptLightweightAuthentication();
    } catch (e) {
      debugPrint('[drive] silent auth failed: $e');
      return null;
    }
  }

  static Future<String?> currentAccount() async => (await _silent())?.email;

  static Future<void> signOut() async {
    try {
      await _ensureInit();
      await _signIn.signOut();
    } catch (_) {}
  }

  static Future<drive.DriveApi?> _api() async {
    final account = await _silent();
    if (account == null) return null;
    // authenticatedClient() hangs off the AUTHORIZATION object, not the
    // GoogleSignIn singleton (extension GoogleApisGoogleSignInAuth on
    // GoogleSignInClientAuthorization).
    final auth = await account.authorizationClient
        .authorizationForScopes(const [_scope]);
    if (auth == null) return null;
    return drive.DriveApi(auth.authClient(scopes: const [_scope]));
  }

  // ── upload ─────────────────────────────────────────────────────────────────

  /// The `Whoop Backups` folder id, creating it if absent.
  static Future<String?> _folderId(drive.DriveApi api) async {
    try {
      // `drive.file` only ever returns files this app made, so this cannot
      // collide with an unrelated folder of the same name.
      final found = await api.files.list(
        q: "mimeType='application/vnd.google-apps.folder' "
            "and name='$folderName' and trashed=false",
        $fields: 'files(id)',
      );
      final existing = found.files;
      if (existing != null && existing.isNotEmpty) return existing.first.id;

      final created = await api.files.create(
        drive.File()
          ..name = folderName
          ..mimeType = 'application/vnd.google-apps.folder',
        $fields: 'id',
      );
      return created.id;
    } catch (e) {
      debugPrint('[drive] folder lookup failed: $e');
      return null;
    }
  }

  /// Upload the newest local snapshot.
  static Future<DriveResult> uploadLatest() async {
    if (!configured) return DriveResult.skipped;
    try {
      final backups = await BackupService.list();
      if (backups.isEmpty) return DriveResult.noBackup;

      final api = await _api();
      if (api == null) return DriveResult.notSignedIn;

      final folder = await _folderId(api);
      if (folder == null) return DriveResult.failed;

      final f = File(backups.first.path);
      final len = await f.length();
      final media = drive.Media(f.openRead(), len);

      await api.files.create(
        drive.File()
          ..name = backups.first.path.split('/').last
          ..parents = [folder],
        uploadMedia: media,
      );

      await _prune(api, folder);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
          _kLastUpload, DateTime.now().millisecondsSinceEpoch);
      // The local nudge counts an off-device copy as done — this IS one.
      await BackupService.markExported();
      debugPrint('[drive] uploaded ${backups.first.path}');
      return DriveResult.uploaded;
    } catch (e) {
      debugPrint('[drive] upload failed: $e');
      return DriveResult.failed;
    }
  }

  /// Keep the newest [keep] uploads; trash the rest.
  static Future<void> _prune(drive.DriveApi api, String folder) async {
    try {
      final list = await api.files.list(
        q: "'$folder' in parents and trashed=false",
        orderBy: 'createdTime desc',
        $fields: 'files(id,createdTime)',
      );
      final files = list.files ?? const <drive.File>[];
      for (final f in files.skip(keep)) {
        final id = f.id;
        if (id != null) await api.files.delete(id);
      }
    } catch (e) {
      debugPrint('[drive] prune failed: $e');
    }
  }

  /// How stale an upload has to get before it is worth complaining about.
  ///
  /// Comfortably longer than [interval], so a few missed days (offline, phone
  /// off) stay quiet, but a genuinely dead connection surfaces within a week.
  static const Duration staleAfter = Duration(days: 5);

  /// Upload at most once per [interval]. Safe to call on every foreground.
  ///
  /// Returns the outcome so the caller can WARN on a persistent failure. A
  /// backup that silently stops is the worst kind: you find out it stopped at
  /// the exact moment you needed it. The commonest cause is the OAuth consent
  /// screen still being in "Testing", where Google expires the refresh token
  /// after seven days.
  static Future<DriveResult> maybeUpload() async {
    if (!configured || !await enabled()) return DriveResult.skipped;
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_kLastUpload) ?? 0;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - last < interval.inMilliseconds) return DriveResult.skipped;
      return await uploadLatest();
    } catch (e) {
      debugPrint('[drive] maybeUpload failed: $e');
      return DriveResult.failed;
    }
  }

  /// True when Drive backup is switched ON but has not managed an upload
  /// within [staleAfter]. Drives the "backup has stopped" warning.
  static Future<bool> isStale() async {
    if (!configured || !await enabled()) return false;
    final last = await lastUpload();
    // Enabled but never once succeeded is itself worth flagging.
    if (last == null) return true;
    return DateTime.now().difference(last) > staleAfter;
  }
}
