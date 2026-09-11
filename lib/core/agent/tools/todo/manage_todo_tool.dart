import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:uuid/uuid.dart';

/// 待办事项综合管理工具（增、删、改、查、标记完成）
class ManageTodoTool extends AgentTool {
  final TodoRepository _todoRepo = TodoRepository();
  final FolderRepository _folderRepo = FolderRepository();

  @override
  String get name => 'manage_todo';

  @override
  String get description =>
      '待办管理综合工具：支持创建待办 (create)、修改待办 (update)、删除待办 (delete)、查询待办 (list)、标记完成或未完成 (toggle_complete)。所有操作自动记录同步日志。';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'action': {
            'type': 'string',
            'enum': ['create', 'update', 'delete', 'list', 'toggle_complete'],
            'description': '待办操作类型',
          },
          'id': {
            'type': 'string',
            'description': '待办 ID（修改、删除、切换状态时必填）',
          },
          'title': {
            'type': 'string',
            'description': '待办标题（创建时必填，修改时选填）',
          },
          'description': {
            'type': 'string',
            'description': '待办详细描述/备注',
          },
          'priority': {
            'type': 'string',
            'enum': ['none', 'low', 'medium', 'high'],
            'description': '优先级：none(无), low(低), medium(中), high(高)',
          },
          'due_date': {
            'type': 'string',
            'description': '截止日期时间，ISO8601 格式或形如 "2026-09-12 18:00"',
          },
          'is_completed': {
            'type': 'boolean',
            'description': '是否已完成',
          },
          'is_long_term': {
            'type': 'boolean',
            'description': '是否为长期/日常待办',
          },
          'folder_id': {
            'type': 'string',
            'description': '所属待办分类文件夹 ID',
          },
          'folder_name': {
            'type': 'string',
            'description': '所属待办分类名称（如"今日"、"长期"、"工作"、"学习"等）。若分类不存在将自动创建；若同时传入 folder_id 则以 folder_id 优先',
          },
          'query_filter': {
            'type': 'string',
            'enum': ['all', 'pending', 'completed', 'long_term'],
            'description': 'action 为 list 时的过滤条件，默认 pending',
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
      case 'create':
        return await _createTodo(arguments);
      case 'update':
        return await _updateTodo(arguments);
      case 'delete':
        return await _deleteTodo(arguments);
      case 'toggle_complete':
        return await _toggleComplete(arguments);
      case 'list':
      default:
        return await _listTodos(arguments);
    }
  }

  Future<ToolResult> _createTodo(Map<String, dynamic> args) async {
    final title = args['title'] as String? ?? '';
    if (title.trim().isEmpty) {
      return ToolResult.error('创建待办时 title 不能为空');
    }

    DateTime? dueDate;
    if (args['due_date'] != null) {
      dueDate = DateTime.tryParse(args['due_date'].toString());
    }

    final rawPriority = (args['priority'] as String? ?? 'normal').toLowerCase();
    final priority = (rawPriority == 'important' || rawPriority == 'high') ? 'important' : 'normal';
    final isLongTerm = args['is_long_term'] as bool? ?? false;
    final folderId = await _resolveFolderId(
      folderId: args['folder_id'] as String?,
      folderName: args['folder_name'] as String?,
      isLongTerm: isLongTerm,
    );
    final desc = args['description'] as String? ?? '';

    final now = DateTime.now();
    final todo = Todo(
      id: const Uuid().v4(),
      title: title,
      description: desc,
      priority: priority,
      dueDate: dueDate,
      isCompleted: args['is_completed'] as bool? ?? false,
      isLongTerm: isLongTerm,
      folderId: folderId,
      sortOrder: now.millisecondsSinceEpoch,
      createdAt: now,
      updatedAt: now,
    );

    final inserted = await _todoRepo.insert(todo);
    WorkspaceEventBus.instance.emit('/todos', WorkspaceChangeType.created, inserted);
    return ToolResult.success(
      '已成功创建待办事项：\n- 标题: ${inserted.title}\n- ID: ${inserted.id}\n- 优先级: $priority\n- 截止时间: ${dueDate != null ? dueDate.toIso8601String() : "无"}\n- 所属分类ID: $folderId',
      uiDetails: {
        'type': 'todo_created',
        'todo': inserted.toMap(),
      },
    );
  }

  Future<String> _resolveFolderId({
    String? folderId,
    String? folderName,
    bool isLongTerm = false,
  }) async {
    final folders = await _folderRepo.getByType('todo');
    if (folderId != null && folderId.isNotEmpty) {
      final existing = folders.where((f) => f.id == folderId).firstOrNull;
      if (existing != null) return existing.id;
    }

    if (folderName != null && folderName.trim().isNotEmpty) {
      final trimmed = folderName.trim();
      final matched = folders.where((f) => f.name.toLowerCase() == trimmed.toLowerCase()).firstOrNull;
      if (matched != null) return matched.id;

      // 自动创建新分类
      final now = DateTime.now();
      final newFolder = Folder(
        id: const Uuid().v4(),
        name: trimmed,
        type: 'todo',
        sortOrder: folders.length,
        createdAt: now,
        updatedAt: now,
      );
      await _folderRepo.insert(newFolder);
      return newFolder.id;
    }

    if (isLongTerm) {
      final longterm = folders.where((f) => f.id == 'todo_default_longterm' || f.name == '长期').firstOrNull;
      if (longterm != null) return longterm.id;
    }

    final today = folders.where((f) => f.id == 'todo_default_today' || f.name == '今日').firstOrNull;
    if (today != null) return today.id;

    return folders.isNotEmpty ? folders.first.id : 'todo_default_today';
  }

  Future<ToolResult> _updateTodo(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('更新待办必须提供待办 id');

    final existing = await _todoRepo.getById(id);
    if (existing == null) return ToolResult.error('找不到待办: $id');

    DateTime? dueDate = existing.dueDate;
    if (args.containsKey('due_date')) {
      final val = args['due_date'];
      dueDate = val != null ? DateTime.tryParse(val.toString()) : null;
    }

    final updated = existing.copyWith(
      title: args['title'] as String? ?? existing.title,
      description: args['description'] as String? ?? existing.description,
      priority: args['priority'] as String? ?? existing.priority,
      isCompleted: args['is_completed'] as bool? ?? existing.isCompleted,
      isLongTerm: args['is_long_term'] as bool? ?? existing.isLongTerm,
      folderId: args.containsKey('folder_id')
          ? args['folder_id'] as String?
          : existing.folderId,
      dueDate: dueDate,
      updatedAt: DateTime.now(),
    );

    final saved = await _todoRepo.update(updated);
    return ToolResult.success(
      '已更新待办 [${saved.title}] (ID: ${saved.id})',
      uiDetails: {
        'type': 'todo_updated',
        'todo': saved.toMap(),
      },
    );
  }

  Future<ToolResult> _deleteTodo(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('删除待办必须提供待办 id');

    final existing = await _todoRepo.getById(id);
    if (existing == null) return ToolResult.error('待办不存在或已被删除: $id');

    await _todoRepo.softDelete(id);
    return ToolResult.success(
      '已删除待办：${existing.title} (ID: $id)',
      uiDetails: {
        'type': 'todo_deleted',
        'id': id,
        'title': existing.title,
      },
    );
  }

  Future<ToolResult> _toggleComplete(Map<String, dynamic> args) async {
    final id = args['id'] as String? ?? '';
    if (id.isEmpty) return ToolResult.error('切换待办状态必须提供待办 id');

    final existing = await _todoRepo.getById(id);
    if (existing == null) return ToolResult.error('找不到待办: $id');

    final targetCompleted = args['is_completed'] as bool? ?? !existing.isCompleted;
    final updated = existing.copyWith(
      isCompleted: targetCompleted,
      updatedAt: DateTime.now(),
    );
    await _todoRepo.update(updated);

    return ToolResult.success(
      '已将待办 [${existing.title}] 标记为：${targetCompleted ? "已完成" : "未完成"}',
      uiDetails: {
        'type': 'todo_status_changed',
        'id': id,
        'title': existing.title,
        'is_completed': targetCompleted,
      },
    );
  }

  Future<ToolResult> _listTodos(Map<String, dynamic> args) async {
    final filter = args['query_filter'] as String? ?? 'pending';
    List<Todo> list;
    if (filter == 'completed') {
      list = await _todoRepo.getCompleted();
    } else if (filter == 'long_term') {
      list = await _todoRepo.getByIsLongTerm(true);
    } else if (filter == 'all') {
      list = await _todoRepo.getAll();
    } else {
      list = await _todoRepo.getPending();
    }

    if (list.isEmpty) {
      return ToolResult.success('当前分类 ($filter) 下没有待办事项。');
    }

    final sb = StringBuffer();
    sb.writeln('待办列表 ($filter, 共 ${list.length} 条):');
    for (final t in list) {
      final status = t.isCompleted ? '[x]' : '[ ]';
      final due = t.dueDate != null ? ' (截止: ${t.dueDate!.toIso8601String().substring(0, 10)})' : '';
      sb.writeln('$status ID: ${t.id} | ${t.title}$due [优先级: ${t.priority}]');
    }

    return ToolResult.success(
      truncateOutput(sb.toString()),
      uiDetails: {
        'type': 'todo_list',
        'count': list.length,
        'items': list.map((e) => e.toMap()).toList(),
      },
    );
  }
}
