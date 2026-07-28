// hevy_client.dart — live Hevy workout sync using the app's own (undocumented)
// API, with no Hevy PRO subscription.
//
// WHY THIS SHAPE
//
// Hevy's `POST /login` is gated behind reCAPTCHA v3 Enterprise, which cannot be
// satisfied from a plain HTTP client — the reference implementations drive a
// headless Chrome via Playwright to obtain a token, which is impossible inside
// an iOS app and is squarely an anti-automation control besides.
//
// `POST /refresh_token` is NOT gated. So the split is:
//
//   ONE TIME   the user signs in through a real WebView on Hevy's own login
//              page. reCAPTCHA is *satisfied*, not circumvented: a real human
//              in a real browser. We keep the refresh token it issues.
//   ONGOING    /refresh_token → fresh access token → /workouts_batch.
//              Pure HTTP, no browser, works from a background sync.
//
// Only the refresh token is persisted. The password is never stored, and never
// even reaches Dart — it is typed into Hevy's own page inside the WebView.
//
// CONSTRAINTS THIS CODE ACCEPTS
//   • Undocumented endpoints. They can change without notice, so every failure
//     is surfaced LOUDLY (see [HevySyncStatus]) rather than logged and
//     swallowed. A silent background failure is the worst outcome for a
//     set-and-forget app — the coach would keep answering from stale lifts.
//   • Refresh tokens expire or get revoked; that path ends in
//     [HevyAuthExpired], which the UI must turn into "sign in to Hevy again".
//
// `x-api-key` below is Hevy's web-client key, identical for every user and
// published in the public reverse-engineering repos (casudo/Hevy-Insights,
// dmzoneill/hevyapp-api). Nothing here was extracted from a Hevy binary.

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Raised when the refresh token is dead and only a fresh WebView login helps.
class HevyAuthExpired implements Exception {
  final String message;
  HevyAuthExpired([this.message = 'Hevy sign-in expired']);
  @override
  String toString() => message;
}

/// Any other transport/shape failure. Carries something showable to the user.
class HevyError implements Exception {
  final String message;
  HevyError(this.message);
  @override
  String toString() => message;
}

/// One logged set. Mirrors Hevy's `sets[]` entries.
@immutable
class HevySet {
  final int index;
  final String indicator; // 'normal' | 'warmup' | 'failure' | 'dropset'
  final double? weightKg;
  final int? reps;
  final double? distanceMeters;
  final int? durationSeconds;
  final double? rpe;

  const HevySet({
    required this.index,
    required this.indicator,
    this.weightKg,
    this.reps,
    this.distanceMeters,
    this.durationSeconds,
    this.rpe,
  });

  static double? _d(Object? v) => (v as num?)?.toDouble();
  static int? _i(Object? v) => (v as num?)?.toInt();

  factory HevySet.fromJson(Map<String, dynamic> j) => HevySet(
        index: _i(j['index']) ?? 0,
        indicator: (j['indicator'] as String?) ?? 'normal',
        weightKg: _d(j['weight_kg']),
        reps: _i(j['reps']),
        distanceMeters: _d(j['distance_meters']),
        durationSeconds: _i(j['duration_seconds']),
        rpe: _d(j['rpe']),
      );

  /// Volume load for this set. Null unless it is a real weight×reps set —
  /// never 0, because 0 would silently drag a volume average down.
  double? get volumeKg =>
      (weightKg != null && reps != null) ? weightKg! * reps! : null;
}

/// One exercise within a workout, with its sets.
@immutable
class HevyExercise {
  final String title;
  final String? templateId;
  final String? exerciseType; // 'weight_reps' | 'distance_duration' | ...
  final String? equipment;
  final String? muscleGroup;
  final List<String> otherMuscles;
  final String? supersetId;
  final String notes;
  final List<HevySet> sets;

  const HevyExercise({
    required this.title,
    required this.sets,
    this.templateId,
    this.exerciseType,
    this.equipment,
    this.muscleGroup,
    this.otherMuscles = const [],
    this.supersetId,
    this.notes = '',
  });

