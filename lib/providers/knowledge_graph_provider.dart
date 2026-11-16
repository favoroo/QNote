import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/knowledge/kg_indexer.dart';
import 'package:qnote_flutter/core/knowledge/kg_insight_service.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';

/// 图谱索引变更流：索引完成、重建、清空后 emit，统计页卡片据此刷新
final kgChangesProvider = StreamProvider<void>((ref) {
  return KnowledgeGraphIndexer.instance.changes;
});

/// 当前手动更新的实时进度；null 表示空闲
final kgProgressProvider = Provider<ValueNotifier<KgRunProgress?>>((ref) {
  return KnowledgeGraphIndexer.instance.progress;
});

/// 统计页「关联发现」卡片数据：只取最新 3 条 new 状态洞察
final kgInsightsProvider = FutureProvider.autoDispose<List<KgInsight>>((ref) async {
  ref.watch(kgChangesProvider);
  return KnowledgeGraphInsightService.instance.top(limit: 3);
});

/// 图谱索引状态（设置页/概览用）
final kgStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  ref.watch(kgChangesProvider);
  return KnowledgeGraphIndexer.instance.status();
});
