import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/storage/widget_snapshot_repository.dart';
import 'package:qnote_flutter/core/utils/widget_snapshot_service.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/models/widget_snapshot.dart';

/// 桌面小组件快照链路测试（仓储读写 + 今日待办计数口径）。
///
/// 两块放在同一个文件里是有意的：ffi 后端下所有测试 isolate 共用同一个 qnote.db
/// 文件，各文件各自 delete 同一张表会互相清掉对方的数据。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late Database db;
  final repo = WidgetSnapshotRepository();
  final todoRepo = TodoRepository();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // 走 DatabaseHelper 建库，顺带验证 v24 的 DDL 真的能建出表
    db = await DatabaseHelper.instance.database;
  });

  setUp(() async {
    await db.delete(WidgetSnapshotRepository.table);
    await db.delete('todos');
  });

  /// 本 App 的「今日」是文件夹而不是日期（见 lib/pages/todo_page.dart 的
  /// currentFolderTodoIds 判定）。组件不再自己复现这条规则，改读这里写出的快照，
  /// 因此规则一旦改动本测试必须同步，否则桌面数字会与 App 内静默不一致。
  Future<int?> snapshotCount() async {
    return (await repo.get(WidgetSnapshotKeys.todoPendingToday))?.intValue;
  }

  Future<void> seedTodo(
    String id, {
    String? folderId,
    bool isLongTerm = false,
    bool isCompleted = false,
    String title = '事项',
  }) async {
    await todoRepo.insert(
      Todo(
        id: id,
        title: title,
        folderId: folderId,
        isLongTerm: isLongTerm,
        isCompleted: isCompleted,
        createdAt: DateTime(2026, 9, 19),
        updatedAt: DateTime(2026, 9, 19),
      ),
    );
  }

  group('WidgetSnapshotRepository', () {
    test('表已由数据库迁移创建，且支持 put/get 往返', () async {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
        [WidgetSnapshotRepository.table],
      );
      expect(tables, hasLength(1));

      await repo.put(
        WidgetSnapshot(
          key: 'todo.pending_today',
          valueNum: 3,
          updatedAt: DateTime.now(),
        ),
      );
      final loaded = await repo.get('todo.pending_today');
      expect(loaded?.intValue, 3);
      expect(loaded?.date, '');
      expect(loaded?.id, 'todo.pending_today|');
    });

    test('同 (key, date) 覆盖为一行，不同 date 各自独立', () async {
      final now = DateTime.now();
      await repo.put(WidgetSnapshot(key: 'finance.daily', date: '2026-09-19', valueNum: 1, updatedAt: now));
      await repo.put(WidgetSnapshot(key: 'finance.daily', date: '2026-09-19', valueNum: 42, updatedAt: now));
      await repo.put(WidgetSnapshot(key: 'finance.daily', date: '2026-09-18', valueNum: 7, updatedAt: now));

      expect((await repo.get('finance.daily', date: '2026-09-19'))?.intValue, 42);
      expect((await repo.get('finance.daily', date: '2026-09-18'))?.intValue, 7);
      expect(await repo.getAll(date: '2026-09-19'), hasLength(1));
      expect(await repo.getAll(date: '2026-09-18'), hasLength(1));
    });

    test('payload 与含引号换行的文本能完整往返', () async {
      const tricky = '他说"今天"要做\n第二行 \\ 反斜杠';
      await repo.put(
        WidgetSnapshot(
          key: 'score.daily',
          date: '2026-09-19',
          valueNum: 88,
          valueText: tricky,
          payload: {'summary': tricky, 'nested': 1},
          updatedAt: DateTime.now(),
        ),
      );

      final loaded = await repo.get('score.daily', date: '2026-09-19');
      expect(loaded?.valueText, tricky);
      expect(loaded?.payload?['summary'], tricky);
      expect(loaded?.payload?['nested'], 1);
    });

    test('读取不存在的键返回 null，供原生侧回落到自查 SQL', () async {
      expect(await repo.get('never.written'), isNull);
    });

    test('hardDelete 精确到 (key, date)', () async {
      final now = DateTime.now();
      await repo.putAll([
        WidgetSnapshot(key: 'k', date: '', valueNum: 1, updatedAt: now),
        WidgetSnapshot(key: 'k', date: '2026-09-19', valueNum: 2, updatedAt: now),
      ]);

      expect(await repo.hardDelete('k'), 1);
      expect(await repo.get('k'), isNull);
      expect((await repo.get('k', date: '2026-09-19'))?.intValue, 2);
    });
  });

  group('WidgetSnapshotService 今日待办口径', () {
    test('显式挂在今日文件夹的未完成待办计入', () async {
      await seedTodo('a', folderId: 'todo_default_today');
      await seedTodo('b', folderId: 'todo_default_today');
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 2);
    });

    test('未分配文件夹且非长期的待办计入今日', () async {
      await seedTodo('null-folder');
      await seedTodo('empty-folder', folderId: '');
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 2);
    });

    test('其它文件夹的待办不计入今日（组件此前的漏判）', () async {
      await seedTodo('mine', folderId: 'todo_default_today');
      await seedTodo('work', folderId: 'some_other_folder');
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 1);
    });

    test('未分配文件夹的长期待办不计入今日', () async {
      await seedTodo('unassigned-longterm', isLongTerm: true);
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 0);
    });

    test('文件夹归属优先：显式挂在今日文件夹下的长期待办照样计入', () async {
      // App 端先按 folderId 命中再谈长期，桌面口径必须跟随；原生兜底 SQL 也是这个
      // 形状，两处一旦分叉，快照缺失时的计数就会和平时不一样
      await seedTodo('today-longterm', folderId: 'todo_default_today', isLongTerm: true);
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 1);
    });

    test('已完成与空标题的待办不计入', () async {
      await seedTodo('done', folderId: 'todo_default_today', isCompleted: true);
      await seedTodo('blank', folderId: 'todo_default_today', title: '   ');
      await seedTodo('valid', folderId: 'todo_default_today');
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 1);
    });

    test('重复调用覆盖为最新值，不累积多行', () async {
      await seedTodo('one', folderId: 'todo_default_today');
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 1);

      await seedTodo('two', folderId: 'todo_default_today');
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 2);

      final rows = await repo.getAll();
      expect(rows, hasLength(1));
    });

    test('无待办时写入 0 而不是留空，避免组件回落到旧口径', () async {
      await WidgetSnapshotService.writeTodoSnapshot();
      expect(await snapshotCount(), 0);
    });
  });
}
