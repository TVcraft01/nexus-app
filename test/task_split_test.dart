import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/tasks/split_plan.dart';
import 'package:nexus_app/tasks/task_coordinator.dart';
import 'package:nexus_app/tasks/task_protocol.dart';

void main() {
  group('tierWeight', () {
    test('maps tiers to increasing weights', () {
      expect(tierWeight('tiny'), 0.5);
      expect(tierWeight('compact'), 1.0);
      expect(tierWeight('balanced'), 2.0);
      expect(tierWeight('large'), 3.0);
    });

    test('unknown or missing tier falls back to Compact weight', () {
      expect(tierWeight(null), 1.0);
      expect(tierWeight('future-tier'), 1.0);
    });
  });

  group('splitItemIndices', () {
    test('distributes evenly across equal weights', () {
      final plan = splitItemIndices(10, [1.0, 1.0]);
      expect(plan[0]!.length, 5);
      expect(plan[1]!.length, 5);
      // Every item 0..9 assigned exactly once, in order.
      final all = [...plan[0]!, ...plan[1]!];
      expect(all, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('weights shares proportionally', () {
      // Worker 1 (weight 3) should get 3x worker 0 (weight 1).
      final plan = splitItemIndices(8, [1.0, 3.0]);
      expect(plan[0]!.length, 2);
      expect(plan[1]!.length, 6);
    });

    test('spreads the remainder by largest fractional part', () {
      // 5 items / 3 workers = 1.67 each -> 2, 2, 1.
      final plan = splitItemIndices(5, [1.0, 1.0, 1.0]);
      expect(plan[0]!.length, 2);
      expect(plan[1]!.length, 2);
      expect(plan[2]!.length, 1);
      expect(plan[0]!.length + plan[1]!.length + plan[2]!.length, 5);
    });

    test('a zero-weight worker gets nothing', () {
      final plan = splitItemIndices(6, [0.0, 1.0]);
      expect(plan[0], isEmpty);
      expect(plan[1]!.length, 6);
    });

    test('no items produces empty shares', () {
      final plan = splitItemIndices(0, [1.0, 2.0]);
      expect(plan[0], isEmpty);
      expect(plan[1], isEmpty);
    });

    test('throws with no workers', () {
      expect(() => splitItemIndices(5, []), throwsArgumentError);
    });
  });

  group('redistribute-on-failure', () {
    test('a failed worker share can be fully re-split across survivors', () {
      // 9 items split evenly 3/3/3 across three workers.
      final failedShare = splitItemIndices(9, [1.0, 1.0, 1.0])[1]!;
      expect(failedShare.length, 3);

      // Worker 1 drops out; re-split its 3 items across the two survivors.
      final reassigned = splitItemIndices(failedShare.length, [1.0, 1.0]);
      final reassignedCount =
          reassigned.values.fold<int>(0, (sum, l) => sum + l.length);
      expect(reassignedCount, failedShare.length,
          reason: 'redistribution must not lose any of the failed work');
    });

    test('uneven redistribution across unequal survivors still covers all',
        () {
      // Worker 0 (Large, weight 3) fails holding 6 of 8 items (weights 3:1).
      final initial = splitItemIndices(8, [3.0, 1.0]);
      final failedShare = initial[0]!;
      expect(failedShare.length, 6);

      // Re-split across the one survivor (weight 1) -> it takes all 6.
      final reassigned = splitItemIndices(failedShare.length, [1.0]);
      expect(reassigned[0]!.length, 6);
    });
  });

  group('BatchSummaryResult.toMarkdown', () {
    test('reassembles in original file order, not completion order', () {
      const items = [
        TaskItem(name: 'a.txt', content: 'a'),
        TaskItem(name: 'b.txt', content: 'b'),
        TaskItem(name: 'c.txt', content: 'c'),
      ];
      // Deliberately out-of-order completion.
      final result = BatchSummaryResult(
        summaries: {2: 'C', 0: 'A', 1: 'B'},
        failedIndices: const [],
      );
      final markdown = result.toMarkdown(items);

      final a = markdown.indexOf('## a.txt');
      final b = markdown.indexOf('## b.txt');
      final c = markdown.indexOf('## c.txt');
      expect(a, isNonNegative);
      expect(a, lessThan(b));
      expect(b, lessThan(c));
    });
  });
}
