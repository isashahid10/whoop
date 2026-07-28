// CoachConfig — local, BYOK settings for the AI coach. The API key is stored in
// the platform keychain/keystore (flutter_secure_storage); base URL + model in
// SharedPreferences. NOTHING here ever touches our backend — the key stays on the
// device and the app calls the OpenAI-compatible provider directly.

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class CoachConfig extends ChangeNotifier {
  static const _kBaseUrl = 'coach_base_url';
  static const _kModel = 'coach_model';
  static const _kKey = 'coach_api_key'; // secure storage

  // ── Build-time seeding (personal fork) ────────────────────────────────────
  // Supplied via `--dart-define-from-file=.env`, NOT committed. `.env` is
  // gitignored (.gitignore:50) — this fork is a public GitHub repo, so a key in
  // a tracked source file would be scraped within minutes of a push. These are
  // only *seeds*: whatever the user saves in Settings always wins, and the key
  // still ends up in the platform keychain on first load.
  static const String _seedApiKey = String.fromEnvironment('COACH_API_KEY');
  static const String _seedModel = String.fromEnvironment('COACH_MODEL');

  static const String defaultBaseUrl = String.fromEnvironment(
    'COACH_BASE_URL',
    defaultValue: 'https://generativelanguage.googleapis.com/v1beta/openai',
  );

  final FlutterSecureStorage _secure = const FlutterSecureStorage();

  String _baseUrl = defaultBaseUrl;
  String _model = '';
  String? _key; // cached in-memory after load

  String get baseUrl => _baseUrl;
  String get model => _model;
  String? get apiKey => _key;
  bool get hasKey => _key != null && _key!.isNotEmpty;
  bool get configured => hasKey && _baseUrl.isNotEmpty && _model.isNotEmpty;

  /// Normalised base, no trailing slash.
  String get apiBase {
    var b = _baseUrl.trim();
    while (b.endsWith('/')) {
      b = b.substring(0, b.length - 1);
    }
    return b;
  }

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_kBaseUrl) ?? defaultBaseUrl;
    _model = prefs.getString(_kModel) ?? (_seedModel.isNotEmpty ? _seedModel : '');
    try {
      _key = await _secure.read(key: _kKey);
    } catch (_) {
      _key = null;
    }

    // First run on a build that carries a seed key: promote it into the
    // keychain and persist the seeded model, so the coach is usable with zero
    // setup. Only ever fills a GAP — an existing stored value always wins, so
    // changing the key in Settings is never undone by a later rebuild.
    if ((_key == null || _key!.isEmpty) && _seedApiKey.isNotEmpty) {
      _key = _seedApiKey;
      try {
        await _secure.write(key: _kKey, value: _seedApiKey);
      } catch (_) {
        // Keychain unavailable (rare). Key still works in-memory this session.
      }
    }
    if (prefs.getString(_kModel) == null && _seedModel.isNotEmpty) {
      await prefs.setString(_kModel, _seedModel);
    }
    if (prefs.getString(_kBaseUrl) == null) {
      await prefs.setString(_kBaseUrl, _baseUrl);
    }

    notifyListeners();
  }

  Future<void> save({String? baseUrl, String? model, String? apiKey}) async {
    final prefs = await SharedPreferences.getInstance();
    if (baseUrl != null) {
      _baseUrl = baseUrl.trim().isEmpty ? defaultBaseUrl : baseUrl.trim();
      await prefs.setString(_kBaseUrl, _baseUrl);
    }
    if (model != null) {
      _model = model.trim();
      await prefs.setString(_kModel, _model);
    }
    if (apiKey != null) {
      final k = apiKey.trim();
      _key = k.isEmpty ? null : k;
      if (k.isEmpty) {
        await _secure.delete(key: _kKey);
      } else {
        await _secure.write(key: _kKey, value: k);
      }
    }
    notifyListeners();
  }
}
