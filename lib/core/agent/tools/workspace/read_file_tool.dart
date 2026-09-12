import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 读取虚拟文件工具
class ReadFileTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  @override
  String get name => 'read_file';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '读取虚拟工作区中某个文件的完整内容（返回带行号的正文与 Frontmatter 元数据）。'
      '用在这些场合：改写前核对原文（edit_file 的 old_text 要照它取）、查看某条待办/笔记/日记详情、'
      '读统计端点（/stats/summary.json、/stats/daily_scores.json）做分析、读配置确认当前设置。'
      '长文可用 offset/limit 分段读；各目录的路径与格式规范见 /AGENTS.md。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'path': {
            'type': 'string',
            'description': '虚拟文件绝对路径（以 "/" 开头），如 "/todos/今日/拿快递.md"、'
                '"/notes/技术/架构.md"、"/timeline/2026-09-11.md"、"/journal/2026-09-11.md"、'
                '"/stats/summary.json"、"/settings/appearance.json"、"/memory/user.md"',
          },
          'offset': {
            'type': 'integer',
            'description': '起始行号（从 1 开始，选填；grep 返回的行号可直接用作起点）',
          },
          'limit': {
            'type': 'integer',
            'description': '读取行数上限（选填）',
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

    if (path.trim().isEmpty) {
      return ToolResult.error('文件路径不能为空');
    }

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
