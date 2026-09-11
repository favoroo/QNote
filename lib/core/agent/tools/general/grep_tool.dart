import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';

/// 仿 opencode / pi-agent 的全库关键词/正则搜索工具
class GrepTool extends AgentTool {
  final NoteRepository _noteRepo = NoteRepository();
  final TodoRepository _todoRepo = TodoRepository();
  final DiaryRepository _diaryRepo = DiaryRepository();

  @override
  String get name => 'grep';

  @override
  String get description =>
      '在整个 App（笔记、待办、时间线流水日记）中检索包含指定关键词或正则表达式的内容。输出匹配项摘要与 ID。';

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
            'enum': ['all', 'notes', 'todos', 'timeline'],
            'description': '搜索范围，默认为 all（全部）',
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
    final query = arguments['query'] as String? ?? '';
    if (query.trim().isEmpty) {
      return ToolResult.error('搜索关键词 query 不能为空');
    }

    final scope = arguments['scope'] as String? ?? 'all';
    final maxResults = arguments['max_results'] as int? ?? 20;

    RegExp? regExp;
    try {
      regExp = RegExp(query, caseSensitive: false);
    } catch (_) {
      regExp = RegExp(RegExp.escape(query), caseSensitive: false);
    }

    final buffer = StringBuffer();
    final List<Map<String, dynamic>> hits = [];

    // 1. 搜索笔记
    if (scope == 'all' || scope == 'notes') {
      final notes = await _noteRepo.getAll();
      for (final note in notes) {
        if (hits.length >= maxResults) break;
        if (regExp.hasMatch(note.title) || regExp.hasMatch(note.content)) {
          hits.add({
            'type': 'note',
            'id': note.id,
            'title': note.title,
            'snippet': _makeSnippet(note.content, regExp),
          });
          buffer.writeln('【笔记】ID: ${note.id} | 标题: ${note.title}');
          buffer.writeln('  匹配摘要: ${_makeSnippet(note.content, regExp)}');
        }
      }
    }

    // 2. 搜索待办
    if (scope == 'all' || scope == 'todos') {
      final todos = await _todoRepo.getAll();
      for (final todo in todos) {
        if (hits.length >= maxResults) break;
        final desc = todo.description;
        if (regExp.hasMatch(todo.title) || regExp.hasMatch(desc)) {
          hits.add({
            'type': 'todo',
            'id': todo.id,
            'title': todo.title,
            'is_completed': todo.isCompleted,
            'snippet': _makeSnippet(desc.isNotEmpty ? desc : todo.title, regExp),
          });
          buffer.writeln('【待办】ID: ${todo.id} | 标题: ${todo.title} | 状态: ${todo.isCompleted ? "已完成" : "待办"}');
        }
      }
    }

    // 3. 搜索时间线流水
    if (scope == 'all' || scope == 'timeline') {
      final records = await _diaryRepo.getAll();
      for (final r in records) {
        if (hits.length >= maxResults) break;
        final tagsStr = r.tags.join(',');
        if (regExp.hasMatch(r.content) || regExp.hasMatch(tagsStr)) {
          hits.add({
            'type': 'timeline',
            'id': r.id,
            'time': r.time.toIso8601String(),
            'tags': r.tags,
            'snippet': _makeSnippet(r.content, regExp),
          });
          buffer.writeln('【时间线】ID: ${r.id} | 时间: ${r.time.toIso8601String().substring(0, 16)} | 标签: $tagsStr');
          buffer.writeln('  内容: ${_makeSnippet(r.content, regExp)}');
        }
      }
    }

    if (hits.isEmpty) {
      return ToolResult.success('未找到匹配关键词 "$query" 的内容。');
    }

    final outputText = '共找到 ${hits.length} 条匹配项:\n$buffer';
    return ToolResult.success(
      truncateOutput(outputText),
      uiDetails: {'type': 'grep_result', 'query': query, 'total': hits.length, 'hits': hits},
    );
  }

  String _makeSnippet(String content, RegExp regExp) {
    if (content.isEmpty) return '';
    final match = regExp.firstMatch(content);
    if (match == null) {
      return content.length > 80 ? '${content.substring(0, 80)}...' : content;
    }
    final start = (match.start - 30).clamp(0, content.length);
    final end = (match.end + 50).clamp(0, content.length);
    String snippet = content.substring(start, end).replaceAll('\n', ' ');
    if (start > 0) snippet = '...$snippet';
    if (end < content.length) snippet = '$snippet...';
    return snippet;
  }
}
