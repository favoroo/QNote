import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/tools/general/ask_user_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/edit_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/grep_tool.dart';
import 'package:qnote_flutter/core/agent/tools/journal/manage_journal_tool.dart';
import 'package:qnote_flutter/core/agent/tools/notes/manage_note_tool.dart';
import 'package:qnote_flutter/core/agent/tools/settings/manage_settings_tool.dart';
import 'package:qnote_flutter/core/agent/tools/timeline/manage_timeline_tool.dart';
import 'package:qnote_flutter/core/agent/tools/todo/manage_todo_tool.dart';

/// 全局工具装配工厂
class AgentToolRegistry {
  static ToolDispatcher createDefaultDispatcher() {
    final dispatcher = ToolDispatcher();

    dispatcher.registerAll([
      // 基础通用能力
      GrepTool(),
      EditTool(),
      AskUserTool(),

      // 业务能力
      ManageTodoTool(),
      ManageTimelineTool(),
      ManageJournalTool(),
      ManageNoteTool(),
      ManageSettingsTool(),
    ]);

    return dispatcher;
  }
}
