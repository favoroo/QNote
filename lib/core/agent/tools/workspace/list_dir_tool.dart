import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 浏览虚拟工作区目录工具
class ListDirTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'list_dir';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '列出指定虚拟目录下的文件与子文件夹。用于探索工作区全貌、查看分类、浏览待办/笔记/时间线/系统配置等。常用目录：根目录 list_dir(path: "/")，待办分类 list_dir(path: "/todos")，分类管理 list_dir(path: "/folders")，数据洞察 list_dir(path: "/stats")，会话管理 list_dir(path: "/chats")，系统配置 list_dir(path: "/settings")。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要查看的虚拟目录路径（如 "/"、"/todos"、"/folders"、"/stats"、"/chats"、"/settings"、"/notes"、"/skills" 等，默认为 "/"）',
          },
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final path = arguments['path'] as String? ?? '/';
    try {
      final items = await _vfs.listDir(path);
      if (items.isEmpty) {
        return ToolResult.success(
          '目录 [$path] 为空',
          uiDetails: {'path': path, 'items': []},
        );
      }
      final output = items.join('\n');
      return ToolResult.success(
        output,
        uiDetails: {'path': path, 'items': items},
      );
    } catch (e) {
      return ToolResult.error('列出目录失败: $e');
    }
  }
}
