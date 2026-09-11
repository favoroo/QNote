import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/tools/general/ask_user_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/grep_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/delete_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/edit_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/list_dir_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/read_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/skill_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/write_file_tool.dart';

/// 全局工具装配工厂
///
/// 对齐 pi-agent 的"通用原语优先"理念：仅保留 VFS 文件原语 + 检索 + 人机确认，
/// 不再注册 manage_todo 等与 VFS 语义重叠的业务工具，降低每轮 schema 开销与模型决策摇摆。
class AgentToolRegistry {
  static ToolDispatcher createDefaultDispatcher() {
    final dispatcher = ToolDispatcher();

    dispatcher.registerAll([
      // 虚拟工作区 (VFS) 通用基础工具
      ListDirTool(),
      ReadFileTool(),
      WriteFileTool(),
      EditFileTool(),
      DeleteFileTool(),
      SkillTool(),

      // 通用搜索与交互
      GrepTool(),
      AskUserTool(),
    ]);

    return dispatcher;
  }
}
