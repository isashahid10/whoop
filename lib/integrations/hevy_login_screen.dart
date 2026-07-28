// hevy_login_screen.dart — the ONE-TIME Hevy sign-in.
//
// Hevy's `/login` is gated behind reCAPTCHA v3 Enterprise. Rather than defeat
// that headlessly (the reference implementations drive a headless Chrome, which
// is both impossible on iOS and squarely an anti-automation bypass), this shows
// Hevy's OWN login page in a WebView. The user signs in as themselves, in a
// real browser, and reCAPTCHA is satisfied exactly as intended.
//
// We then capture the session token Hevy's web app issued to itself and keep
// the refresh token — `/refresh_token` carries no reCAPTCHA, so every later
// sync is plain HTTP with no browser (see hevy_client.dart).
//
// The password is typed into Hevy's page. It never enters Dart and is never
// stored anywhere by this app.
//
// CAPTURE STRATEGY (three nets, because one is not enough)
//
//   1. NETWORK INTERCEPT — a JS shim wraps fetch/XHR before the page's own code
//      runs and harvests any token-shaped field out of API responses. This is
//      the most reliable net: it does not care where the app later decides to
//      persist the token, only that it came over the wire.
//   2. STORAGE SCAN — localStorage + sessionStorage + cookies, recursing into
//      JSON values. Catches the case where the user was ALREADY signed in and
//      no login request happens at all.
//   3. INDEXEDDB SCAN — OAuth SDKs (Apple/Google sign-in especially) routinely
//      persist sessions in IndexedDB rather than localStorage, so a scan that
//      skips it finds nothing for exactly the users who used a social login.
//
// Polling is continuous rather than page-load-triggered: Hevy's web app is a
// SPA, so after sign-in it routes client-side and `onPageFinished` may never
// fire again.
//
// When all three nets come up empty we show WHICH KEYS EXIST rather than a bare
// failure — a silent "didn't work" is unfixable, a key list is a five-minute fix.

