import 'package:sqflite/sqflite.dart';
import 'package:qnote_flutter/models/date_color_mark.dart';
import 'database_helper.dart';

class ColorMarkRepository {
  final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  Future<Database> get _db async => await _dbHelper.database;

  Future<DateColorMark?> getByDate(DateTime date) async {
    final db = await _db;
    final dateStr = date.toIso8601String().split('T').first;
    final results = await db.query(
      'date_color_marks',
      where: 'date = ?',
      whereArgs: [dateStr],
    );
    if (results.isEmpty) return null;
    return DateColorMark.fromMap(results.first);
  }

  Future<List<DateColorMark>> getAll() async {
    final db = await _db;
    final results = await db.query('date_color_marks', orderBy: 'date DESC');
    return results.map((m) => DateColorMark.fromMap(m)).toList();
  }

  Future<void> insert(DateColorMark mark) async {
    final db = await _db;
    await db.insert('date_color_marks', mark.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> delete(String id) async {
    final db = await _db;
    await db.delete('date_color_marks', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteByDate(DateTime date) async {
    final db = await _db;
    final dateStr = date.toIso8601String().split('T').first;
    await db.delete('date_color_marks', where: 'date = ?', whereArgs: [dateStr]);
  }
}
