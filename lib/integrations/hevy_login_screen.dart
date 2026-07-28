// hevy_login_screen.dart — the ONE-TIME Hevy sign-in.
//
// Hevy's `/login` is gated behind reCAPTCHA v3 Enterprise. Rather than defeat
// that headlessly (the reference implementations drive a headless Chrome, which
// is both impossible on iOS and squarely an anti-automation bypass), this shows
// Hevy's OWN login page in a WebView. The user signs in as themselves, in a
// real browser, and reCAPTCHA is satisfied exactly as intended.
//
// We then read the tokens Hevy's web app stored for itself and keep the refresh
// token — `/refresh_token` carries no reCAPTCHA, so every later sync is plain
// HTTP with no browser (see hevy_client.dart).
//
// The password is typed into Hevy's page. It never enters Dart and is never
// stored anywhere by this app.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../ui/kit/kit.dart';
import 'hevy_client.dart';

class HevyLoginScreen extends StatefulWidget {
  const HevyLoginScreen({super.key});

  @override
  State<HevyLoginScreen> createState() => _HevyLoginScreenState();
}

class _HevyLoginScreenState extends State<HevyLoginScreen> {
  static const String _loginUrl = 'https://hevy.com/login';

  late final WebViewController _controller;
  bool _loading = true;
  bool _capturing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
        },
        onPageFinished: (url) async {
          if (!mounted) return;
          setState(() => _loading = false);
          // Sign-in bounces off /login once it succeeds. Poll from then on:
          // the tokens land in web storage asynchronously, a little after
          // navigation completes.
          if (!url.contains('/login')) await _tryCaptureTokens();
        },
        onWebResourceError: (e) {
          if (mounted) setState(() => _error = e.description);
        },
      ))
      ..loadRequest(Uri.parse(_loginUrl));
  }

  /// Read the tokens Hevy's web app persisted for itself.
  ///
  /// Key names differ across their releases, so this scans localStorage AND
  /// sessionStorage for anything token-shaped rather than hardcoding one key —
  /// a rename upstream would otherwise silently break sign-in.
  Future<void> _tryCaptureTokens() async {
    if (_capturing) return;
    _capturing = true;
    try {
      for (var attempt = 0; attempt < 12; attempt++) {
        final raw = await _controller.runJavaScriptReturningResult('''
          (function () {
            var out = {};
            function scan(store) {
              if (!store) return;
              for (var i = 0; i < store.length; i++) {
                var k = store.key(i);
                var v = store.getItem(k);
                if (!v) continue;
                var lk = k.toLowerCase();
                if (lk.indexOf('refresh') >= 0) out.refresh = out.refresh || v;
                if (lk.indexOf('auth') >= 0 || lk.indexOf('access') >= 0 ||
                    lk.indexOf('token') >= 0) {
                  try {
                    var p = JSON.parse(v);
                    if (p && typeof p === 'object') {
                      out.refresh = out.refresh || p.refresh_token || p.refreshToken;
                      out.access  = out.access  || p.access_token  || p.accessToken ||
                                    p.auth_token || p.authToken;
                      return;
                    }
                  } catch (e) { /* plain string token */ }
                  out.access = out.access || v;
                }
              }
            }
            try { scan(window.localStorage); } catch (e) {}
            try { scan(window.sessionStorage); } catch (e) {}
            return JSON.stringify(out);
          })();
        ''');

        final map = _decodeJsResult(raw);
        final refresh = map['refresh'];
        if (refresh != null && refresh.isNotEmpty) {
          await HevyClient()
              .storeTokens(refreshToken: refresh, accessToken: map['access']);
          if (mounted) Navigator.of(context).pop(true);
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }

      if (mounted) {
        setState(() => _error =
            'Signed in, but no Hevy session token was found. Their web app may '
            'have changed how it stores sessions.');
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      _capturing = false;
    }
  }

  /// `runJavaScriptReturningResult` returns a String on iOS but may hand back a
  /// double-encoded JSON string; normalise both shapes.
  static Map<String, String?> _decodeJsResult(Object? raw) {
    try {
      Object? v = raw;
      if (v is String) {
        v = jsonDecode(v);
        if (v is String) v = jsonDecode(v); // double-encoded
      }
      if (v is Map) {
        return {
          'refresh': v['refresh'] as String?,
          'access': v['access'] as String?,
        };
      }
    } catch (_) {/* not ready yet */}
    return const {'refresh': null, 'access': null};
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.surface,
      appBar: AppBar(
        title: const Text('Sign in to Hevy'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(false),
        ),
      ),
      body: Column(
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(Sp.x4),
              child: ProCard(
                child: Row(children: [
                  AppIcon(OsIcon.info, size: 18, color: AppColors.bad),
                  const SizedBox(width: Sp.x3),
                  Expanded(child: Text(_error!, style: AppText.captionMuted)),
                ]),
              ),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(Sp.x4),
              child: Text(
                'Your password goes to Hevy directly and is never stored by this '
                'app. Only the session token is kept, on this device.',
                style: AppText.captionMuted,
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
