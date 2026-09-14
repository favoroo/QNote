import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 局部高精度编辑虚拟文件工具
class EditFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'edit_file';

  @override
  String get description =>
      '对文件做精准的局部字符串替换，用于「改一处」而不是「重写整篇」：'
      '把待办 status 改成 completed（标记完成）、改标题/优先级/提醒时间、'
      '替换笔记中的某个段落、改配置 JSON 里的某些键值。'
      'old_text 必须是文件正文里的原样片段（含足够上下文以保证唯一），'
      'VFS 会自动忽略行号前缀，因此照抄 read_file 回显里的文本也能匹配上。'
      '匹配失败说明文本与现状不符——此时先 read_file 核对，不要反复重试同一写法。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要修改的文件绝对路径（如 "/todos/今日/拿快递.md"）',
          },
          'old_text': {
            'type': 'string',
            'description': '待替换的现有原文（须在原文件中精确匹配；带不带行号前缀都可以）',
          },
          'new_text': {
            'type': 'string',
            'description': '替换后的新文本',
          },
          'replace_all': {
            'type': 'boolean',
            'description': '是否替换所有匹配项（默认 false，仅替换第一处）',
          },
        },
        'required': ['path', 'old_text', 'new_text'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final path = arguments['path'] as String? ?? '';
    final oldText = arguments['old_text'] as String? ?? '';
    final newText = arguments['new_text'] as String? ?? '';
    final replaceAll = arguments['replace_all'] as bool? ?? false;

    if (path.isEmpty || oldText.isEmpty) {
      return ToolResult.error('路径与待替换的原文本不能为空');
    }
    if (oldText == newText) {
      return ToolResult.error('old_text 与 new_text 完全相同，无需替换');
    }

    try {
      final res = await _vfs.editFile(path, oldText, newText, replaceAll: replaceAll);
      return ToolResult.success(
        '已成功编辑文件 [$path]',
        uiDetails: {
          'path': path,
          'old_text': oldText,
          'new_text': newText,
          ...res,
        },
      );
    } catch (e) {
      return ToolResult.error('编辑文件失败: $e');
    }
  }
}
