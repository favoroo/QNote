import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 写入或新建虚拟文件工具
class WriteFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'write_file';

  @override
  String get description =>
      '在虚拟工作区指定路径创建新文件或覆写已有文件。支持创建/更新待办（如 "/todos/工作/写周报.md"、"/todos/今日/拿快递.md"）、新建笔记（如 "/notes/技术/Agent设计.md"）、记录时间流水（如 "/timeline/2026-09-11.md"）、撰写深度日记或修改系统设置。若目标分类不存在将自动创建分类！';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '虚拟文件绝对路径（必须以 "/" 开头，如 "/todos/工作/需求评审.md"）',
          },
          'content': {
            'type': 'string',
            'description': '写入的完整文件内容。支持包含 YAML Frontmatter (如 status, priority, due_date 等元数据)',
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

    if (path.trim().isEmpty) {
      return ToolResult.error('文件路径不能为空');
    }

    try {
      final res = await _vfs.writeFile(path, content);
      final status = res['status'] ?? 'saved';
      final title = res['title'] ?? path;
      return ToolResult.success(
        '已成功保存文件 [$path] ($status)\n标题: $title',
        uiDetails: res,
      );
    } catch (e) {
      return ToolResult.error('写入文件失败: $e');
    }
  }
}
