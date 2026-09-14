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
      '列出指定虚拟目录下的文件与子文件夹，用于了解工作区结构与浏览分类。'
      '不确定条目在哪个分类时，优先用 grep 直接定位（更快），list_dir 更适合摸清结构。'
      '需要一次性看全貌时传 recursive: true，会返回整棵目录树的完整路径（条目过多会自动截断）。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要查看的虚拟目录路径（如 "/"、"/todos"、"/notes"、"/timeline"、'
                '"/settings"、"/folders" 等，默认为 "/"）',
          },
          'recursive': {
            'type': 'boolean',
            'description': '是否递归展开整棵目录树，默认 false（仅列一层）',
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
    final recursive = arguments['recursive'] as bool? ?? false;
    try {
      final items = await _vfs.listDir(path, recursive: recursive);
      if (items.isEmpty) {
        return ToolResult.success(
          '目录 [$path] 为空',
          uiDetails: {'path': path, 'recursive': recursive, 'items': []},
        );
      }
      return ToolResult.success(
        items.join('\n'),
        uiDetails: {'path': path, 'recursive': recursive, 'items': items},
      );
    } catch (e) {
      return ToolResult.error('列出目录失败: $e');
    }
  }
}
