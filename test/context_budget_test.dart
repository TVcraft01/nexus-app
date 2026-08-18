import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/ai/model_tiers.dart';
import 'package:nexus_app/tasks/batch_task_screen.dart';
import 'package:nexus_app/tasks/split_plan.dart';
import 'package:nexus_app/tasks/task_coordinator.dart';

void main() {
  group('contentCharBudget', () {
    test('reserves prompt overhead before budgeting file content', () {
      // Compact: 2048 tokens - 96 overhead = 1952 usable * 4 chars = 7808.
      expect(contentCharBudget(ModelTier.compact.contextSize), 7808);
      expect(contentCharBudget(ModelTier.balanced.contextSize), 16000);
      expect(contentCharBudget(ModelTier.large.contextSize), 32384);
    });

    test('bigger tiers get bigger budgets', () {
      final compact = contentCharBudget(ModelTier.compact.contextSize);
      final balanced = contentCharBudget(ModelTier.balanced.contextSize);
      final large = contentCharBudget(ModelTier.large.contextSize);
      expect(compact, lessThan(balanced));
      expect(balanced, lessThan(large));
    });

    test('tiny contexts never round to zero', () {
      expect(contentCharBudget(64), greaterThan(0));
    });
  });

  group('truncateContentToBudget', () {
    test('content within budget is untouched', () {
      final (text, truncated) =
          truncateContentToBudget('hello', contentCharBudget(ModelTier.compact.contextSize));
      expect(text, 'hello');
      expect(truncated, isFalse);
    });

    test('content over budget is truncated and flagged', () {
      // A file far larger than the compact tier's context budget — exactly the
      // case that used to throw LlamaOpenAIException (prompt exceeds context).
      final big = 'a' * 60000; // old fixed 60k cap was far over budget
      final (text, truncated) =
          truncateContentToBudget(big, contentCharBudget(ModelTier.compact.contextSize));
      expect(truncated, isTrue);
      expect(text.length, contentCharBudget(ModelTier.compact.contextSize));
      expect(text, startsWith('a' * 100), reason: 'truncation keeps the head');
    });

    test('truncated output is still non-empty (a summary can be produced)', () {
      final budget = contentCharBudget(ModelTier.compact.contextSize);
      final (text, truncated) = truncateContentToBudget('x' * (budget + 1), budget);
      expect(truncated, isTrue);
      expect(text, isNotEmpty);
    });
  });

  group('charCapForWorkers', () {
    WorkerInfo worker(String id, String? tier) => WorkerInfo(
          id: id,
          name: id,
          tierId: tier,
          weight: tierWeight(tier),
          isSelf: false,
        );

    test('no known workers falls back to the compact budget', () {
      expect(charCapForWorkers(const []),
          contentCharBudget(ModelTier.compact.contextSize));
    });

    test('a single large worker gets the large budget', () {
      expect(charCapForWorkers([worker('pc', 'large')]),
          contentCharBudget(ModelTier.large.contextSize));
    });

    test('mixed tiers cap at the SMALLEST worker context', () {
      // A file must fit every worker, since shares are rebalanced live.
      final cap = charCapForWorkers([worker('pc', 'large'), worker('phone', 'compact')]);
      expect(cap, contentCharBudget(ModelTier.compact.contextSize));
    });
  });
}