  factory HevyExercise.fromJson(Map<String, dynamic> j) => HevyExercise(
        title: (j['title'] as String?) ?? 'Unknown',
        templateId: j['exercise_template_id'] as String?,
        exerciseType: j['exercise_type'] as String?,
        equipment: j['equipment_category'] as String?,
        muscleGroup: j['muscle_group'] as String?,
        otherMuscles:
            ((j['other_muscles'] as List?) ?? const []).map((e) => '$e').toList(),
        supersetId: j['superset_id'] as String?,
        notes: (j['notes'] as String?) ?? '',
        sets: ((j['sets'] as List?) ?? const [])
            .whereType<Map>()
            .map((s) => HevySet.fromJson(s.cast<String, dynamic>()))
            .toList(),
      );
}

/// One workout session.
@immutable
class HevyWorkout {
  final String id;
  final int index; // pagination cursor AND ordering key
  final String name;
  final String description;
  final DateTime start;
  final DateTime end;
  final List<HevyExercise> exercises;

  const HevyWorkout({
    required this.id,
    required this.index,
    required this.name,
    required this.description,
    required this.start,
    required this.end,
    required this.exercises,
  });

  factory HevyWorkout.fromJson(Map<String, dynamic> j) {
    DateTime ts(Object? v) => DateTime.fromMillisecondsSinceEpoch(
        ((v as num?)?.toInt() ?? 0) * 1000);
    return HevyWorkout(
      id: (j['id'] as String?) ?? '',
      index: (j['index'] as num?)?.toInt() ?? 0,
      name: (j['name'] as String?) ?? 'Workout',
      description: (j['description'] as String?) ?? '',
      start: ts(j['start_time']),
      end: ts(j['end_time']),
      exercises: ((j['exercises'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => HevyExercise.fromJson(e.cast<String, dynamic>()))
          .toList(),
    );
  }

  Duration get duration => end.difference(start);

  /// Total weight×reps across every real weighted set.
  double get totalVolumeKg => exercises
      .expand((e) => e.sets)
      .map((s) => s.volumeKg ?? 0)
      .fold<double>(0, (a, b) => a + b);

  int get setCount => exercises.fold<int>(0, (a, e) => a + e.sets.length);
}

class HevyClient {
  static const String _base = 'https://api.hevyapp.com';

  /// Hevy's web-client key. Static for all users; published in the public
  /// reverse-engineering repos. Not a per-user secret and not a PRO key.
  static const String _apiKey = 'klean_kanteen_insulated';

  static const _kRefresh = 'hevy_refresh_token';
  static const _kAccess = 'hevy_access_token';
  /// Which of [authSchemes] this token authenticates under — probed at sign-in
  /// so data calls never have to re-discover it.
  static const _kScheme = 'hevy_auth_scheme';

  final FlutterSecureStorage _secure = const FlutterSecureStorage();
  final http.Client _http;

  HevyClient({http.Client? client}) : _http = client ?? http.Client();

  Map<String, String> _headers({String? accessToken, String? scheme}) => {
        'x-api-key': _apiKey,
        'Content-Type': 'application/json',
        'accept': 'application/json, text/plain, */*',
        'Hevy-Platform': 'web',
        if (accessToken != null && accessToken.isNotEmpty)
          ..._authHeader(scheme ?? 'auth-token', accessToken),
      };

  // ── token storage ─────────────────────────────────────────────────────────

  /// How a token is presented to the API. The mobile app uses a bare
  /// `auth-token` header; the WEB app's cookie is named `auth2.0-token`, which
  /// points at OAuth 2.0 and therefore `Authorization: Bearer`. Since the token
  /// is captured from the web app, the scheme cannot be assumed — it is probed.
  static const List<String> authSchemes = ['auth-token', 'bearer', 'x-auth-token'];

  static Map<String, String> _authHeader(String scheme, String token) {
    switch (scheme) {
      case 'bearer':
        return {'Authorization': 'Bearer $token'};
      case 'x-auth-token':
        return {'x-auth-token': token};
      default:
        return {'auth-token': token};
    }
  }

  /// Probe [token] against a real endpoint under every known auth scheme.
  ///
  /// Returns the scheme that produced a 200, or null. Several cookies are
  /// token-shaped and picking one by NAME is how earlier attempts went wrong:
  /// a 200 is proof, a plausible name is not.
  static Future<String?> workingScheme(String token) async {
    final t = token.trim();
    if (t.length < 12) return null;
    for (final scheme in authSchemes) {
      try {
        final resp = await http.get(
          Uri.parse('$_base/user/account'),
          headers: {
            'x-api-key': _apiKey,
            'accept': 'application/json, text/plain, */*',
            'Hevy-Platform': 'web',
            ..._authHeader(scheme, t),
          },
        ).timeout(const Duration(seconds: 12));
        if (resp.statusCode == 200) return scheme;
      } catch (_) {
        /* try the next scheme */
      }
    }
    return null;
  }

  /// Per-candidate status codes, for the sign-in screen's diagnostic. Reports
  /// only lengths and status codes — never a token value.
  static Future<String> diagnose(List<String> candidates) async {
    if (candidates.isEmpty) {
      return 'No candidate tokens were readable from cookies.\n'
          'The values are likely HttpOnly (visible by name, unreadable by JS).';
    }
    final buf = StringBuffer('Tried ${candidates.length} candidate(s):\n');
    for (var i = 0; i < candidates.length; i++) {
      final t = candidates[i].trim();
      buf.write('\n#${i + 1} len=${t.length}  ');
      for (final scheme in authSchemes) {
        try {
          final resp = await http.get(
            Uri.parse('$_base/user/account'),
            headers: {
              'x-api-key': _apiKey,
              'accept': 'application/json, text/plain, */*',
              'Hevy-Platform': 'web',
              ..._authHeader(scheme, t),
            },
          ).timeout(const Duration(seconds: 12));
          buf.write('$scheme=${resp.statusCode} ');
        } catch (_) {
          buf.write('$scheme=ERR ');
        }
      }
    }
    return buf.toString();
  }

  /// Linked when we hold EITHER token. The access token is the one that
  /// actually works — see [_refreshAccessToken] for why refresh is optional.
  Future<bool> get isLinked async {
    final a = await _secure.read(key: _kAccess);
    if (a != null && a.isNotEmpty) return true;
    final r = await _secure.read(key: _kRefresh);
    return r != null && r.isNotEmpty;
  }

  /// Persist whatever the one-time WebView sign-in captured. Both are optional
  /// because Hevy exposes no working refresh endpoint — an access token on its
  /// own is a complete, usable link.
  Future<void> storeTokens({
    String? refreshToken,
    String? accessToken,
    String? scheme,
  }) async {
    if (scheme != null && scheme.isNotEmpty) {
      await _secure.write(key: _kScheme, value: scheme);
    }
    if (refreshToken != null && refreshToken.isNotEmpty) {
      await _secure.write(key: _kRefresh, value: refreshToken);
    }
    if (accessToken != null && accessToken.isNotEmpty) {
      await _secure.write(key: _kAccess, value: accessToken);
    }
  }

  /// Forget the link entirely (sign out / revoked token).
  Future<void> clear() async {
    await _secure.delete(key: _kRefresh);
    await _secure.delete(key: _kAccess);
    await _secure.delete(key: _kScheme);
  }

  // ── auth ──────────────────────────────────────────────────────────────────

  /// Best-effort token refresh.
  ///
  /// ⚠️ `POST /refresh_token` **does not exist** — it 404s. Probed 2026-07-28
  /// against the live API; the public reverse-engineering repos that document
  /// it are stale or were wrong. `/auth/refresh_token` exists but returns an
  /// opaque `{"error":"Bad Request"}` for every payload shape tried, and
  /// `/oauth/token` demands client credentials we do not have.
  ///
  /// So there is no headless re-auth. The session token captured at sign-in is
  /// what drives everything, and when it finally dies the only honest recovery
  /// is another WebView sign-in — which is what [HevyAuthExpired] tells the UI
  /// to ask for. This method stays as a cheap attempt in case Hevy ships a
  /// working refresh route later, but nothing depends on it succeeding.
  Future<String> _refreshAccessToken() async {
    final refresh = await _secure.read(key: _kRefresh);
    if (refresh == null || refresh.isEmpty) {
      throw HevyAuthExpired('Sign in to Hevy again');
    }

    final http.Response resp;
    try {
      resp = await _http
          .post(Uri.parse('$_base/refresh_token'),
              headers: _headers(), body: jsonEncode({'refresh_token': refresh}))
          .timeout(const Duration(seconds: 30));
    } catch (e) {
      throw HevyError('Could not reach Hevy: $e');
    }

    // 404 = the route does not exist (the normal case today). 401/403 = the
    // token is dead. Every one of these means the same thing to the user, so
    // say the actionable thing rather than leaking a status code.
    if (resp.statusCode != 200) {
      await clear();
      throw HevyAuthExpired('Hevy sign-in expired — sign in again');
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(resp.body);
    } catch (_) {
      throw HevyError('Hevy returned a non-JSON refresh response');
    }
    if (decoded is! Map) throw HevyError('Unexpected Hevy refresh response');

    final access =
        (decoded['access_token'] ?? decoded['auth_token']) as String?;
    final newRefresh = decoded['refresh_token'] as String?;
    if (access == null || access.isEmpty) {
      throw HevyError('Hevy refresh response had no access token');
    }

    await _secure.write(key: _kAccess, value: access);
    // Hevy rotates refresh tokens — persisting the new one is REQUIRED or the
    // next refresh fails and the user gets bounced back to sign-in.
    if (newRefresh != null && newRefresh.isNotEmpty) {
      await _secure.write(key: _kRefresh, value: newRefresh);
    }
    return access;
  }

  // ── data ──────────────────────────────────────────────────────────────────

  /// Fetch workouts newer than [sinceIndex], newest-first, following Hevy's
  /// 20-per-page cursor. [sinceIndex] of 0 pulls the full history.
  ///
  /// [maxPages] bounds a first-run backfill so a huge history cannot wedge a
  /// background sync; the cursor makes the next run resume where this stopped.
  Future<List<HevyWorkout>> fetchWorkouts({
    int sinceIndex = 0,
    int maxPages = 50,
  }) async {
    var access = await _secure.read(key: _kAccess);
    final scheme = await _secure.read(key: _kScheme) ?? 'auth-token';
    access ??= await _refreshAccessToken();

    final out = <HevyWorkout>[];
    var cursor = 0;
    var retriedAuth = false;

    for (var page = 0; page < maxPages; page++) {
      final http.Response resp;
      try {
        resp = await _http
            .get(Uri.parse('$_base/workouts_batch/$cursor'),
                headers: _headers(accessToken: access, scheme: scheme))
            .timeout(const Duration(seconds: 30));
      } catch (e) {
        throw HevyError('Could not reach Hevy: $e');
      }

      // One transparent re-auth: the cached access token may simply have aged
      // out mid-sync. A second failure is a real auth problem.
      if ((resp.statusCode == 401 || resp.statusCode == 403) && !retriedAuth) {
        retriedAuth = true;
        access = await _refreshAccessToken();
        page--;
        continue;
      }
      if (resp.statusCode != 200) {
        throw HevyError('Hevy workouts failed (${resp.statusCode})');
      }

      final Object? decoded;
      try {
        decoded = jsonDecode(resp.body);
      } catch (_) {
        throw HevyError('Hevy returned a non-JSON workouts response');
      }
      if (decoded is! List) {
        throw HevyError('Unexpected Hevy workouts response shape');
      }

      final batch = decoded
          .whereType<Map>()
          .map((w) => HevyWorkout.fromJson(w.cast<String, dynamic>()))
          .toList();
      if (batch.isEmpty) break;

      var reachedKnown = false;
      for (final w in batch) {
        if (w.index <= sinceIndex) {
          reachedKnown = true;
          continue;
        }
        out.add(w);
      }
      if (reachedKnown) break; // caught up with what we already have

      cursor = batch.last.index;
      if (batch.length < 20) break; // last page
    }

    return out;
  }
}
