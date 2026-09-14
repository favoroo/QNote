import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_undo_entry.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/utils/widget_utils.dart';
import 'package:qnote_flutter/models/agent_memory.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/providers/journal_provider.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/todo_folder_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';

// ==========================================
// Agent 执行管线共享支撑件
// AI 主会话（ai_provider）与全局悬浮小Q（floating_q_provider）共用，
// 抽取自 CurrentChatNotifier.sendMessage / rollbackToMessage，保持行为一致
// ==========================================

/// 按 VFS 路径前缀联动刷新对应业务数据（AgentLoop afterToolCall 钩子用）
void refreshWorkspaceSideEffects(Ref ref, String rawPath) {
  final targetPath = rawPath.toLowerCase();

  // 1. 待办系统联动刷新
  if (targetPath.startsWith('/todos')) {
    try {
      ref.read(todoListProvider.notifier).refresh();
      ref.read(todoFolderListProvider.notifier).refresh();
      ref.invalidate(completedTodoListProvider);
      ref.invalidate(upcomingRemindersProvider);
      WidgetUtils.updateHomeWidgets();
    } catch (_) {}
  }

  // 2. 日记与时间线流水联动刷新
  if (targetPath.startsWith('/journal') || targetPath.startsWith('/timeline')) {
    try {
      ref.read(diaryListProvider.notifier).refresh();
      ref.invalidate(journalByDateProvider);
      // 日记复用 notes/folders 表存储（JournalService），删除日记只是硬删数据库行，
      // 笔记树的 noteListProvider/folderListProvider 仍是内存旧缓存，
      // 不刷新会导致笔记页残留"内容被清空"的已删日记节点
      ref.read(noteListProvider.notifier).refresh();
      ref.read(folderListProvider.notifier).refresh();
    } catch (_) {}
  }

  // 3. 笔记知识库联动刷新
  if (targetPath.startsWith('/notes')) {
    try {
      ref.read(noteListProvider.notifier).refresh();
      // 文件夹列表同样需要联动（如 AI 新建/移动笔记到文件夹）
      ref.read(folderListProvider.notifier).refresh();
    } catch (_) {}
  }
}

/// 撤回恢复后全量刷新受影响的业务数据（对齐 [refreshWorkspaceSideEffects] 的联动逻辑，
/// 恢复写入不走 AgentLoop 的 afterToolCall 钩子，需手动补齐）
void refreshAllBusinessData(Ref ref) {
  try {
    ref.read(todoListProvider.notifier).refresh();
    ref.read(todoFolderListProvider.notifier).refresh();
    ref.invalidate(completedTodoListProvider);
    ref.invalidate(upcomingRemindersProvider);
    ref.read(diaryListProvider.notifier).refresh();
    ref.invalidate(journalByDateProvider);
    // 日记复用 notes/folders 表存储，笔记树同样需要刷新
    ref.read(noteListProvider.notifier).refresh();
    ref.read(folderListProvider.notifier).refresh();
    WidgetUtils.updateHomeWidgets();
  } catch (_) {}
}

/// 判断虚拟路径当前是否处于"不存在"（读取失败或空态占位文案）
Future<bool> isWorkspacePathAbsent(String path) async {
  try {
    final content = await VirtualWorkspaceService.instance.readFile(path);
    // 占位文案特征串统一由 VFS 维护，避免两处各写一份导致判定漂移
    return VirtualWorkspaceService.isPlaceholderText(content);
  } catch (_) {
    return true;
  }
}

