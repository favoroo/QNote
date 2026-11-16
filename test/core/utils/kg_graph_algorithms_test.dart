import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/kg_graph_algorithms.dart';

void main() {
  test('两个连通分量得到不同社区，结果可复现', () {
    final edges = [
      const KgWeightedEdge(source: 'a', target: 'b', weight: 2),
      const KgWeightedEdge(source: 'b', target: 'c', weight: 1),
      const KgWeightedEdge(source: 'd', target: 'e', weight: 3),
    ];
    final first = detectCommunities(nodeIds: const ['a', 'b', 'c', 'd', 'e'], edges: edges);
    final second = detectCommunities(nodeIds: const ['e', 'd', 'c', 'b', 'a'], edges: edges);

    expect(first['a'], first['b']);
    expect(first['b'], first['c']);
    expect(first['d'], first['e']);
    expect(first['a'], isNot(first['d']));
    expect(second, first);
  });

  test('孤立节点保留自己的社区', () {
    final result = detectCommunities(
      nodeIds: const ['a', 'b', 'lonely'],
      edges: [const KgWeightedEdge(source: 'a', target: 'b', weight: 1)],
    );
    expect(result['lonely'], isNotNull);
    expect(result['a'], result['b']);
  });

  test('空图返回空映射', () {
    expect(detectCommunities(nodeIds: const [], edges: const []), isEmpty);
  });

  test('加权度按边权重求和', () {
    final edges = [
      const KgWeightedEdge(source: 'a', target: 'b', weight: 2),
      const KgWeightedEdge(source: 'a', target: 'c', weight: 3),
    ];
    expect(weightedDegree('a', edges), 5);
    expect(weightedDegree('b', edges), 2);
    expect(weightedDegree('c', edges), 3);
  });
}
