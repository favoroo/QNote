import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 删除虚拟文件工具
class DeleteFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'delete_file';

  @override
  String get description =>
      '删除虚拟工作区中的文件或分类目录：\n'
      '1. 单项删除：软删除单个待办（如 "/todos/今日/任务.md"）、单篇笔记（如 "/notes/旧笔记.md"）、单条时间线（如 "/timeline/<id>.md"）、历史会话（如 "/chats/<id>.json"）；\n'
      '2. 分类目录级删除：支持传入待办分类目录路径（如 "/todos/工作/"）或笔记本目录路径（如 "/notes/临时/"），系统将自动级联软删除该分类及其下属的所有条目；\n'
      '3. 整天流水清空：支持传入 "/timeline/2026-09-11.md" 清空当天所有流水。敏感删除请先调用 ask_user 确认。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要删除的文件或分类目录绝对路径（如 "/todos/今日/拿快递.md"、"/todos/临时分类/"、"/timeline/<id>.md"、"/chats/<id>.json"）',
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
