import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';

/// 仿 opencode / pi-agent 的精准文本替换编辑工具
class EditTool extends AgentTool {
  final NoteRepository _noteRepo = NoteRepository();

  @override
  String get name => 'edit';

  @override
  String get description =>
      '在指定的笔记或长篇日记中，精准查找旧文本并替换为新文本（支持多次替换或单次替换），避免重写整个文件导致格式丢失。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'target_type': {
            'type': 'string',
            'enum': ['note', 'journal'],
            'description': '目标类型：note（普通笔记）或 journal（长篇日记）',
          },
          'id': {
            'type': 'string',
            'description': '目标 ID。若为 journal，也可以是形如 "2026-09-11" 的日期字符串',
          },
          'old_text': {
            'type': 'string',
            'description': '待替换的原始文本片段（必须与目标内容完全匹配）',
          },
          'new_text': {
            'type': 'string',
            'description': '替换后的新文本片段',
          },
          'replace_all': {
            'type': 'boolean',
            'description': '是否替换全部匹配项，默认 false（只替换首个匹配）',
          },
        },
        'required': ['target_type', 'id', 'old_text', 'new_text'],
      };

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> arguments, {
    void Function(String progress)? onProgress,
  }) async {
    final targetType = arguments['target_type'] as String? ?? 'note';
    final targetId = arguments['id'] as String? ?? '';
    final oldText = arguments['old_text'] as String? ?? '';
    final newText = arguments['new_text'] as String? ?? '';
    final replaceAll = arguments['replace_all'] as bool? ?? false;

    if (targetId.isEmpty) return ToolResult.error('目标 id 不能为空');
    if (oldText.isEmpty) return ToolResult.error('待替换的 old_text 不能为空');

    String realNoteId = targetId;
    if (targetType == 'journal') {
      if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(targetId)) {
        final dt = DateTime.tryParse(targetId);
        if (dt != null) {
          realNoteId = JournalService.noteId(dt);
        }
      }
    }

    final note = await _noteRepo.getById(realNoteId);
    if (note == null) {
      return ToolResult.error('未找到对应笔记/日记: $realNoteId');
    }

    final content = note.content;
    if (!content.contains(oldText)) {
      return ToolResult.error('目标笔记内容中未找到指定的 old_text，请先通过 read 或 grep 核对准确文本。');
    }

    String updatedContent;
    if (replaceAll) {
      updatedContent = content.replaceAll(oldText, newText);
    } else {
      final index = content.indexOf(oldText);
      updatedContent = content.substring(0, index) +
          newText +
          content.substring(index + oldText.length);
    }

    final updatedNote = note.copyWith(
      content: updatedContent,
      updatedAt: DateTime.now(),
    );
    await _noteRepo.update(updatedNote);

    return ToolResult.success(
      '已成功更新目标 [${note.title}] (ID: ${note.id}) 的内容。\n已将: "$oldText"\n替换为: "$newText"',
      uiDetails: {
        'type': 'edit_result',
        'note_id': note.id,
        'title': note.title,
        'old_text': oldText,
        'new_text': newText,
      },
    );
  }
}