import 'dart:async';
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
  Timer? _poll;
  bool _loading = true;
  bool _done = false;
  String? _error;
  String? _diagnostic;

  /// Wraps fetch + XHR so any token-bearing API response is harvested
  /// regardless of where the app later persists it. Also kicks off an async
  /// IndexedDB dump into a global the poller reads.
  static const String _interceptorJs = r'''
(function () {
  if (window.__osHook) return;
  window.__osHook = true;
  window.__osTokens = {};
  window.__osIdb = {};

  function harvest(o, depth) {
    if (!o || depth > 6) return;
    try {
      if (Array.isArray(o)) { for (var i = 0; i < o.length; i++) harvest(o[i], depth + 1); return; }
      if (typeof o !== 'object') return;
      for (var k in o) {
        var v = o[k]; var lk = String(k).toLowerCase();
        if (typeof v === 'string' && v.length > 12) {
          if (lk.indexOf('refresh') >= 0) window.__osTokens.refresh = v;
          else if (lk.indexOf('access') >= 0 || lk === 'auth_token' ||
                   lk === 'authtoken' || lk === 'id_token' || lk === 'idtoken') {
            window.__osTokens.access = v;
          }
        } else if (v && typeof v === 'object') harvest(v, depth + 1);
      }
    } catch (e) {}
  }
  window.__osHarvest = harvest;

  // THE RELIABLE NET: capture the `auth-token` REQUEST header Hevy's own web
  // app sends to its API. Whatever it puts there is, by definition, a token the
  // API accepts — no guessing which stored blob is the session, and no
  // dependence on a refresh endpoint (`/refresh_token` returns 404; it does not
  // exist, whatever the public reverse-engineering repos claim).
  function grabHeader(k, v) {
    try {
      if (String(k).toLowerCase() === 'auth-token' && v && String(v).length > 8) {
        window.__osTokens.access = String(v);
      }
    } catch (e) {}
  }

  var of = window.fetch;
  if (of) {
    window.fetch = function (input, init) {
      try {
        var h = (init && init.headers) || (input && input.headers);
        if (h) {
          if (typeof h.forEach === 'function') h.forEach(function (v, k) { grabHeader(k, v); });
          else if (typeof h.get === 'function') grabHeader('auth-token', h.get('auth-token'));
          else for (var k in h) grabHeader(k, h[k]);
        }
      } catch (e) {}
      var p = of.apply(this, arguments);
      try {
        p.then(function (r) {
          try {
            r.clone().text().then(function (t) {
              try { harvest(JSON.parse(t), 0); } catch (e) {}
            }).catch(function () {});
          } catch (e) {}
          return r;
        }).catch(function () {});
      } catch (e) {}
      return p;
    };
  }

  try {
    var osrh = XMLHttpRequest.prototype.setRequestHeader;
    XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
      grabHeader(k, v);
      return osrh.apply(this, arguments);
    };
    var os = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function () {
      try {
        this.addEventListener('load', function () {
          try { harvest(JSON.parse(this.responseText), 0); } catch (e) {}
        });
      } catch (e) {}
      return os.apply(this, arguments);
    };
  } catch (e) {}

  // IndexedDB — where Apple/Google sign-in SDKs usually put the session.
  try {
    if (indexedDB && indexedDB.databases) {
      indexedDB.databases().then(function (dbs) {
        (dbs || []).forEach(function (meta) {
          try {
            var req = indexedDB.open(meta.name);
            req.onsuccess = function () {
              var db = req.result;
              try {
                Array.prototype.slice.call(db.objectStoreNames).forEach(function (sn) {
                  try {
                    var tx = db.transaction(sn, 'readonly');
                    var all = tx.objectStore(sn).getAll();
                    all.onsuccess = function () {
                      try {
                        window.__osIdb[meta.name + '/' + sn] = 1;
                        (all.result || []).forEach(function (row) { harvest(row, 0); });
                      } catch (e) {}
                    };
                  } catch (e) {}
                });
              } catch (e) {}
            };
          } catch (e) {}
        });
      }).catch(function () {});
    }
  } catch (e) {}
})();
''';

  /// Reads every net and returns `{refresh, access, keys}`. `keys` is the
  /// diagnostic: the key NAMES present (never their values).
  static const String _probeJs = r'''
(function () {
  var out = { keys: [], candidates: [] };
  try {
    if (window.__osTokens) {
      if (window.__osTokens.refresh) out.refresh = window.__osTokens.refresh;
      if (window.__osTokens.access) out.access = window.__osTokens.access;
    }
  } catch (e) {}

  function scan(store, tag) {
    if (!store) return;
    for (var i = 0; i < store.length; i++) {
      var k = store.key(i); var v = store.getItem(k);
      if (!k) continue;
      out.keys.push(tag + ':' + k);
      if (!v) continue;
      var lk = k.toLowerCase();
      try {
        var p = JSON.parse(v);
        if (p && typeof p === 'object' && window.__osHarvest) window.__osHarvest(p, 0);
      } catch (e) {
        if (lk.indexOf('refresh') >= 0 && v.length > 12) out.refresh = out.refresh || v;
        else if ((lk.indexOf('token') >= 0 || lk.indexOf('auth') >= 0) && v.length > 12) {
          out.access = out.access || v;
        }
      }
    }
  }
  try { scan(window.localStorage, 'ls'); } catch (e) {}
  try { scan(window.sessionStorage, 'ss'); } catch (e) {}

  // COOKIES — where Hevy actually keeps the session (`access-token` and
  // `auth2.0-token`, confirmed on device 2026-07-28). The first version of this
  // read cookie NAMES for the diagnostic and never their VALUES, which is
  // exactly why capture kept failing while the token sat in plain sight.
  try {
    (document.cookie || '').split(';').forEach(function (c) {
      var eq = c.indexOf('=');
      if (eq < 0) return;
      var k = c.slice(0, eq).trim();
      var v = c.slice(eq + 1).trim();
      if (!k) return;
      out.keys.push('ck:' + k);
      if (!v || v.length < 12) return;
      try { v = decodeURIComponent(v); } catch (e) {}
      var lk = k.toLowerCase();
      if (lk.indexOf('refresh') >= 0) out.refresh = out.refresh || v;
      if (lk.indexOf('token') >= 0 || lk.indexOf('auth') >= 0) {
        out.candidates.push(v);
      }
    });
  } catch (e) {}
  try {
    Object.keys(window.__osIdb || {}).forEach(function (k) { out.keys.push('idb:' + k); });
  } catch (e) {}

  // Re-read after the storage scan: scan() feeds JSON blobs back through
  // harvest(), which may have populated __osTokens just now.
  try {
    if (window.__osTokens) {
      out.refresh = out.refresh || window.__osTokens.refresh;
      out.access = out.access || window.__osTokens.access;
      if (window.__osTokens.access) out.candidates.unshift(window.__osTokens.access);
    }
  } catch (e) {}
  // De-dupe and bound — each candidate costs one validation request.
  try {
    var seen = {}; var uniq = [];
    out.candidates.forEach(function (c) {
      if (c && !seen[c]) { seen[c] = 1; uniq.push(c); }
    });
    out.candidates = uniq.slice(0, 12);
  } catch (e) {}
  return JSON.stringify(out);
})();
''';

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() => _loading = true);
          // Inject BEFORE the page's own scripts run, so the login request is
          // already wrapped by the time it fires.
          _controller.runJavaScript(_interceptorJs).catchError((_) {});
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
          _controller.runJavaScript(_interceptorJs).catchError((_) {});
        },
        onWebResourceError: (e) {
          // Sub-resource errors are noise; only surface a main-frame failure.
          if (e.isForMainFrame == true && mounted) {
            setState(() => _error = e.description);
          }
        },
      ))
      ..loadRequest(Uri.parse(_loginUrl));

    // Drop anything held from a previous attempt before capturing again. A
    // stale token makes isLinked true, which sends sync down the auth path and
    // reports "sign-in expired" while the user is plainly signed in — the exact
    // confusing failure this screen exists to resolve.
    HevyClient().clear();

    // Continuous poll: Hevy's web app is a SPA, so onPageFinished may never
    // fire again after sign-in routes client-side.
    _poll = Timer.periodic(const Duration(milliseconds: 900), (_) => _probe());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _probe({bool manual = false}) async {
    if (_done) return;
    try {
      final raw = await _controller.runJavaScriptReturningResult(_probeJs);
      final map = _decode(raw);
      final refresh = map['refresh'] as String?;
      final access = map['access'] as String?;

      // VALIDATE rather than guess. Several cookies look token-shaped
      // (`access-token`, `auth2.0-token`, plus analytics junk), and picking by
      // name is how the last two attempts went wrong. Ask the API which one it
      // actually accepts — a 200 is proof, a name match is a hypothesis.
      final candidates = <String>[
        if (access != null && access.isNotEmpty) access,
        ...?(map['candidates'] as List?)?.cast<String>(),
      ];

      for (final c in candidates) {
        if (!await HevyClient.tokenWorks(c)) continue;
        _done = true;
        _poll?.cancel();
        await HevyClient().storeTokens(refreshToken: refresh, accessToken: c);
        if (mounted) Navigator.of(context).pop(true);
        return;
      }

      if (manual) {
        final keys = (map['keys'] as List?)?.cast<String>() ?? const <String>[];
        setState(() {
          _diagnostic = keys.isEmpty
              ? 'No web storage found at all — the page may still be loading.'
              : 'No session token found yet. Storage keys present:\n\n'
                  '${keys.take(40).join('\n')}';
        });
      }
    } catch (_) {
      // JS not ready on this navigation; the next tick retries.
    }
  }

  static Map<String, Object?> _decode(Object? raw) {
    try {
      Object? v = raw;
      if (v is String) {
        v = jsonDecode(v);
        if (v is String) v = jsonDecode(v); // iOS can double-encode
      }
      if (v is Map) return v.cast<String, Object?>();
    } catch (_) {/* not ready */}
    return const {};
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
        actions: [
          // Explicit escape hatch: if the automatic poll misses it, this both
          // retries and reports what IS in storage, which turns an unfixable
          // "it didn't work" into an actionable key list.
          TextButton(
            onPressed: () => _probe(manual: true),
            child: const Text('Capture'),
          ),
        ],
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
          if (_diagnostic != null)
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.all(Sp.x4),
              padding: const EdgeInsets.all(Sp.x3),
              decoration: BoxDecoration(
                color: AppColors.surfaceSunk,
                borderRadius: BorderRadius.circular(R.card),
              ),
              child: SingleChildScrollView(
                child: SelectableText(_diagnostic!,
                    style: AppText.captionMuted.copyWith(fontSize: 11)),
              ),
            ),
          if (_loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(child: WebViewWidget(controller: _controller)),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(Sp.x4),
              child: Text(
                'Sign in above. This closes by itself once Hevy hands over a '
                'session. Your password goes to Hevy directly and is never '
                'stored by this app.',
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
