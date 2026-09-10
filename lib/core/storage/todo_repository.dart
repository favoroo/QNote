import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/todo.dart';

class TodoRepository {
  static final TodoRepository _instance = TodoRepository._internal();
  factory TodoRepository() => _instance;
  TodoRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  Future<List<Todo>> getAll({bool includeDeleted = false}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: includeDeleted ? null : 'is_deleted = 0',
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getByFolder(String folderId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'folder_id = ? AND is_deleted = 0',
      whereArgs: [folderId],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getCompleted() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'is_completed = 1 AND is_deleted = 0',
      orderBy: 'updated_at DESC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getPending() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'is_completed = 0 AND is_deleted = 0',
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getByIsLongTerm(bool isLongTerm) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'is_long_term = ? AND is_deleted = 0',
      whereArgs: [isLongTerm ? 1 : 0],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getUpcomingReminders() async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'reminder_time IS NOT NULL AND is_completed = 0 AND is_deleted = 0',
      orderBy: 'reminder_time ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getCompletedByIsLongTerm(bool isLongTerm) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'is_completed = 1 AND is_long_term = ? AND is_deleted = 0',
      whereArgs: [isLongTerm ? 1 : 0],
      orderBy: 'updated_at DESC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<Todo?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query('todos', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Todo.fromMap(maps.first);
  }

  Future<Todo> insert(Todo todo) async {
    final db = await _dbHelper.database;
    await db.insert('todos', todo.toMap());
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: todo.id,
      operation: 'insert',
      data: todo.toMap(),
    );
    return todo;
  }

  Future<Todo> update(Todo todo) async {
    final db = await _dbHelper.database;
    final updated = todo.copyWith(updatedAt: DateTime.now());
    await db.update(
      'todos',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [todo.id],
    );
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: todo.id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<void> softDelete(String id) async {
    final db = await _dbHelper.database;
    final existing = await getById(id);
    if (existing == null) return;

    final nowStr = DateTime.now().toIso8601String();
    await db.update(
      'todos',
      {'is_deleted': 1, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      isDeleted: true,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
  }

  Future<void> hardDelete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('todos', where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: id,
      operation: 'delete',
    );
  }

  /// 清理所有标题为空的存量待办记录（软删除），避免脏数据残留
  Future<int> cleanEmptyTodos() async {
    final db = await _dbHelper.database;
    final emptyRows = await db.query(
      'todos',
      where: "(TRIM(title) = '' OR title IS NULL) AND is_deleted = 0",
    );
    if (emptyRows.isEmpty) return 0;

    final nowStr = DateTime.now().toIso8601String();
    for (final row in emptyRows) {
      final id = row['id'] as String;
      await db.update(
        'todos',
        {'is_deleted': 1, 'updated_at': nowStr},
        where: 'id = ?',
        whereArgs: [id],
      );
      await _syncLog.logChange(
        tableName: 'todos',
        recordId: id,
        operation: 'update',
        data: {...row, 'is_deleted': 1, 'updated_at': nowStr},
      );
    }
    return emptyRows.length;
  }

  Future<void> toggleComplete(String id, bool isCompleted) async {
    final db = await _dbHelper.database;
    final existing = await getById(id);
    if (existing == null) return;

    final nowStr = DateTime.now().toIso8601String();
    await db.update(
      'todos',
      {'is_completed': isCompleted ? 1 : 0, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      isCompleted: isCompleted,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
  }

  Future<void> moveToLongTerm(String id) async {
    final db = await _dbHelper.database;
    final existing = await getById(id);
    if (existing == null) return;

    final nowStr = DateTime.now().toIso8601String();
    await db.update(
      'todos',
      {'is_long_term': 1, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      isLongTerm: true,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
  }

  Future<void> moveToToday(String id) async {
    final db = await _dbHelper.database;
    final existing = await getById(id);
    if (existing == null) return;

    final nowStr = DateTime.now().toIso8601String();
    await db.update(
      'todos',
      {'is_long_term': 0, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      isLongTerm: false,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
  }

  /// 将待办移动到指定分类
  Future<Todo?> moveToFolder(String id, String folderId) async {
    final db = await _dbHelper.database;
    final existing = await getById(id);
    if (existing == null) return null;

    final nowStr = DateTime.now().toIso8601String();
    await db.update(
      'todos',
      {'folder_id': folderId, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      folderId: folderId,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'todos',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  /// 软删除指定分类下的所有待办
  Future<int> deleteByFolder(String folderId) async {
    final db = await _dbHelper.database;
    final todos = await getByFolder(folderId);
    if (todos.isEmpty) return 0;

    final nowStr = DateTime.now().toIso8601String();
    for (final todo in todos) {
      await db.update(
        'todos',
        {'is_deleted': 1, 'updated_at': nowStr},
        where: 'id = ?',
        whereArgs: [todo.id],
      );
      await _syncLog.logChange(
        tableName: 'todos',
        recordId: todo.id,
        operation: 'update',
        data: {...todo.toMap(), 'is_deleted': 1, 'updated_at': nowStr},
      );
    }
    return todos.length;
  }

  Future<void> batchUpdate(List<Todo> todos) async {
    if (todos.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final todo in todos) {
      batch.update(
        'todos',
        todo.toMap(),
        where: 'id = ?',
        whereArgs: [todo.id],
      );
    }
    await batch.commit(noResult: true);
    
    final syncLogEntries = todos.map((todo) => SyncLogEntry(
      tableName: 'todos',
      recordId: todo.id,
      operation: 'update',
      data: todo.toMap(),
      timestamp: DateTime.now(),
    )).toList();
    await _syncLog.logChanges(syncLogEntries);
  }

  Future<List<Todo>> search(String keyword) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: '(title LIKE ? OR description LIKE ? OR tags LIKE ?) AND is_deleted = 0',
      whereArgs: ['%$keyword%', '%$keyword%', '%$keyword%'],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }
}
