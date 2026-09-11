import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:uuid/uuid.dart';

/// 笔记与笔记本文件夹综合管理工具
class ManageNoteTool extends AgentTool {
  final NoteRepository _noteRepo = NoteRepository();
  final FolderRepository _folderRepo = FolderRepository();

  @override
  String get name => 'manage_note';

  @override
  String get description =>
      '笔记与文件夹管理：创建笔记 (create_note)、读取笔记全文 (read_note)、修改笔记 (update_note)、删除笔记 (delete_note)、列出所有笔记/文件夹 (list)、创建文件夹 (create_folder)。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': [
              'create_note',
              'read_note',
              'update_note',
              'delete_note',
              'list',
              'create_folder'
            ],
            'description': '笔记操作类型',
          },
          'id': {
            'type': 'string',
            'description': '笔记或文件夹 ID',
          },
          'title': {
            'type': 'string',
            'description': '笔记标题或文件夹名称',
          },
          'content': {
            'type': 'string',
            'description': '笔记正文内容（Markdown 格式）',
          },
          'folder_id': {
            'type': 'string',
            'description': '所属笔记本文件夹 ID',
          },
          'is_pinned': {
            'type': 'boolean',
            'description': '是否置顶',
          },
          'tags': {
            'type': 'string',
            'description': '笔记标签，逗号分隔如 "工作,重要"',
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

    switch (action) {
      case 'create_note':
        return await _createNote(arguments);
      case 'read_note':
        return await _readNote(arguments);
      case 'update_note':
        return await _updateNote(arguments);
      case 'delete_note':
        return await _deleteNote(arguments);
      case 'create_folder':
        return await _createFolder(arguments);
      case 'list':
      default:
        return await _listNotes(arguments);
    }
  }

  Future<ToolResult> _createNote(Map<String, dynamic> args) async {
    final title = args['title'] as String? ?? '无标题笔记';
    final content = args['content'] as String? ?? '';
    final folderId = args['folder_id'] as String?;
    final isPinned = args['is_pinned'] as bool? ?? false;
    final tags = args['tags'] as String? ?? '';

    final now = DateTime.now();
    final note = Note(
      id: const Uuid().v4(),
      title: title,
      content: content,
      folderId: folderId,
      isPinned: isPinned,
      tags: tags,
      createdAt: now,
      updatedAt: now,
    );

    final saved = await _noteRepo.insert(note);
    return ToolResult.success(
      '已成功创建笔记：[$title] (ID: ${saved.id})',
      uiDetails: {
        'type': 'note_created',
        'note': saved.toMap(),
      },
    );
  }

  Future<ToolResult> _readNote(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('读取笔记必须提供 id');

    final note = await _noteRepo.getById(id);
    if (note == null) return ToolResult.error('未找到笔记: $id');

    return ToolResult.success(
      '【笔记】${note.title} (ID: ${note.id})\n'
      '置顶: ${note.isPinned ? "是" : "否"} | 更新时间: ${note.updatedAt.toIso8601String().substring(0, 16)}\n\n'
      '${truncateOutput(note.content)}',
      uiDetails: {
        'type': 'note_read',
        'note': note.toMap(),
      },
    );
  }

  Future<ToolResult> _updateNote(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('更新笔记必须提供 id');

    final existing = await _noteRepo.getById(id);
    if (existing == null) return ToolResult.error('未找到笔记: $id');

    final updated = existing.copyWith(
      title: args['title'] as String? ?? existing.title,
      content: args['content'] as String? ?? existing.content,
      folderId: args.containsKey('folder_id')
          ? args['folder_id'] as String?
          : existing.folderId,
      isPinned: args['is_pinned'] as bool? ?? existing.isPinned,
      tags: args['tags'] as String? ?? existing.tags,
      updatedAt: DateTime.now(),
    );

    final saved = await _noteRepo.update(updated);
    return ToolResult.success(
      '已成功更新笔记：[${saved.title}] (ID: ${saved.id})',
      uiDetails: {
        'type': 'note_updated',
        'note': saved.toMap(),
      },
    );
  }

  Future<ToolResult> _deleteNote(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('删除笔记必须提供 id');

    final existing = await _noteRepo.getById(id);
    if (existing == null) return ToolResult.error('笔记不存在: $id');

    await _noteRepo.softDelete(id);
    return ToolResult.success(
      '已将笔记 [${existing.title}] 移入废纸篓/软删除 (ID: $id)',
      uiDetails: {
        'type': 'note_deleted',
        'id': id,
        'title': existing.title,
      },
    );
  }

  Future<ToolResult> _createFolder(Map<String, dynamic> args) async {
    final name = args['title'] as String? ?? '';
    if (name.trim().isEmpty) return ToolResult.error('文件夹名称不能为空');

    final folder = Folder(
      id: const Uuid().v4(),
      name: name,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );

    final saved = await _folderRepo.insert(folder);
    return ToolResult.success(
      '已创建笔记本文件夹：[$name] (ID: ${saved.id})',
      uiDetails: {
        'type': 'folder_created',
        'folder': saved.toMap(),
      },
    );
  }

  Future<ToolResult> _listNotes(Map<String, dynamic> args) async {
    final notes = await _noteRepo.getAll();
    final folders = await _folderRepo.getAll();

    final sb = StringBuffer();
    sb.writeln('文件夹列表 (${folders.length} 个):');
    for (final f in folders) {
      sb.writeln('- [目录] ${f.name} (ID: ${f.id})');
    }

    sb.writeln('\n笔记列表 (${notes.length} 篇):');
    for (final n in notes.take(30)) {
      final pin = n.isPinned ? '[置顶] ' : '';
      sb.writeln('- $pin${n.title} (ID: ${n.id})');
    }

    return ToolResult.success(
      truncateOutput(sb.toString()),
      uiDetails: {
        'type': 'notes_tree',
        'folder_count': folders.length,
        'note_count': notes.length,
      },
    );
  }
}
