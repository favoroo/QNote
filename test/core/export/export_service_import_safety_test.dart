import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/export/export_service.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';

/// 覆盖导入的数据安全边界。
///
/// 覆盖模式会先清空本地全部业务表，所以「什么样的备份文件才算合法」直接决定
/// 用户会不会因为选错一个文件而丢掉全部数据。这里锁住三条底线：
/// 1. 空壳/结构错误的备份必须在清库之前被拒绝；
/// 2. 导入前的本地快照必须真实落盘；
/// 3. 清空所有本地数据必须连带清掉 sync_log 与磁盘图片。
class _MockPathProviderPlatform extends PathProviderPlatform {
  late String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Database db;
  late Directory tempDir;
  final mockPathProvider = _MockPathProviderPlatform();
  final stamp = DateTime.now().millisecondsSinceEpoch;

  String diaryId(String name) => 'ximp_${name}_$stamp';

  Map<String, dynamic> diaryMap(String id) => {
        'id': id,
        'title': '已有日记',
        'content': '不能被空备份清掉',
        'time': DateTime.now().toIso8601String(),
        'mood': 3,
        'weather': '',
        'tags': '[]',
        'photos': '[]',
        'is_deleted': 0,
        'created_at': DateTime.now().toIso8601String(),
        'updated_at': DateTime.now().toIso8601String(),
      };

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('export_import_test');
    mockPathProvider.rootPath = tempDir.path;
    PathProviderPlatform.instance = mockPathProvider;
    await db.delete('diary_records', where: 'id LIKE ?', whereArgs: ['ximp_%']);
  });

  tearDown(() async {
    await db.delete('diary_records', where: 'id LIKE ?', whereArgs: ['ximp_%']);
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('覆盖导入的前置校验', () {
    test('空对象备份被拒绝，且本地数据一条不少', () async {
      final id = diaryId('empty');
      await db.insert('diary_records', diaryMap(id));

      await expectLater(
        ExportService().importFromJsonString('{}', overwrite: true),
        throwsA(isA<Exception>()),
      );

      expect(
        await db.query('diary_records', where: 'id = ?', whereArgs: [id]),
        hasLength(1),
        reason: '空 JSON 过了校验就会清空全部表并提示「导入成功」',
      );
    });

    test('只有版本号字段的备份同样被拒绝', () async {
      await expectLater(
        ExportService().importFromJsonString(
          jsonEncode({'export_version': 2}),
          overwrite: true,
        ),
        throwsA(isA<Exception>()),
      );
    });

    test('表类型错误的备份在清库前就被拒绝', () async {
      final id = diaryId('badtype');
      await db.insert('diary_records', diaryMap(id));

      await expectLater(
        ExportService().importFromJsonString(
          jsonEncode({'diary_records': 'not-a-list'}),
          overwrite: true,
        ),
        throwsA(isA<Exception>()),
      );

      expect(
        await db.query('diary_records', where: 'id = ?', whereArgs: [id]),
        hasLength(1),
      );
    });

    test('记录项不是对象时不会先清库再抛异常', () async {
      final id = diaryId('baditem');
      await db.insert('diary_records', diaryMap(id));

      await expectLater(
        ExportService().importFromJsonString(
          jsonEncode({
            'diary_records': ['not-a-map'],
          }),
          overwrite: true,
        ),
        throwsA(anything),
      );

      expect(
        await db.query('diary_records', where: 'id = ?', whereArgs: [id]),
        hasLength(1),
        reason: '解析必须发生在清库之前，否则失败后数据已经没了',
      );
    });

    test('合并模式下空备份不报错也不动数据', () async {
      final id = diaryId('merge');
      await db.insert('diary_records', diaryMap(id));

      await ExportService().importFromJsonString('{}', overwrite: false);

      expect(
        await db.query('diary_records', where: 'id = ?', whereArgs: [id]),
        hasLength(1),
      );
    });
  });

  group('覆盖导入的本地快照', () {
    test('导入前会把当前数据写入 import_snapshots 目录', () async {
      final id = diaryId('snapshot');
      await db.insert('diary_records', diaryMap(id));

      final emptyBackup = jsonEncode({
        'export_version': 2,
        'diary_records': <dynamic>[],
      });
      await ExportService().importFromJsonString(emptyBackup, overwrite: true);

      final dir = Directory('${tempDir.path}/import_snapshots');
      expect(await dir.exists(), isTrue, reason: '快照目录必须真实创建');

      final snapshots = await dir
          .list()
          .where((f) => f is File)
          .cast<File>()
          .toList();
      expect(snapshots, hasLength(1));

      final content =
          jsonDecode(await snapshots.single.readAsString()) as Map<String, dynamic>;
      final diaries = content['diary_records'] as List;
      expect(
        diaries.any((e) => (e as Map)['id'] == id),
        isTrue,
        reason: '快照要能捞回被清掉的数据，否则等于没做',
      );
    });
  });

  group('清空所有本地数据', () {
    test('清空后 sync_log 与磁盘图片都不残留', () async {
      final id = diaryId('wipe');
      await db.insert('diary_records', diaryMap(id));
      await db.insert('sync_log', {
        'table_name': 'diary_records',
        'record_id': id,
        'operation': 'upsert',
        'data': null,
        'timestamp': DateTime.now().toIso8601String(),
      });

      final imagesDir = Directory('${tempDir.path}/images/diary');
      await imagesDir.create(recursive: true);
      final imageFile = File('${imagesDir.path}/leftover.png');
      await imageFile.writeAsBytes([1, 2, 3]);

      final deleted = await ExportService().wipeAllLocalData();

      expect(deleted, greaterThanOrEqualTo(1));
      expect(await imageFile.exists(), isFalse);
      expect(
        await db.query('sync_log', where: 'record_id = ?', whereArgs: [id]),
        isEmpty,
        reason: '残留变更日志会让下次同步把清空前的数据当增量重新上传',
      );
      expect(
        await db.query('diary_records', where: 'id = ?', whereArgs: [id]),
        isEmpty,
      );
    });
  });
}
