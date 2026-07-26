// CoachEngine._trimHistory — the resent-context size bound.
//
// The trim drops WHOLE turns from the oldest end specifically so that a `tool`
// message never outlives the assistant turn whose `tool_calls` it answers:
// OpenAI-compatible providers reject an orphaned tool message with a 400, and
// once the history is persisted that rejection repeats on every subsequent turn
// of the session — the conversation is bricked, not just one reply.
//
// That invariant used to be a side effect of the loop bounds rather than
// something the code enforced. Both loops stop at `length > 1`, so a single
// turn larger than the whole byte budget walked the history down to exactly one
// element and left it there — and if that survivor was the `tool` half of a
// pair, the very orphan the method exists to prevent was what got sent.
import 'package:flutter_test/flutter_test.dart';
import 'package:openstrap_edge/coach/coach_config.dart';
import 'package:openstrap_edge/coach/coach_engine.dart';
import 'package:openstrap_edge/data/local_repository.dart';

class _FakeRepo extends LocalRepository {}

/// A message whose encoded size comfortably exceeds the whole history budget,
/// so the trim is forced to walk all the way down.
Map<String, dynamic> _huge(String role) => {
      'role': role,
      'content': 'x' * (CoachEngine.kMaxHistoryChars + 1000),
    };

void main() {
  late CoachEngine engine;

  setUp(() {
    engine = CoachEngine(config: CoachConfig(), api: _FakeRepo());
  });

  group('CoachEngine history trimming never strands a tool message', () {
    test('an oversized assistant turn does not leave its tool reply orphaned',
        () {
      // The exact reachable shape: one assistant turn bigger than the entire
      // budget, followed by the tool result answering its tool_calls. Dropping
      // the assistant strands the tool with nothing to pair against.
      engine.debugHistory.addAll([
        _huge('assistant'),
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'sleep data'},
      ]);

      engine.debugTrimHistory();

      // Pre-fix this asserted-out: the history was exactly [tool].
      expect(
        engine.debugHistory.any((m) => m['role'] == 'tool'),
        isFalse,
        reason: 'a tool message must never survive without its assistant turn',
      );
    });

    test('the surviving history never BEGINS with a tool message', () {
      engine.debugHistory.addAll([
        {'role': 'user', 'content': 'how did I sleep?'},
        _huge('assistant'),
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'sleep data'},
        {'role': 'assistant', 'content': 'You slept well.'},
      ]);

      engine.debugTrimHistory();

      if (engine.debugHistory.isNotEmpty) {
        expect(engine.debugHistory.first['role'], isNot('tool'));
      }
    });

    test('a history already under the ceiling is left completely alone', () {
      // Guards against over-correction: the orphan sweep must not eat a
      // legitimate, correctly-paired turn that was never over budget.
      final intact = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'how did I sleep?'},
        {'role': 'assistant', 'content': null, 'tool_calls': const []},
        {'role': 'tool', 'tool_call_id': 'call_1', 'content': 'sleep data'},
        {'role': 'assistant', 'content': 'You slept well.'},
      ];
      engine.debugHistory.addAll(intact);

      engine.debugTrimHistory();

      expect(engine.debugHistory, hasLength(intact.length));
      expect(engine.debugHistory.first['role'], 'user');
      expect(engine.debugHistory.any((m) => m['role'] == 'tool'), isTrue);
    });

    test('trimming a long well-formed history keeps a user message at the head',
        () {
      for (var i = 0; i < 40; i++) {
        engine.debugHistory.addAll([
          {'role': 'user', 'content': 'q$i ${'x' * 4000}'},
          {'role': 'assistant', 'content': null, 'tool_calls': const []},
          {'role': 'tool', 'tool_call_id': 'c$i', 'content': 'r$i'},
          {'role': 'assistant', 'content': 'a$i'},
        ]);
      }

      engine.debugTrimHistory();

      expect(engine.debugHistory, isNotEmpty);
      expect(engine.debugHistory.first['role'], 'user');
    });
  });
}
