import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/agent_memory.dart';

/// 小Q长期记忆列表（固定包含 user / agent 两个分类的文档，内容可能为空）
final agentMemoryListProvider =
    AsyncNotifierProvider<AgentMemoryNotifier, List<AgentMemoryDocument>>(() {
  return AgentMemoryNotifier();
});

/// 小Q长期记忆管理 Notifier
///
/// 读写统一走 [ConfigRepository]（app_configs 键值存储，自动写同步日志参与云同步）；
/// 小Q Agent 经 VFS 写入 `/memory/*.md` 时会广播事件，此处监听后自动刷新，
/// 保证"小Q记忆"页面与小Q的写入双向实时同步
class AgentMemoryNotifier extends AsyncNotifier<List<AgentMemoryDocument>> {
  void _onWorkspaceChange(WorkspaceChangeEvent event) {
    if (event.path.startsWith('/memory/')) {
      ref.invalidateSelf();
    }
  }

  @override
  Future<List<AgentMemoryDocument>> build() async {
    // addListener 内部按引用去重，build 重复执行不会重复注册
    WorkspaceEventBus.instance.addListener(_onWorkspaceChange);
    ref.onDispose(
      () => WorkspaceEventBus.instance.removeListener(_onWorkspaceChange),
    );
    return ConfigRepository.instance.getAllAgentMemories();
  }

  /// 按分类取当前文档（构建失败或加载中时返回空文档兜底）
  AgentMemoryDocument _documentOf(
    List<AgentMemoryDocument>? docs,
    String category,
  ) {
    final matched = docs?.where((d) => d.category == category).firstOrNull;
    return matched ?? AgentMemoryDocument(category: category);
  }

  /// 新增一条记忆（追加到末尾）；超限抛出异常由 UI 捕获提示
  Future<void> addEntry(String category, String text) async {
    final entry = text.trim();
    if (entry.isEmpty) return;
    final docs = state.valueOrNull;
    final doc = _documentOf(docs, category);
    final updated = doc.copyWith(
      content: doc.content.trim().isEmpty
          ? '- $entry'
          : '${doc.content.trimRight()}\n- $entry',
    );
    await _save(updated);
  }

  /// 修订一条记忆（按原文本精准匹配替换）
  Future<void> updateEntry(String category, String oldText, String newText) async {
    final doc = _documentOf(state.valueOrNull, category);
    final oldLine = oldText.trim().startsWith('- ') ? oldText.trim() : '- ${oldText.trim()}';
    final newLine = newText.trim().isEmpty ? '' : '- ${newText.trim()}';
    final content = doc.content;
    if (!content.contains(oldLine)) {
      throw Exception('未找到要修改的记忆条目');
    }
    final updated = doc.copyWith(
      content: content.replaceFirst(oldLine, newLine).trim(),
    );
    await _save(updated);
  }

  /// 删除一条记忆（按内容精准匹配移除该行）
  Future<void> deleteEntry(String category, String text) async {
    final doc = _documentOf(state.valueOrNull, category);
    final line = text.trim().startsWith('- ') ? text.trim() : '- ${text.trim()}';
    final lines = doc.content
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && l != line)
        .toList();
    await _save(doc.copyWith(content: lines.join('\n')));
  }

  /// 清空指定分类的全部记忆
  Future<void> clear(String category) async {
    await _save(AgentMemoryDocument(category: category, content: ''));
  }

  Future<void> _save(AgentMemoryDocument doc) async {
    final maxChars = AgentMemoryCategory.maxChars(doc.category);
    if (doc.content.length > maxChars) {
      throw Exception('记忆容量已超限（${doc.content.length}/$maxChars 字符），请先删减或整合条目');
    }
    await ConfigRepository.instance.saveAgentMemory(doc);
    ref.invalidateSelf();
  }
}
