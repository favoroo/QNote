import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';

/// 每日长篇日记管理工具
class ManageJournalTool extends AgentTool {
  final JournalService _journalService = JournalService.instance;

  @override
  String get name => 'manage_journal';

  @override
  String get description =>
      '长篇日记综合管理：查看某天日记 (get)、创建/覆盖日记 (write)、向某天日记末尾追加内容 (append)。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['get', 'write', 'append'],
            'description': '日记操作类型',
          },
          'date': {
            'type': 'string',
            'description': '日记所属日期，形如 "2026-09-11"（默认今天）',
          },
          'content': {
            'type': 'string',
            'description': '日记 Markdown 正文内容（write 或 append 时使用）',
          },
        },
        'required': ['action'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final action = arguments['action'] as String;
    DateTime date = DateTime.now();
    if (arguments['date'] != null) {
      final parsed = DateTime.tryParse(arguments['date'].toString());
      if (parsed != null) date = parsed;
    }

    final dateStr = '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

    switch (action) {
      case 'get':
        final note = await _journalService.getNoteForDate(date);
        if (note == null || note.content.trim().isEmpty) {
          return ToolResult.success('日期 $dateStr 尚未撰写长篇日记。');
        }
        return ToolResult.success(
          '【$dateStr 日记全文】 (ID: ${note.id})\n\n${truncateOutput(note.content)}',
          uiDetails: {
            'type': 'journal_content',
            'date': dateStr,
            'note_id': note.id,
            'content': note.content,
          },
        );

      case 'write':
        final content = arguments['content'] as String? ?? '';
        final saved = await _journalService.saveJournal(date, content);
        return ToolResult.success(
          '已成功保存 $dateStr 的长篇日记。',
          uiDetails: {
            'type': 'journal_saved',
            'date': dateStr,
            'note_id': saved?.id,
          },
        );

      case 'append':
        final content = arguments['content'] as String? ?? '';
        if (content.trim().isEmpty) return ToolResult.error('追加内容不能为空');

        final existing = await _journalService.getNoteForDate(date);
        final oldContent = existing?.content ?? '';
        final newContent = oldContent.isEmpty ? content : '$oldContent\n\n$content';
        final saved = await _journalService.saveJournal(date, newContent);

        return ToolResult.success(
          '已成功向 $dateStr 的日记末尾追加内容。',
          uiDetails: {
            'type': 'journal_appended',
            'date': dateStr,
            'note_id': saved?.id,
          },
        );

      default:
        return ToolResult.error('未知 action: $action');
    }
  }
}
