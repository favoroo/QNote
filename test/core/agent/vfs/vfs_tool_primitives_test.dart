import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';

/// VFS 工具层优化回归测试
///
/// 覆盖四类曾被绕开的能力：grep 回传可操作路径、id 路径写入不产生脏数据、
/// 行号前缀容错、追加模式与移动原语。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final vfs = VirtualWorkspaceService.instance;
  final todoRepo = TodoRepository();
  final diaryRepo = DiaryRepository();

  group('VFS 检索与写入原语', () {
    test('grep 命中携带可直接用于读写的虚拟路径', () async {
      await vfs.writeFile(
        '/todos/检索分类/找得到我.md',
        '---\npriority: normal\n---\n关键词：紫罗兰计划',
      );

      final hits = await vfs.grep('紫罗兰计划', scope: 'todos');
      expect(hits, isNotEmpty, reason: '应能按待办范围检索到');

      final hit = hits.firstWhere((h) => h['title'] == '找得到我');
      expect(hit['path'], '/todos/检索分类/找得到我.md');
      expect(hit['id'], isNotEmpty, reason: '仍需保留实体 id 供精确删除');

      // 关键：返回的路径必须可直接喂给 read_file，而不是只能拿到裸 id
      final content = await vfs.readFile(hit['path'] as String);
      expect(content, contains('紫罗兰计划'));
    });

    test('按实体 id 路径写入命中既有实体，且不把 id 顶成标题', () async {
      final created = await vfs.writeFile(
        '/todos/脏数据防护/原始标题.md',
        '---\npriority: normal\n---\n原始备注',
      );
      final id = created['id'] as String;
      final folderId = created['folder_id'] as String;

      // 场景 1：正文不带 id 的 id 路径写入（grep 命中、页面上下文提示都会产出这种路径）
      await vfs.writeFile(
        '/todos/脏数据防护/$id.md',
        '---\npriority: important\n---\n改过的备注',
      );

      var all = await todoRepo.getAll();
      var matched = all.where((t) => t.id == id).toList();
      expect(matched.length, 1, reason: '不应产生第二条记录');
      expect(matched.first.title, '原始标题', reason: 'id 不能被当成新标题写回');
      expect(matched.first.priority, 'important', reason: '内容应真的被更新');

      // 场景 2：撤回恢复形态——正文自带 id: 且路径为 id 路径（历史 UUID 标题脏数据的真实成因）
      final snapshot = await vfs.readFile('/todos/脏数据防护/$id.md');
      expect(snapshot, contains('id:'), reason: '前提：读取回显带 frontmatter id');
      await vfs.writeFile('/todos/脏数据防护/$id.md', snapshot);

      all = await todoRepo.getAll();
      matched = all.where((t) => t.id == id).toList();
      expect(matched.length, 1, reason: '恢复快照不应产生新记录');
      expect(matched.first.title, '原始标题', reason: '恢复快照不能把 UUID 顶成标题');

      // 只校验本用例所属分类，避免受历史运行遗留数据干扰
      expect(
        all
            .where((t) => t.folderId == folderId)
            .where((t) => RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-').hasMatch(t.title))
            .isEmpty,
        isTrue,
        reason: '不应出现 UUID 标题的脏待办',
      );
    });

    test('edit_file 容忍照抄回显带来的行号前缀', () async {
      await vfs.writeFile('/notes/笔记本/带行号.md', '第一行内容\n第二行内容\n第三行内容');
      final readBack = await vfs.readFile('/notes/笔记本/带行号.md');
      // 模拟模型照抄 read_file 回显（含「行号 + 制表符」前缀）作为 old_text
      final copied = readBack.split('\n').firstWhere((l) => l.contains('第二行内容'));
      expect(copied, contains('\t'), reason: '前提：回显确实带行号前缀');

      await vfs.editFile('/notes/笔记本/带行号.md', copied, '第二行已改写');

      final after = await vfs.readFile('/notes/笔记本/带行号.md');
      expect(after, contains('第二行已改写'));
      expect(after, isNot(contains('第二行内容')));
    });

    test('write_file 追加模式：时间线追加保留已有事件', () async {
      const day = '2026-03-05';
      await vfs.writeFile(
        '/timeline/$day.md',
        '## [09:00] 事件A\n- 分类: 工作\n- 心情: 4',
      );
      await vfs.writeFile(
        '/timeline/$day.md',
        '## [20:00] 事件B\n- 分类: 日常\n- 心情: 3',
        append: true,
      );

      final content = await vfs.readFile('/timeline/$day.md');
      expect(content, contains('事件A'), reason: '追加不应覆盖已有事件');
      expect(content, contains('事件B'));

      final records = await diaryRepo.getByDate(DateTime(2026, 3, 5));
      expect(records.length, 2, reason: '两条流水都应落库');
    });

    test('追加模式在空态日不把占位文案当正文', () async {
      const day = '2026-03-06';
      await vfs.writeFile(
        '/timeline/$day.md',
        '## [08:00] 唯一事件\n- 分类: 日常',
        append: true,
      );

      final content = await vfs.readFile('/timeline/$day.md');
      expect(content, contains('唯一事件'));
      expect(content, isNot(contains('暂无流水事件打卡')), reason: '占位文案应被丢弃');
    });

    test('追加模式对 JSON 配置端点报错', () async {
      expect(
        () => vfs.writeFile('/settings/weight.json', '{"weight": 68}', append: true),
        throwsA(isA<Exception>()),
      );
    });

    test('move_file 一步完成改分类与改名', () async {
      final created = await vfs.writeFile(
        '/todos/移动源分类/待搬走.md',
        '---\npriority: normal\n---\n搬家前的备注',
      );
      final id = created['id'] as String;

      final res = await vfs.moveFile(
        '/todos/移动源分类/待搬走.md',
        '/todos/移动目标分类/搬过来了.md',
      );
      expect(res['status'], 'moved');

      final all = await todoRepo.getAll();
      final matched = all.where((t) => t.id == id).toList();
      expect(matched.length, 1, reason: '移动不应产生重复条目');
      expect(matched.first.title, '搬过来了');
      expect(res['folder'], '移动目标分类');
    });

    test('list_dir 递归返回整棵目录树的完整路径', () async {
      final tree = await vfs.listDir('/', recursive: true);
      // 广度优先：顶层各目录先铺开，即使条目超限被截断也不会整段子树消失
      expect(tree, contains('/todos/'));
      expect(tree, contains('/settings/'));
      expect(
        tree.any((p) => p.startsWith('/todos/') && p.endsWith('.md')),
        isTrue,
        reason: '应展开到具体条目',
      );
      expect(
        tree.any((p) => p.contains('//')),
        isFalse,
        reason: '不应出现双斜杠拼接的路径',
      );
    });

    test('grep 支持记忆与配置范围', () async {
      await vfs.writeFile('/settings/weight.json', '{"weight": 66.6}');

      final hits = await vfs.grep('66.6', scope: 'settings');
      expect(hits, isNotEmpty);
      final weightHit = hits.firstWhere((h) => h['path'] == '/settings/weight.json');
      expect(weightHit['line'], isA<int>(), reason: '行级命中应带行号供 read_file 定位');
    });
  });
}
