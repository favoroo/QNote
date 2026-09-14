import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 删除虚拟文件工具
class DeleteFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'delete_file';

  @override
  String get description =>
      '删除虚拟文件或整个分类目录（软删除，可在对话撤回中恢复）：'
      '删单个待办/笔记/单条时间线（传 /timeline/<id>.md）/清空整天流水（/timeline/YYYY-MM-DD.md）/'
      '删分类目录（传目录路径即级联删除其下全部条目，系统默认分类「今日」「长期」除外）。'
      '删除与清空不可逆，执行前必须先 ask_user 二次确认。'
      '移动/改分类不要用「新建+删除」，用 move_file。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '要删除的文件或分类目录绝对路径'
                '（如 "/todos/今日/拿快递.md"、"/todos/临时分类/"、'
                '"/timeline/<id>.md"、"/chats/<会话id>.json"）',
          },
        },
        'required': ['path'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final path = (arguments['path'] as String? ?? '').trim();
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
