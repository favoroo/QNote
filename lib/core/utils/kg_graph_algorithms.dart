import 'dart:math' as math;

/// 带权无向边，供社区发现使用
class KgWeightedEdge {
  final String source;
  final String target;
  final double weight;

  const KgWeightedEdge({required this.source, required this.target, required this.weight});
}

/// 轻量社区发现：确定性的标签传播。
///
/// 个人图谱量级（数千节点）不需要完整 Louvain 的复杂度；标签传播在
/// 加权无向图上迭代收敛快，固定排序后结果可复现。后续若主题质量不够，
/// 可在不改变调用方的前提下替换成 Louvain。
Map<String, int> detectCommunities({
  required Iterable<String> nodeIds,
  required Iterable<KgWeightedEdge> edges,
  int maxIterations = 20,
}) {
  final ids = nodeIds.where((id) => id.isNotEmpty).toSet().toList()..sort();
  if (ids.isEmpty) return const {};

  final adjacency = <String, Map<String, double>>{for (final id in ids) id: <String, double>{}};
  for (final edge in edges) {
    if (!adjacency.containsKey(edge.source) || !adjacency.containsKey(edge.target)) continue;
    if (edge.source == edge.target || edge.weight <= 0) continue;
    adjacency[edge.source]![edge.target] = (adjacency[edge.source]![edge.target] ?? 0) + edge.weight;
    adjacency[edge.target]![edge.source] = (adjacency[edge.target]![edge.source] ?? 0) + edge.weight;
  }

  // 初始每个节点一个社区；标签用节点 id，平票时按字典序取最小，保证可复现
  final labels = <String, String>{for (final id in ids) id: id};
  for (var iteration = 0; iteration < maxIterations; iteration++) {
    var changed = false;
    for (final id in ids) {
      final weights = <String, double>{};
      for (final entry in adjacency[id]!.entries) {
        final label = labels[entry.key]!;
        weights[label] = (weights[label] ?? 0) + entry.value;
      }
      if (weights.isEmpty) continue;
      var bestLabel = labels[id]!;
      var bestWeight = weights[bestLabel] ?? 0;
      for (final entry in weights.entries) {
        if (entry.value > bestWeight || (entry.value == bestWeight && entry.key.compareTo(bestLabel) < 0)) {
          bestLabel = entry.key;
          bestWeight = entry.value;
        }
      }
      if (bestLabel != labels[id]) {
        labels[id] = bestLabel;
        changed = true;
      }
    }
    if (!changed) break;
  }

  // 按社区规模降序重新编号，0 是最大的社区；同规模按代表性 id 排序
  final groups = <String, List<String>>{};
  for (final id in ids) {
    groups.putIfAbsent(labels[id]!, () => []).add(id);
  }
  final sortedGroups = groups.values.toList()
    ..sort((a, b) {
      final bySize = b.length.compareTo(a.length);
      if (bySize != 0) return bySize;
      final aKey = a.toList()..sort();
      final bKey = b.toList()..sort();
      return aKey.first.compareTo(bKey.first);
    });

  final result = <String, int>{};
  for (var i = 0; i < sortedGroups.length; i++) {
    for (final id in sortedGroups[i]) {
      result[id] = i;
    }
  }
  return result;
}

/// 加权度：社区命名/重要性排序用
double weightedDegree(String nodeId, Iterable<KgWeightedEdge> edges) {
  var sum = 0.0;
  for (final edge in edges) {
    if (edge.source == nodeId || edge.target == nodeId) {
      sum += math.max(0, edge.weight);
    }
  }
  return sum;
}
