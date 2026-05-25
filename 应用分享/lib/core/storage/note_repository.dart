import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/note.dart';

class NoteRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  Future<List<Note>> getAll({bool includeDeleted = false}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'notes',
      where: includeDeleted ? null : 'is_deleted = 0',
      orderBy: 'is_pinned DESC, updated_at DESC',
    );
    return maps.map((m) => Note.fromMap(m)).toList();
  }

  Future<List<Note>> getByFolder(String folderId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'notes',
      where: 'folder_id = ? AND is_deleted = 0',
      whereArgs: [folderId],
      orderBy: 'is_pinned DESC, updated_at DESC',
    );
    return maps.map((m) => Note.fromMap(m)).toList();
  }

  Future<Note?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query('notes', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Note.fromMap(maps.first);
  }

  Future<Note> insert(Note note) async {
    final db = await _dbHelper.database;
    await db.insert('notes', note.toMap());
    await _syncLog.logChange(
      tableName: 'notes',
      recordId: note.id,
      operation: 'insert',
      data: note.toMap(),
    );
    return note;
  }

  Future<Note> update(Note note) async {
    final db = await _dbHelper.database;
    final updated = note.copyWith(updatedAt: DateTime.now());
    await db.update(
      'notes',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [note.id],
    );
    await _syncLog.logChange(
      tableName: 'notes',
      recordId: note.id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<void> softDelete(String id) async {
    final db = await _dbHelper.database;
    await db.update(
      'notes',
      {'is_deleted': 1, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    final existing = await getById(id);
    if (existing != null) {
      await _syncLog.logChange(
        tableName: 'notes',
        recordId: id,
        operation: 'update',
        data: existing.toMap(),
      );
    }
  }

  Future<void> hardDelete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('notes', where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: 'notes',
      recordId: id,
      operation: 'delete',
    );
  }

  Future<void> togglePin(String id, bool isPinned) async {
    final db = await _dbHelper.database;
    await db.update(
      'notes',
      {'is_pinned': isPinned ? 1 : 0, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
    final existing = await getById(id);
    if (existing != null) {
      await _syncLog.logChange(
        tableName: 'notes',
        recordId: id,
        operation: 'update',
        data: existing.toMap(),
      );
    }
  }

  Future<List<Note>> search(String keyword) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'notes',
      where: '(title LIKE ? OR content LIKE ? OR tags LIKE ?) AND is_deleted = 0',
      whereArgs: ['%$keyword%', '%$keyword%', '%$keyword%'],
      orderBy: 'is_pinned DESC, updated_at DESC',
    );
    return maps.map((m) => Note.fromMap(m)).toList();
  }
}
