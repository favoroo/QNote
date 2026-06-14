import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';

/// 固定事件模板数据访问层
class FixedEventRepository {
  static final FixedEventRepository instance = FixedEventRepository._internal();

  FixedEventRepository._internal();

  /// 获取所有模板
  Future<List<FixedEventTemplate>> getAll() async {
    final db = await DatabaseHelper.instance.database;
    final maps = await db.query(
      'fixed_event_templates',
      orderBy: 'sort_order ASC',
    );
    return maps.map((m) => FixedEventTemplate.fromMap(m)).toList();
  }

  /// 获取启用的模板
  Future<List<FixedEventTemplate>> getEnabled() async {
    final db = await DatabaseHelper.instance.database;
    final maps = await db.query(
      'fixed_event_templates',
      where: 'is_enabled = ?',
      whereArgs: [1],
      orderBy: 'sort_order ASC',
    );
    return maps.map((m) => FixedEventTemplate.fromMap(m)).toList();
  }

  /// 根据 ID 获取单个模板
  Future<FixedEventTemplate?> getById(String id) async {
    final db = await DatabaseHelper.instance.database;
    final maps = await db.query(
      'fixed_event_templates',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (maps.isEmpty) return null;
    return FixedEventTemplate.fromMap(maps.first);
  }

  /// 新增模板
  Future<void> insert(FixedEventTemplate template) async {
    final db = await DatabaseHelper.instance.database;
    await db.insert(
      'fixed_event_templates',
      template.toMap(),
    );
  }

  /// 更新模板
  Future<void> update(FixedEventTemplate template) async {
    final db = await DatabaseHelper.instance.database;
    await db.update(
      'fixed_event_templates',
      template.toMap(),
      where: 'id = ?',
      whereArgs: [template.id],
    );
  }

  /// 删除模板
  Future<void> delete(String id) async {
    final db = await DatabaseHelper.instance.database;
    await db.delete(
      'fixed_event_templates',
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  /// 清空所有模板
  Future<void> deleteAll() async {
    final db = await DatabaseHelper.instance.database;
    await db.delete('fixed_event_templates');
  }
}