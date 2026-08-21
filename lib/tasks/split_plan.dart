/// Pure split logic for the batch task: distributes a list of independent
/// items across a set of workers proportionally to their weights. This is the
/// core new algorithm, so it is kept free of any I/O for direct unit testing.
library;

/// How much work a tier can take relative to Compact. Rough, not optimal —
/// a Large device gets three times the share of a Compact one, and the Tiny
/// 0.5B model takes half a Compact share.
double tierWeight(String? tierId) {
  switch (tierId) {
    case 'tiny':
      return 0.5;
    case 'balanced':
      return 2.0;
    case 'large':
      return 3.0;
    case 'compact':
    default:
      return 1.0;
  }
}

/// Distributes [itemCount] items across [weights.length] workers using the
/// largest-remainder method, so the share is proportional to each worker's
/// weight and every item is assigned exactly once.
///
/// Returns a map from worker index to the list of item indices (0-based, in
/// the original item order) assigned to that worker. Workers with weight 0
/// get nothing.
Map<int, List<int>> splitItemIndices(int itemCount, List<double> weights) {
  if (weights.isEmpty) {
    throw ArgumentError('splitItemIndices needs at least one worker');
  }
  final result = <int, List<int>>{
    for (var i = 0; i < weights.length; i++) i: <int>[],
  };
  if (itemCount <= 0) return result;

  final total = weights.fold<double>(0.0, (sum, w) => sum + w);
  if (total <= 0) return result;

  final exact = [for (final w in weights) itemCount * w / total];
  final counts = [for (final e in exact) e.floor()];
  var remaining = itemCount - counts.fold<int>(0, (sum, c) => sum + c);

  // Give the leftover items to the workers with the largest fractional part,
  // ties broken by worker order (stable).
  final order = [for (var i = 0; i < weights.length; i++) i]
    ..sort((a, b) {
      final fa = exact[a] - exact[a].floor();
      final fb = exact[b] - exact[b].floor();
      final cmp = fb.compareTo(fa);
      return cmp != 0 ? cmp : a.compareTo(b);
    });
  var cursor = 0;
  while (remaining > 0) {
    counts[order[cursor % order.length]]++;
    cursor++;
    remaining--;
  }

  // Expand counts into concrete item indices, sequentially per worker.
  var nextItem = 0;
  for (var w = 0; w < weights.length; w++) {
    result[w] = [for (var j = 0; j < counts[w]; j++) nextItem++];
  }
  return result;
}
