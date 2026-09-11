import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 读取虚拟文件工具
class ReadFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'read_file';

  @override
  String get description =>
      '读取虚拟工作区中指定文件的内容（包含行号及 Frontmatter 元数据）。支持读取待办详情（如 "/todos/今日/拿快递.md"）、笔记内容（如 "/notes/技术架构/方案.md"）、时间线流水（如 "/timeline/2026-09-11.md"）、长篇日记、系统配置（如 "/settings/profile.json"）或专业技能手册（如 "/skills/todo-manager.md"）。支持行号切片。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '虚拟文件绝对路径（以 "/" 开头）',
          },
          'offset': {
            'type': 'integer',
            'description': '起始读取行号（从 1 开始，选填）',
          },
          'limit': {
            'type': 'integer',
            'description': '读取行数限制（选填）',
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
    final offset = arguments['offset'] as int?;
    final limit = arguments['limit'] as int?;

    try {
      final content = await _vfs.readFile(path, offset: offset, limit: limit);
      final truncated = truncateOutput(content, maxLength: 6000);
      return ToolResult.success(
        truncated,
        uiDetails: {
          'path': path,
          'offset': offset,
          'limit': limit,
          'preview': truncated.length > 300 ? '${truncated.substring(0, 300)}...' : truncated,
        },
      );
    } catch (e) {
      return ToolResult.error('读取文件失败: $e');
    }
  }
}
