import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 删除虚拟文件工具
class DeleteFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'delete_file';

  @override
  String get description =>
      '删除虚拟工作区中的指定文件（如软删除待办 "/todos/今日/已取消任务.md" 或笔记 "/notes/旧笔记.md"）。执行前请确认用户意图。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要删除的文件绝对路径（如 "/todos/今日/拿快递.md"）',
          },
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final path = arguments['path'] as String? ?? '';
    if (path.isEmpty) {
      return ToolResult.error('路径不能为空');
    }

    try {
      final res = await _vfs.deleteFile(path);
      final title = res['title'] ?? path;
      return ToolResult.success(
        '已成功删除 [$title] ($path)',
        uiDetails: res,
      );
    } catch (e) {
      return ToolResult.error('删除文件失败: $e');
    }
  }
}
