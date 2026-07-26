// Two small guards for the same class of bug: state written back from a future
// that is no longer the one the screen is waiting for.
//
//   • [LatestRequestGate]  — a NEWER request has started; drop the older reply.
//   • [setStateIfMounted]  — the State is GONE; drop the reply entirely.
//
// Both exist because `await` has no memory: the continuation runs whenever the
// future happens to complete, with no relationship to what the widget still
// wants (or to whether it still exists).

import 'package:flutter/widgets.dart';

/// Request-generation guard for widgets that can have several fetches in
/// flight at once (e.g. an `insightsRevision` listener firing again while the
/// previous load is still awaiting).
///
/// Futures do NOT complete in the order they were started: a cross-day rollup
/// followed immediately by a derive leaves two loads racing, and the LATER one
/// can finish FIRST — after which the earlier, staler payload lands last and
/// wins. That is exactly the stale-day bug the revision listener was added to
/// fix, reintroduced by the listener itself. Take a token before awaiting and
/// drop the result if a newer request has started since.
///
///     final token = _gate.begin();
///     final d = await load();
///     if (!mounted || !_gate.isCurrent(token)) return;   // superseded
class LatestRequestGate {
  int _gen = 0;

  /// Start a request and get its token. Every earlier token is now stale.
  int begin() => ++_gen;

  /// True only for the most recently started request.
  bool isCurrent(int token) => token == _gen;
}

/// `setState` that is a no-op once the State has been disposed.
///
/// Any `setState` reached AFTER an `await` needs this. A provider call can
/// block for up to two minutes; the user pops the screen; the call then errors
/// (or its progress callbacks fire) and the handler crashes the frame with
/// "setState() called after dispose()". The `mounted` check is not defensive
/// noise — for a long await it is the normal case.
extension SafeSetState<W extends StatefulWidget> on State<W> {
  void setStateIfMounted(VoidCallback fn) {
    if (mounted) {
      // ignore: invalid_use_of_protected_member
      setState(fn);
    }
  }
}
