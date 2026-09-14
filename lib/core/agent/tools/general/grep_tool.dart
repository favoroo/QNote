import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';

/// 全库关键词/正则检索工具
///
/// 检索实现收敛在 [VirtualWorkspaceService.grep] 一处，工具层只做参数解析与结果排版，
/// 避免两套检索语义各自演化（改了一处忘了另一处）。
class GrepTool extends AgentTool {
  final VirtualWorkspaceService _vfs = VirtualWorkspaceService.instance;

  /// 命中类型 → 中文标签，用于排版分组
  static const Map<String, String> _typeLabels = {
    'todo': '待办',
    'note': '笔记',
    'journal': '日记',
    'timeline': '时间线',
    'memory': '记忆',
    'settings': '配置',
    'chats': '会话',
  };

  @override
  String get name => 'grep';

  @override
  ToolExecutionMode get executionMode => ToolExecutionMode.parallel;

  @override
  String get description =>
      '在整个 App 内检索关键词或正则（笔记、待办、时间线流水、日记、长期记忆、系统配置、历史会话），'
      '返回**可直接用于 read_file / edit_file / delete_file 的虚拟路径**与命中摘要。'
      '这是「找内容」的默认入口：只要不确定条目在哪个分类、完整标题是什么，就先用它定位，'
      '不要靠 list_dir 层层翻目录试探。需要完整正文时，再用返回的路径调 read_file。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'query': {
            'type': 'string',
            'description': '要搜索的关键词或正则表达式',
          },
          'scope': {
            'type': 'string',
            'enum': VirtualWorkspaceService.grepScopes,
            'description': '检索范围，默认 all（全库）；查具体模块时可收窄以提升精度',
          },
          'max_results': {
            'type': 'integer',
            'description': '最多返回的匹配条数，默认 20',
          },
        },
        'required': ['query'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final query = (arguments['query'] as String? ?? '').trim();
    if (query.isEmpty) {
      return ToolResult.error('搜索关键词 query 不能为空');
    }

    // 未知 scope 静默归一为 all，避免模型传错枚举值就直接失败
    final rawScope = (arguments['scope'] as String? ?? 'all').trim();
    final scope =
        VirtualWorkspaceService.grepScopes.contains(rawScope) ? rawScope : 'all';
    final maxResults = _parseMaxResults(arguments['max_results']);

    List<Map<String, dynamic>> hits;
    try {
      hits = await _vfs.grep(query, scope: scope, maxResults: maxResults);
    } catch (e) {
      return ToolResult.error('检索失败: $e');
    }

    if (hits.isEmpty) {
      return ToolResult.success(
        '未找到与「$query」匹配的内容（检索范围：$scope）。'
        '可尝试更换关键词、收窄或放宽 scope 后重试；确认没有时请如实告知用户，不要编造内容。',
        uiDetails: {
          'type': 'grep_result',
          'query': query,
          'scope': scope,
          'total': 0,
          'hits': const [],
        },
      );
    }

    final buffer = StringBuffer(
      '共找到 ${hits.length} 条匹配项（范围：$scope）。'
      '下列路径可直接用于 read_file / edit_file / delete_file：\n',
    );
    for (final hit in hits) {
      final type = hit['type']?.toString() ?? '';
      final label = _typeLabels[type] ?? type;
      buffer.write('\n【$label】${hit['path'] ?? ''}');
      final line = hit['line'];
      if (line is int) {
        buffer.write('（第 $line 行）');
      }
      final title = hit['title'];
      if (title is String && title.trim().isNotEmpty) {
        buffer.write(' | 标题: ${title.trim()}');
      }
      if (hit['is_completed'] == true) {
        buffer.write(' | 状态: 已完成');
      }
      final time = hit['time'];
      if (time is String && time.length >= 16) {
        buffer.write(' | 时间: ${time.substring(0, 16).replaceAll('T', ' ')}');
      }
      final match = hit['match'] ?? hit['snippet'];
      if (match is String && match.trim().isNotEmpty) {
        buffer.write('\n  匹配摘要: ${match.trim()}');
      }
    }

    return ToolResult.success(
      truncateOutput(buffer.toString(), maxLength: 6000),
      uiDetails: {
        'type': 'grep_result',
        'query': query,
        'scope': scope,
        'total': hits.length,
        'hits': hits,
      },
    );
  }

  /// 解析 max_results：兼容 int / num / string，缺省 20，收敛到 [1, 100]
  int _parseMaxResults(dynamic raw) {
    int? value;
    if (raw is int) {
      value = raw;
    } else if (raw is num) {
      value = raw.round();
    } else if (raw is String) {
      value = int.tryParse(raw);
    }
    if (value == null) return 20;
    return value.clamp(1, 100);
  }
}
