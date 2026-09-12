import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 写入或新建虚拟文件工具（全量覆写 / 追加两种模式）
class WriteFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  /// 写入模式：全量覆写（默认）
  static const String modeOverwrite = 'overwrite';

  /// 写入模式：追加到文件末尾
  static const String modeAppend = 'append';

  @override
  String get name => 'write_file';

  @override
  String get description =>
      '在虚拟工作区创建/覆写/追加文件内容。这是执行「定下来要做的事」的写入原语：'
      '新建待办、写笔记、记时间线、写日记、改配置都用它。'
      '写待办必须带完整 YAML Frontmatter（status / priority / repeat_rule / tags / reminder_time）；'
      '时间线必须用「## [HH:MM] 标题」时间块，禁用 Frontmatter；'
      '配置与分类为 JSON。'
      'mode: "append" 表示追加到文件末尾（仅待办、笔记、时间线、日记、记忆支持）——'
      '往当天时间线补一条流水、记忆里补一条、笔记末尾接一段，都应该用追加，'
      '不必先 read_file 再整篇重写（整篇重写容易丢失时间线的 id 注释导致事件重复）。'
      '各目录的完整格式规范见 /AGENTS.md 与对应技能手册。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '虚拟文件绝对路径（以 "/" 开头，如 "/todos/工作/写周报.md"、'
                '"/timeline/2026-09-11.md"、"/notes/技术/架构.md"、"/settings/weight.json"）',
          },
          'content': {
            'type': 'string',
            'description': '写入的完整内容。待办为 YAML Frontmatter + 正文；'
                '时间线为二级时间标题块；设置与分类为 JSON 文本',
          },
          'mode': {
            'type': 'string',
            'enum': [modeOverwrite, modeAppend],
            'description': '写入模式：overwrite 覆写整篇（默认）；append 追加到末尾（仅待办/笔记/时间线/日记/记忆）',
          },
        },
        'required': ['path', 'content'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final path = arguments['path'] as String? ?? '';
    final content = arguments['content'] as String? ?? '';
    final mode = (arguments['mode'] as String? ?? modeOverwrite).trim();

    if (path.trim().isEmpty) {
      return ToolResult.error('文件路径不能为空');
    }
    if (content.isEmpty) {
      return ToolResult.error('content 不能为空（如需清空文件，请在用户明确要求下写入占位内容）');
    }
    if (mode != modeOverwrite && mode != modeAppend) {
      return ToolResult.error('mode 只支持 "$modeOverwrite" 或 "$modeAppend"，收到: $mode');
    }
    final isAppend = mode == modeAppend;

    try {
      final res = await _vfs.writeFile(path, content, append: isAppend);
      final status = res['status'] ?? 'saved';
      final title = res['title'] ?? path;
      final buffer = StringBuffer(
        '已成功保存文件 [$path] ($status${isAppend ? '，追加模式' : ''})\n标题: $title',
      );
      // 回显待办的定时字段，便于模型自检是否真正写入了提醒
      if (res['due_date'] != null) {
        buffer.write('\n截止时间: ${res['due_date']}');
      }
      if (res['reminder_time'] != null) {
        buffer.write('\n提醒时间: ${res['reminder_time']}');
      }
      return ToolResult.success(buffer.toString(), uiDetails: res);
    } catch (e) {
      return ToolResult.error('写入文件失败: $e');
    }
  }
}
