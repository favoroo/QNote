import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/ask_user_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/fetch_url_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/generate_image_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/grep_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/web_search_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/delete_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/edit_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/list_dir_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/move_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/read_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/skill_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/view_image_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/write_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/write_files_tool.dart';

/// 全局工具装配工厂
///
/// 对齐 pi-agent 的"通用原语优先"理念：仅保留 VFS 文件原语 + 检索 + 人机确认，
/// 不再注册 manage_todo 等与 VFS 语义重叠的业务工具，降低每轮 schema 开销与模型决策摇摆。
/// 原语按「单条 / 批量」「读 / 写 / 移动」成对提供，避免多条目任务被迫逐条调用而吃满步数上限。
class AgentToolRegistry {
  /// 可选工具名集合（对齐 Hermes Toolsets 的"核心直曝 + 扩展可停"分层）：
  /// 用户可在设置页禁用以裁剪 schema 与开销；其余工具均为核心工具，始终注册
  static const Set<String> optionalToolNames = {
    'fetch_url',
    'web_search',
    'generate_image',
  };

  /// 创建默认工具分发器
  ///
  /// [disabledTools] 为用户禁用的可选工具名集合（见 [AgentToolConfig]），
  /// 仅对 [optionalToolNames] 生效；核心工具忽略该参数始终注册
  static ToolDispatcher createDefaultDispatcher({
    Set<String> disabledTools = const {},
  }) {
    final dispatcher = ToolDispatcher();

    // 核心工具忽略禁用名单（防御性兜底：仅裁剪合法的可选工具）
    final disabled = disabledTools.where(optionalToolNames.contains).toSet();

    final tools = <AgentTool>[
      // 虚拟工作区 (VFS) 通用基础工具
      ListDirTool(),
      ReadFileTool(),
      WriteFileTool(),
      WriteFilesTool(),
      EditFileTool(),
      MoveFileTool(),
      DeleteFileTool(),
      ViewImageTool(),
      SkillTool(),

      // 通用搜索、联网与交互（可选，可在设置中禁用）
      GrepTool(),
      if (!disabled.contains('fetch_url')) FetchUrlTool(),
      if (!disabled.contains('web_search')) WebSearchTool(),
      if (!disabled.contains('generate_image')) GenerateImageTool(),
      AskUserTool(),
    ];

    dispatcher.registerAll(tools);

    return dispatcher;
  }
}
