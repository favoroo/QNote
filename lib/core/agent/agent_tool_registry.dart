import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/tools/general/ask_user_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/edit_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/grep_tool.dart';
import 'package:qnote_flutter/core/agent/tools/journal/manage_journal_tool.dart';
import 'package:qnote_flutter/core/agent/tools/notes/manage_note_tool.dart';
import 'package:qnote_flutter/core/agent/tools/settings/manage_settings_tool.dart';
import 'package:qnote_flutter/core/agent/tools/timeline/manage_timeline_tool.dart';
import 'package:qnote_flutter/core/agent/tools/todo/manage_todo_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/delete_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/edit_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/list_dir_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/read_file_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/skill_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/write_file_tool.dart';

/// 全局工具装配工厂
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
      EditTool(),
      AskUserTool(),

      // 业务工具（兼容保留）
      ManageTodoTool(),
      ManageTimelineTool(),
      ManageJournalTool(),
      ManageNoteTool(),
      ManageSettingsTool(),
    ]);

    return dispatcher;
  }
}