/// 逆序恢复一组工作区变更快照（后写入的先撤销）：
/// existedBefore → 写回旧内容；本轮新建的 → 删除文件。
/// 返回 `(恢复成功处数, 恢复失败处数)`。
Future<(int restored, int failed)> restoreWorkspaceUndoEntries(
  Ref ref,
  List<WorkspaceUndoEntry> entries,
) async {
  int restored = 0;
  int failed = 0;
  for (final entry in entries.reversed) {
    try {
      if (entry.existedBefore) {
        if (entry.beforeContent != null) {
          await VirtualWorkspaceService.instance.writeFile(
            entry.path,
            entry.beforeContent!,
          );
          refreshWorkspaceSideEffects(ref, entry.path);
          restored++;
        }
      } else {
        // 本轮新建的文件应删除；若已不存在（读取失败或占位文案）则状态已符合，无需删除
        if (!await isWorkspacePathAbsent(entry.path)) {
          await VirtualWorkspaceService.instance.deleteFile(entry.path);
        }
        refreshWorkspaceSideEffects(ref, entry.path);
        restored++;
      }
    } catch (e) {
      failed++;
      LoggerService.instance.logAI(
        '撤回恢复工作区变更失败: ${entry.path}, $e',
        level: LogLevel.warning,
      );
    }
  }
  return (restored, failed);
}

/// 组装基础动态环境上下文（当前时间 + 用户资料），[extraSections] 中的
/// 额外段落（如关联数据导出、页面上下文说明）依次以 `- ` 条目追加在末尾
Future<String> buildBaseDynamicContext({
  List<String> extraSections = const [],
}) async {
  final now = DateTime.now();
  final buffer = StringBuffer();

  // 当前时间（中文格式，如 "2026/05/17 星期日 09:31"）
  const weekdays = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
  final timeContext =
      '${DateFormat('yyyy/MM/dd').format(now)} ${weekdays[now.weekday % 7]} ${DateFormat('HH:mm').format(now)}';
  buffer.writeln('- 当前时间: $timeContext');

  // 用户资料（补充计算年龄与最新体重）
  final userProfile = await ConfigRepository.instance.getUserProfile();
  if (userProfile != null &&
      ((userProfile.name != null && userProfile.name!.isNotEmpty) ||
          (userProfile.nickname != null && userProfile.nickname!.isNotEmpty) ||
          (userProfile.birthday != null && userProfile.birthday!.isNotEmpty))) {
    final Map<String, dynamic> enrichedProfile = {
      'id': userProfile.id,
      'name': userProfile.name,
      'nickname': userProfile.nickname,
      'birthday': userProfile.birthday,
      'height': userProfile.height,
      'gender': userProfile.gender,
      'otherInfo': userProfile.otherInfo,
      'customFields': userProfile.customFields,
    };

    if (userProfile.birthday != null && userProfile.birthday!.isNotEmpty) {
      try {
        final birthDate = DateTime.parse(userProfile.birthday!);
        enrichedProfile['age'] = now.year - birthDate.year;
      } catch (_) {}
    }

    if (userProfile.weightHistory.isNotEmpty) {
      final sortedWeights = [...userProfile.weightHistory]
        ..sort((a, b) => b.time.compareTo(a.time));
      enrichedProfile['latestWeight'] = sortedWeights.first.weight;
    }

    buffer.writeln(
      '- 用户资料: ${const JsonEncoder.withIndent('  ').convert(enrichedProfile)}',
    );
  }

  // 小Q长期记忆（对齐 Hermes 冻结快照语义：仅在对话开始时读取注入一次，
  // 本轮中途的记忆写入不回填上下文，下轮对话生效）
  final memories = await ConfigRepository.instance.getAllAgentMemories();
  final memoryBuffer = StringBuffer();
  for (final doc in memories) {
    final title = AgentMemoryCategory.displayName(doc.category);
    final state = doc.content.trim().isEmpty
        ? '暂无'
        : '已用 ${doc.usagePercent}%';
    memoryBuffer.writeln('  【$title | $state】${AgentMemoryCategory.pathOf(doc.category)}');
    if (doc.content.trim().isNotEmpty) {
      memoryBuffer.writeln(doc.content.trimRight());
    }
  }
  buffer.writeln('- 小Q长期记忆（每次对话自动载入；条目一行一条，可用 read_file/edit_file 增查改）:');
  buffer.write(memoryBuffer.toString());

  for (final section in extraSections) {
    if (section.trim().isNotEmpty) {
      buffer.writeln('- $section');
    }
  }

  return buffer.toString().trim();
}
