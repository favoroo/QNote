import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/folder.dart';

class FolderRepository {
  static final FolderRepository _instance = FolderRepository._internal();
  factory FolderRepository() => _instance;
  FolderRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  Future<List<Folder>> getAll() async {
    final db = await _dbHelper.database;
    final maps = await db.query('folders', orderBy: 'sort_order ASC, name ASC');
    return maps.map((m) => Folder.fromMap(m)).toList();
  }

  Future<List<Folder>> getByType(String type) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'folders',
      where: 'type = ?',
      whereArgs: [type],
      orderBy: 'sort_order ASC, name ASC',
    );
    return maps.map((m) => Folder.fromMap(m)).toList();
  }

  Future<List<Folder>> getByTypes(List<String> types) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'folders',
      where: 'type IN (${List.filled(types.length, '?').join(',')})',
      whereArgs: types,
      orderBy: 'sort_order ASC, name ASC',
    );
    return maps.map((m) => Folder.fromMap(m)).toList();
  }

  Future<List<Folder>> getSubFolders(String parentId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'folders',
      where: 'parent_id = ?',
      whereArgs: [parentId],
      orderBy: 'sort_order ASC, name ASC',
    );
    return maps.map((m) => Folder.fromMap(m)).toList();
  }

  Future<Folder?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query('folders', where: 'id = ?', whereArgs: [id]);
    if (maps.isEmpty) return null;
    return Folder.fromMap(maps.first);
  }

  Future<Folder> insert(Folder folder) async {
    final db = await _dbHelper.database;
    await db.insert('folders', folder.toMap());
    await _syncLog.logChange(
      tableName: 'folders',
      recordId: folder.id,
      operation: 'insert',
      data: folder.toMap(),
    );
    return folder;
  }

  Future<Folder> update(Folder folder) async {
    final db = await _dbHelper.database;
    final updated = folder.copyWith(updatedAt: DateTime.now());
    await db.update(
      'folders',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [folder.id],
    );
    await _syncLog.logChange(
      tableName: 'folders',
      recordId: folder.id,
      operation: 'update',
      data: updated.toMap(),
    );
    return updated;
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('folders', where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: 'folders',
      recordId: id,
      operation: 'delete',
    );
  }

  Future<void> updateSortOrder(String id, int sortOrder) async {
    final db = await _dbHelper.database;
    final existing = await getById(id);
    if (existing == null) return;

    final nowStr = DateTime.now().toIso8601String();
    await db.update(
      'folders',
      {'sort_order': sortOrder, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      sortOrder: sortOrder,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'folders',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
  }

  Future<void> batchUpdate(List<Folder> folders) async {
    if (folders.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final folder in folders) {
      batch.update(
        'folders',
        folder.toMap(),
        where: 'id = ?',
        whereArgs: [folder.id],
      );
    }
    await batch.commit(noResult: true);

    final syncLogEntries = folders.map((folder) => SyncLogEntry(
      tableName: 'folders',
      recordId: folder.id,
      operation: 'update',
      data: folder.toMap(),
      timestamp: DateTime.now(),
    )).toList();
    await _syncLog.logChanges(syncLogEntries);
  }
}
