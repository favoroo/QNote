import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/folder.dart';

class FolderRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

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
    return updated;
  }

  Future<void> delete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('folders', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> updateSortOrder(String id, int sortOrder) async {
    final db = await _dbHelper.database;
    await db.update(
      'folders',
      {'sort_order': sortOrder, 'updated_at': DateTime.now().toIso8601String()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }
}
