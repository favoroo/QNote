import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/agent/services/quick_prompt_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';

/// 常用提示词列表（用户自定义，持久化于 app_configs）
///
/// 数据经 [QuickPromptService]（单 key JSON + 内存缓存）；
/// 小Q Agent 经 VFS `/quick_prompts/prompts.md` 写入时广播事件，
/// 此处监听后刷新缓存与 UI，保证弹窗与管理页双向实时同步
final quickPromptListProvider =
    AsyncNotifierProvider<QuickPromptNotifier, List<String>>(() {
      return QuickPromptNotifier();
    });

class QuickPromptNotifier extends AsyncNotifier<List<String>> {
  void _onWorkspaceChange(WorkspaceChangeEvent event) {
    if (event.path.startsWith('/quick_prompts/')) {
      // VFS 写入走了 QuickPromptService.setPrompts（缓存已更新），
      // 但云同步导入等外部来源需手动失效缓存
      QuickPromptService.instance.refresh();
      ref.invalidateSelf();
    }
  }

  @override
  Future<List<String>> build() async {
    WorkspaceEventBus.instance.addListener(_onWorkspaceChange);
    ref.onDispose(
      () => WorkspaceEventBus.instance.removeListener(_onWorkspaceChange),
    );
    return QuickPromptService.instance.getPrompts();
  }

  /// 追加一条提示词
  Future<void> addPrompt(String text) async {
    await QuickPromptService.instance.addPrompt(text);
    ref.invalidateSelf();
  }

  /// 编辑指定索引的提示词
  Future<void> updatePrompt(int index, String text) async {
    await QuickPromptService.instance.updatePrompt(index, text);
    ref.invalidateSelf();
  }

  /// 删除指定索引的提示词
  Future<void> deletePrompt(int index) async {
    await QuickPromptService.instance.deletePrompt(index);
    ref.invalidateSelf();
  }
}
