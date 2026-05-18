import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/todo.dart';

class TodoRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<List<Todo>> getAll({bool includeDeleted = false}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: includeDeleted ? null : 'is_deleted = 0',
      orderBy: 'CASE priority WHEN \'important\' THEN 0 ELSE 1 END, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getByFolder(String folderId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'folder_id = ? AND is_deleted = 0',
      whereArgs: [folderId],
      orderBy: 'CASE priority WHEN \'important\' THEN 0 ELSE 1 END, created_at ASC',
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
      orderBy: 'CASE priority WHEN \'important\' THEN 0 ELSE 1 END, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }

  Future<List<Todo>> getByIsLongTerm(bool isLongTerm) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: 'is_long_term = ? AND is_deleted = 0',
      whereArgs: [isLongTerm ? 1 : 0],
      orderBy: 'CASE priority WHEN \'important\' THEN 0 ELSE 1 END, created_at ASC',
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
    return updated;
  }

  Future<void> softDelete(String id) async {
    final db = await _dbHelper.database;
    await db.update(
      'todos',
      {'is_deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> hardDelete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('todos', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> toggleComplete(String id, bool isCompleted) async {
    final db = await _dbHelper.database;
    await db.update(
      'todos',
      {'is_completed': isCompleted ? 1 : 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> moveToLongTerm(String id) async {
    final db = await _dbHelper.database;
    await db.update(
      'todos',
      {'is_long_term': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> moveToToday(String id) async {
    final db = await _dbHelper.database;
    await db.update(
      'todos',
      {'is_long_term': 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  Future<void> batchUpdate(List<Todo> todos) async {
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
  }

  Future<List<Todo>> search(String keyword) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'todos',
      where: '(title LIKE ? OR description LIKE ? OR tags LIKE ?) AND is_deleted = 0',
      whereArgs: ['%$keyword%', '%$keyword%', '%$keyword%'],
      orderBy: 'CASE priority WHEN \'important\' THEN 0 ELSE 1 END, created_at ASC',
    );
    return maps.map((m) => Todo.fromMap(m)).toList();
  }
}
