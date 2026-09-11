import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 局部高精度编辑虚拟文件工具
class EditFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'edit_file';

  @override
  String get description =>
      '对虚拟工作区中指定文件执行精准的局部字符串替换（Exact String Replacement）。常用于将待办状态由 "status: pending" 改为 "status: completed"（标记完成）、修改待办截止时间或优先级、修改笔记中的某个段落、或修改配置 JSON 中的某些键值，避免全文件重写。';

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
            'description': '文件中待替换的现有原字符串（必须在原文件中精确匹配，不要包含行号前缀）',
          },
          'new_text': {
            'type': 'string',
            'description': '替换后的新字符串',
          },
          'replace_all': {
            'type': 'boolean',
            'description': '是否替换所有匹配项（默认为 false，仅替换第一处）',
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
