import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/sync_log_repository.dart';
import 'package:qnote_flutter/models/diary_record.dart';

class DiaryRepository {
  static final DiaryRepository _instance = DiaryRepository._internal();
  factory DiaryRepository() => _instance;
  DiaryRepository._internal();

  final DatabaseHelper _dbHelper = DatabaseHelper.instance;
  final SyncLogRepository _syncLog = SyncLogRepository.instance;

  Future<List<DiaryRecord>> getAll({bool includeDeleted = false}) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'diary_records',
      where: includeDeleted ? null : 'is_deleted = 0',
      orderBy: 'time DESC',
    );
    return maps.map((m) => DiaryRecord.fromMap(m)).toList();
  }

  Future<List<DiaryRecord>> getByDate(DateTime date) async {
    final db = await _dbHelper.database;
    final prevDateStr = date.subtract(const Duration(days: 1)).toIso8601String().split('T').first;
    final nextDateStr = date.add(const Duration(days: 2)).toIso8601String().split('T').first;

    final maps = await db.query(
      'diary_records',
      where: "time >= ? AND time < ? AND is_deleted = 0",
      whereArgs: [prevDateStr, nextDateStr],
      orderBy: 'time DESC',
    );

    final targetDate = DateTime(date.year, date.month, date.day);
    return maps
        .map((m) => DiaryRecord.fromMap(m))
        .where((r) => r.belongsToDate(targetDate))
        .toList();
  }

  Future<List<DiaryRecord>> getByDateRange(DateTime start, DateTime end) async {
    final db = await _dbHelper.database;
    final extendedStart = start.subtract(const Duration(days: 1));
    final extendedStartStr = extendedStart.toIso8601String();
    final endStr = end.toIso8601String();

    final maps = await db.query(
      'diary_records',
      where: 'time >= ? AND time <= ? AND is_deleted = 0',
      whereArgs: [extendedStartStr, endStr],
      orderBy: 'time DESC',
    );

    final targetStart = DateTime(start.year, start.month, start.day);
    final targetEnd = DateTime(end.year, end.month, end.day);

    return maps
        .map((m) => DiaryRecord.fromMap(m))
        .where((r) {
          final effectiveDate = r.getEffectiveDate();
          return !effectiveDate.isBefore(targetStart) && !effectiveDate.isAfter(targetEnd);
        })
        .toList();
  }

  Future<List<DiaryRecord>> getByFolder(String folderId) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'diary_records',
      where: 'folder_id = ? AND is_deleted = 0',
      whereArgs: [folderId],
      orderBy: 'time DESC',
    );
    return maps.map((m) => DiaryRecord.fromMap(m)).toList();
  }

  Future<List<DiaryRecord>> getByTag(String tag) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'diary_records',
      where: 'tags LIKE ? AND is_deleted = 0',
      whereArgs: ['%"$tag"%'],
      orderBy: 'time DESC',
    );
    return maps.map((m) => DiaryRecord.fromMap(m)).toList();
  }

  Future<DiaryRecord?> getById(String id) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'diary_records',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (maps.isEmpty) return null;
    return DiaryRecord.fromMap(maps.first);
  }

  Future<DiaryRecord> insert(DiaryRecord record) async {
    final db = await _dbHelper.database;
    await db.insert('diary_records', record.toMap());
    await _syncLog.logChange(
      tableName: 'diary_records',
      recordId: record.id,
      operation: 'insert',
      data: record.toMap(),
    );
    return record;
  }

  Future<DiaryRecord> update(DiaryRecord record) async {
    final db = await _dbHelper.database;
    final updated = record.copyWith(updatedAt: DateTime.now());
    await db.update(
      'diary_records',
      updated.toMap(),
      where: 'id = ?',
      whereArgs: [record.id],
    );
    await _syncLog.logChange(
      tableName: 'diary_records',
      recordId: record.id,
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
      'diary_records',
      {'is_deleted': 1, 'updated_at': nowStr},
      where: 'id = ?',
      whereArgs: [id],
    );
    final updated = existing.copyWith(
      isDeleted: true,
      updatedAt: DateTime.parse(nowStr),
    );
    await _syncLog.logChange(
      tableName: 'diary_records',
      recordId: id,
      operation: 'update',
      data: updated.toMap(),
    );
  }

  Future<void> hardDelete(String id) async {
    final db = await _dbHelper.database;
    await db.delete('diary_records', where: 'id = ?', whereArgs: [id]);
    await _syncLog.logChange(
      tableName: 'diary_records',
      recordId: id,
      operation: 'delete',
    );
  }

  Future<List<DiaryRecord>> search(String query) async {
    final db = await _dbHelper.database;
    final maps = await db.query(
      'diary_records',
      where: '(title LIKE ? OR content LIKE ? OR tags LIKE ? OR display_tag LIKE ?) AND is_deleted = 0',
      whereArgs: ['%$query%', '%$query%', '%$query%', '%$query%'],
      orderBy: 'time DESC',
    );
    return maps.map((m) => DiaryRecord.fromMap(m)).toList();
  }

  Future<List<DiaryRecord>> getByDateWithSleepByEndTime(DateTime date) async {
    return getByDate(date);
  }

  Future<List<DiaryRecord>> getByDateRangeWithSleepByEndTime(DateTime start, DateTime end) async {
    return getByDateRange(start, end);
  }
}
