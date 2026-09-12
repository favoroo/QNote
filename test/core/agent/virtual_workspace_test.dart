import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/agent/vfs/workspace_event_bus.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('VirtualWorkspace (VFS) 虚拟工作区与 Skill 机制测试', () {
    final vfs = VirtualWorkspaceService.instance;
    final dispatcher = AgentToolRegistry.createDefaultDispatcher();
    final todoRepo = TodoRepository();

    test('1. AGENTS.md 与 Skill 手册加载', () async {
      final agentsContent = await vfs.readFile('/AGENTS.md');
      expect(agentsContent, contains('QNote Agent Operating System'));
      expect(agentsContent, contains('/todos/'));

      final skills = SkillRegistry.instance.listSkills();
      expect(skills.length, greaterThanOrEqualTo(5));

      final todoSkill = SkillRegistry.instance.getSkillContent('todo-manager');
      expect(todoSkill, isNotNull);
      expect(todoSkill, contains('待办事项管理技能'));

      final skillFileRead = await vfs.readFile('/skills/todo-manager.md');
      expect(skillFileRead, contains('todo-manager'));
    });

    test('2. 目录遍历 list_dir', () async {
      final rootItems = await vfs.listDir('/');
      expect(rootItems, contains('todos/'));
      expect(rootItems, contains('skills/'));
      expect(rootItems, contains('AGENTS.md'));

      final todoFolders = await vfs.listDir('/todos');
      expect(todoFolders, contains('今日/'));
    });

    test('3. write_file: 写入待办并自动创建分类', () async {
      // 写入到自定义分类 "工作项目"
      final res = await vfs.writeFile(
        '/todos/工作项目/准备周报.md',
        '---\npriority: important\ndue_date: "2026-09-15 18:00"\n---\n本周工作总结与下周计划',
      );
      expect(res['status'], anyOf('created', 'updated'));
      expect(res['folder'], '工作项目');

      // 验证在 SQLite 中能查到
      final all = await todoRepo.getAll();
      final created = all.where((t) => t.title == '准备周报').firstOrNull;
      expect(created, isNotNull);
      expect(created!.priority, 'important');
      expect(created.folderId, isNotNull);
      expect(created.folderId, isNotEmpty);
    });

    test('4. read_file: 读取待办 Frontmatter 与内容', () async {
      final content = await vfs.readFile('/todos/工作项目/准备周报.md');
      expect(content, contains('title: "准备周报"'));
      expect(content, contains('priority: important'));
      expect(content, contains('本周工作总结与下周计划'));
    });

    test('5. edit_file: 精准文本替换（标记完成）', () async {
      final editRes = await vfs.editFile(
        '/todos/工作项目/准备周报.md',
        'status: pending',
        'status: completed',
      );
      expect(editRes['status'], 'updated');

      final all = await todoRepo.getAll();
      final updated = all.where((t) => t.title == '准备周报').firstOrNull;
      expect(updated, isNotNull);
      expect(updated!.isCompleted, isTrue);
    });

    test('6. WorkspaceEventBus 变更监听', () async {
      bool eventReceived = false;
      void listener(WorkspaceChangeEvent e) {
        if (e.path.contains('测试待办')) {
          eventReceived = true;
        }
      }

      WorkspaceEventBus.instance.addListener(listener);
      await vfs.writeFile('/todos/今日/测试待办.md', '这是测试待办内容');
      WorkspaceEventBus.instance.removeListener(listener);

      expect(eventReceived, isTrue);
    });

    test('7. 通过 Agent Dispatcher 执行新工具', () async {
      // 验证 skill 工具调用
      final skillCall = await dispatcher.dispatch(
        const ToolCall(id: 'call_skill', name: 'skill', arguments: {'name': 'note-manager'}),
      );
      expect(skillCall.isError, isFalse);
      expect(skillCall.content, contains('笔记与知识库管理技能'));

      // 验证 list_dir 工具调用
      final listCall = await dispatcher.dispatch(
        const ToolCall(id: 'call_list', name: 'list_dir', arguments: {'path': '/todos'}),
      );
      expect(listCall.isError, isFalse);
      expect(listCall.content, contains('今日/'));
    });

    test('8. timeline: 写入多条、edit_file 差量删除、单条ID删除与清空验证', () async {
      final diaryRepo = DiaryRepository();
      const testDateStr = '2026-09-11';
      final testPath = '/timeline/$testDateStr.md';

      // 1. 写入两条时间线记录
      final writeRes = await vfs.writeFile(
        testPath,
        '# 2026-09-11 时间线流水\n\n'
        '## [07:48] 早餐\n'
        '- 分类: 饮食\n'
        '- 心情: 3\n'
        '- 详情: A2 鲜牛奶\n\n'
        '## [12:00] 午餐\n'
        '- 分类: 饮食\n'
        '- 心情: 3\n'
        '- 详情: 中午吃了一碗方便面\n',
      );
      expect(writeRes['status'], 'success');
      expect(writeRes['records_processed'], 2);

      // 验证 SQLite 中确实有 2 条未删除记录
      var currentRecords = await diaryRepo.getByDate(DateTime.parse(testDateStr));
      expect(currentRecords.length, 2);

      // 读取内容，验证包含 id 隐藏注释
      final readContent = await vfs.readFile(testPath);
      expect(readContent, contains('午餐'));
      expect(readContent, contains('A2 鲜牛奶'));
      expect(readContent, contains('<!-- id: '));

      // 提取方便面记录的 ID
      final noodleRecord = currentRecords.firstWhere((r) => r.title == '午餐');
      final milkRecord = currentRecords.firstWhere((r) => r.title == '早餐');

      // 2. 模拟小Q的行为：用 edit_file 替换删除方便面整块（小Q在问题中使用的典型方式）
      // 去掉行号后提取块文本进行替换
      final cleanContent = readContent.split('\n').map((l) => l.replaceFirst(RegExp(r'^\d+\t'), '')).join('\n');
      final noodleBlockRegex = RegExp(r'##\s*\[12:00\]\s*午餐[\s\S]*?(?=(##|$))');
      final blockToReplace = noodleBlockRegex.firstMatch(cleanContent)!.group(0)!;
      
      final editRes = await vfs.editFile(testPath, blockToReplace, '');
      expect(editRes['status'], 'success');
      expect(editRes['records_deleted'], 1);

      // 核心验证：验证数据库中方便面已被软删除，仅剩鲜牛奶
      currentRecords = await diaryRepo.getByDate(DateTime.parse(testDateStr));
      expect(currentRecords.length, 1);
      expect(currentRecords.first.id, milkRecord.id);

      // 再次 read_file，验证返回的内容中方便面已不复存在
      final readAfterDelete = await vfs.readFile(testPath);
      expect(readAfterDelete, contains('早餐'));
      expect(readAfterDelete, isNot(contains('午餐')));
      expect(readAfterDelete, isNot(contains('方便面')));

      // 3. 验证通过 delete_file 精准删除单条记录
      final deleteSingleRes = await vfs.deleteFile('/timeline/${milkRecord.id}.md');
      expect(deleteSingleRes['status'], 'deleted');
      expect(deleteSingleRes['id'], milkRecord.id);

      currentRecords = await diaryRepo.getByDate(DateTime.parse(testDateStr));
      expect(currentRecords.isEmpty, isTrue);

      // 4. 再次写入一条，测试显式清空
      await vfs.writeFile(
        testPath,
        '## [20:00] 散步\n- 分类: 运动\n- 详情: 晚间慢走 3 公里\n',
      );
      expect((await diaryRepo.getByDate(DateTime.parse(testDateStr))).length, 1);

      // 通过写入纯标题/空内容显式清空
      final clearRes = await vfs.writeFile(testPath, '# 2026-09-11 时间线流水\n\n> 暂无流水事件打卡。');
      expect(clearRes['status'], 'success');
      expect(clearRes['records_deleted'], 1);
      expect((await diaryRepo.getByDate(DateTime.parse(testDateStr))).isEmpty, isTrue);
    });

    test('9. settings: appearance.json 读写与个性化外观切换', () async {
      // 1. 验证 list_dir /settings
      final settingsList = await vfs.listDir('/settings');
      expect(settingsList, contains('appearance.json'));
      expect(settingsList, contains('ai.json'));
      expect(settingsList, contains('shortcuts.json'));
      expect(settingsList, contains('fixed_events.json'));
      expect(settingsList, contains('profile.json'));
      expect(settingsList, contains('webdav.json'));

      // 2. 读默认 appearance.json
      final initialRead = await vfs.readFile('/settings/appearance.json');
      expect(initialRead, contains('themeMode'));
      expect(initialRead, contains('accentColor'));

      // 3. 写入新外观配置（深色模式 + 玫瑰粉红 #E91E8C）
      final writeRes = await vfs.writeFile(
        '/settings/appearance.json',
        '{"themeMode": "dark", "accentColor": "#E91E8C"}',
      );
      expect(writeRes['status'], 'updated');

      // 4. 验证持久化与再次读取
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('theme_mode'), 2); // ThemeMode.dark.index == 2

      final readAfter = await vfs.readFile('/settings/appearance.json');
      expect(readAfter, contains('"themeMode": "dark"'));
      expect(readAfter, contains('"accentColor": "#E91E8C"'));

      // 5. 支持色彩别名与中文模式（如 "浅色" 与 "green"）
      await vfs.writeFile(
        '/settings/appearance.json',
        '{"themeMode": "浅色", "accentColor": "green"}',
      );
      expect(prefs.getInt('theme_mode'), 1); // ThemeMode.light.index == 1
      final readGreen = await vfs.readFile('/settings/appearance.json');
      expect(readGreen, contains('"themeMode": "light"'));
      expect(readGreen, contains('"accentColor": "#00E676"'));
    });

    test('10. settings: ai.json 角色分配与模型超参数读写', () async {
      // 1. 读取初始 ai.json
      final aiRead = await vfs.readFile('/settings/ai.json');
      expect(aiRead, contains('roles'));
      expect(aiRead, contains('temperatures'));
      expect(aiRead, contains('assistant'));
      expect(aiRead, contains('timelineOptimization'));

      // 2. 更新小Q模型分配与温度参数
      final writeAiRes = await vfs.writeFile(
        '/settings/ai.json',
        '''
        {
          "roles": {
            "assistant": {
              "useFreeModel": true,
              "freeModelId": "glm-5.2"
            }
          },
          "temperatures": {
            "assistant": {
              "temperature": 0.35,
              "maxTokens": 4096
            }
          }
        }
        ''',
      );
      expect(writeAiRes['status'], 'updated');

      // 3. 验证再次读取包含修改后的模型与温度
      final aiReadAfter = await vfs.readFile('/settings/ai.json');
      expect(aiReadAfter, contains('glm-5.2'));
      expect(aiReadAfter, contains('0.35'));
    });

    test('11. settings: shortcuts.json 快捷按键解锁写入与定制', () async {
      final writeShortcutsRes = await vfs.writeFile(
        '/settings/shortcuts.json',
        '''
        [
          {
            "id": "shortcut_water_1",
            "name": "喝水打卡",
            "hasPopup": false,
            "sortOrder": 0,
            "isVisible": true
          }
        ]
        ''',
      );
      expect(writeShortcutsRes['status'], 'updated');
      expect(writeShortcutsRes['count'], 1);

      final readShortcuts = await vfs.readFile('/settings/shortcuts.json');
      expect(readShortcuts, contains('喝水打卡'));
      expect(readShortcuts, contains('shortcut_water_1'));
    });

    test('12. settings: fixed_events.json 固定作息模板管理', () async {
      final writeEventsRes = await vfs.writeFile(
        '/settings/fixed_events.json',
        '''
        [
          {
            "id": "fixed_sleep_test",
            "name": "夜间睡眠",
            "startTime": "23:30",
            "endTime": "07:30",
            "isTimePoint": false,
            "isEnabled": true
          }
        ]
        ''',
      );
      expect(writeEventsRes['status'], 'updated');
      expect(writeEventsRes['count'], 1);

      final readEvents = await vfs.readFile('/settings/fixed_events.json');
      expect(readEvents, contains('夜间睡眠'));
      expect(readEvents, contains('23:30'));
    });

    test('13. settings: profile.json 增量更新不丢失原有信息', () async {
      // 1. 初始化用户资料
      await vfs.writeFile(
        '/settings/profile.json',
        '{"name": "小明", "gender": "male", "height": 175.0, "weightHistory": []}',
      );

      // 2. 增量更新昵称
      final partialUpdate = await vfs.writeFile(
        '/settings/profile.json',
        '{"nickname": "阿明"}',
      );
      expect(partialUpdate['status'], 'updated');

      // 3. 验证身高、性别等未丢失
      final profileRead = await vfs.readFile('/settings/profile.json');
      expect(profileRead, contains('"nickname": "阿明"'));
      expect(profileRead, contains('"height": 175.0'));
      expect(profileRead, contains('"gender": "male"'));
    });

    test('14. todos: repeat_rule 重复规则与 tags 标签支持', () async {
      await vfs.writeFile(
        '/todos/今日/每天跑步打卡.md',
        '''---
status: pending
priority: important
repeat_rule: daily
tags: "运动,健康"
---
每日傍晚跑步 5 公里''',
      );

      final readContent = await vfs.readFile('/todos/今日/每天跑步打卡.md');
      expect(readContent, contains('repeat_rule: "daily"'));
      expect(readContent, contains('tags: "运动,健康"'));

      final all = await todoRepo.getAll();
      final runningTodo = all.where((t) => t.title == '每天跑步打卡').firstOrNull;
      expect(runningTodo, isNotNull);
      expect(runningTodo!.repeatRule, 'daily');
      expect(runningTodo.tags, '运动,健康');
    });

    test('15. folders: /folders/ 虚拟端点、重命名分类与目录级删除', () async {
      // 1. 验证 list_dir /folders
      final folderFiles = await vfs.listDir('/folders');
      expect(folderFiles, contains('todos.json'));
      expect(folderFiles, contains('notes.json'));

      // 2. 读取 todos.json
      final todosFoldersRead = await vfs.readFile('/folders/todos.json');
      expect(todosFoldersRead, contains('今日'));

      // 3. 新建与重命名分类
      final updateRes = await vfs.writeFile(
        '/folders/todos.json',
        '''
        [
          { "id": "todo_custom_gym", "name": "健身运动", "sortOrder": 5 }
        ]
        ''',
      );
      expect(updateRes['status'], 'updated');

      final readAfterUpdate = await vfs.readFile('/folders/todos.json');
      expect(readAfterUpdate, contains('健身运动'));

      // 4. 在新分类下建待办，然后通过目录路径删除该分类
      await vfs.writeFile('/todos/健身运动/深蹲测试.md', '深蹲 50 次');
      final delFolderRes = await vfs.deleteFile('/todos/健身运动/');
      expect(delFolderRes['status'], 'deleted');
      expect(delFolderRes['folder'], '健身运动');

      // 验证待办已被删除
      final all = await todoRepo.getAll();
      expect(all.where((t) => t.title == '深蹲测试').isEmpty, isTrue);
    });

    test('16. timeline: 时间跨度 [09:00 - 11:30] 与自定义结构化指标', () async {
      const testDate = '2026-09-12';
      final path = '/timeline/$testDate.md';

      await vfs.writeFile(
        path,
        '''# 2026-09-12 时间线

## [09:00 - 11:30] 上午系统重构评审
- 分类: 工作
- 心情: 5
- 天气: 晴
- 饮水: 600ml
- 消费金额: 45.0
- 详情: 完成了全能小Q全量数据管理的最终架构评审
''',
      );

      final readContent = await vfs.readFile(path);
      expect(readContent, contains('[09:00 - 11:30]'));
      expect(readContent, contains('饮水: 600ml'));
      expect(readContent, contains('消费金额: 45.0'));

      final records = await DiaryRepository().getByDate(DateTime.parse(testDate));
      final record = records.firstWhere((r) => r.title.contains('系统重构评审'));
      expect(record.tagEntries.isNotEmpty, isTrue);
      expect(record.tagEntries.first.fields['饮水'], '600ml');
      expect(record.weather, '晴');
    });

    test('17. settings: weight.json 快捷记体重与趋势统计', () async {
      final writeWeightRes = await vfs.writeFile(
        '/settings/weight.json',
        '{"weight": 68.4}',
      );
      expect(writeWeightRes['status'], 'created');
      expect(writeWeightRes['weight'], 68.4);

      final readWeight = await vfs.readFile('/settings/weight.json');
      expect(readWeight, contains('latestWeight'));
      expect(readWeight, contains('68.4'));
    });

    test('18. stats: /stats/ 数据洞察端点读取', () async {
      final statsList = await vfs.listDir('/stats');
      expect(statsList, contains('summary.json'));
      expect(statsList, contains('daily_scores.json'));

      final summary = await vfs.readFile('/stats/summary.json');
      expect(summary, contains('todos'));
      expect(summary, contains('timeline'));
      expect(summary, contains('completionRate'));

      final scores = await vfs.readFile('/stats/daily_scores.json');
      expect(scores, isNotNull);
    });

    test('19. grep: 全局检索跨待办、笔记与时间线流水', () async {
      final grepRes = await vfs.grep('系统重构评审');
      expect(grepRes.isNotEmpty, isTrue);
      expect(grepRes.first['type'], 'timeline');
      expect(grepRes.first['path'], contains('/timeline/'));
    });

    test('20. settings: color_marks.json 日历高光打点与清除', () async {
      // 1. 设置日期高光标记（2026-09-15 红色）
      final markRes = await vfs.writeFile(
        '/settings/color_marks.json',
        '{"date": "2026-09-15", "color": "红色"}',
      );
      expect(markRes['status'], 'updated');

      final readMarks = await vfs.readFile('/settings/color_marks.json');
      expect(readMarks, contains('2026-09-15'));
      expect(readMarks, contains('#FFFF3B30'));

      // 2. 清除该日期标记
      final clearRes = await vfs.writeFile(
        '/settings/color_marks.json',
        '{"date": "2026-09-15", "color": "none"}',
      );
      expect(clearRes['status'], 'updated');

      final readMarksAfter = await vfs.readFile('/settings/color_marks.json');
      expect(readMarksAfter, isNot(contains('2026-09-15')));
    });

    test('21. chats: /chats/sessions.json 历史会话查看、重命名与软删除', () async {
      // 1. 验证 list_dir /chats
      final chatFiles = await vfs.listDir('/chats');
      expect(chatFiles, contains('sessions.json'));

      final testSessionId = 'test_session_${DateTime.now().millisecondsSinceEpoch}';
      // 2. 写入一条新会话到数据库用于测试
      final session = ChatSession(
        id: testSessionId,
        title: '初始测试对话',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await ConfigRepository.instance.insertChatSession(session);

      // 3. 读取 sessions.json
      final sessionsRead = await vfs.readFile('/chats/sessions.json');
      expect(sessionsRead, contains(testSessionId));
      expect(sessionsRead, contains('初始测试对话'));

      // 4. 重命名会话
      final renameRes = await vfs.writeFile(
        '/chats/sessions.json',
        '[{"id": "$testSessionId", "title": "全能小Q开发方案"}]',
      );
      expect(renameRes['status'], 'updated');
      expect(renameRes['updated_count'], 1);

      final readAfterRename = await vfs.readFile('/chats/sessions.json');
      expect(readAfterRename, contains('全能小Q开发方案'));

      // 5. 软删除会话
      final delSessionRes = await vfs.deleteFile('/chats/$testSessionId.json');
      expect(delSessionRes['status'], 'deleted');

      final readAfterDel = await vfs.readFile('/chats/sessions.json');
      expect(readAfterDel, isNot(contains(testSessionId)));
    });

    test('22. skills: folder-manager 技能手册加载', () async {
      final folderSkill = SkillRegistry.instance.getSkillContent('folder-manager');
      expect(folderSkill, isNotNull);
      expect(folderSkill, contains('分类与笔记本目录管理技能'));
      expect(folderSkill, contains('/folders/todos.json'));
    });
  });

  group('VFS 变更录制（对话撤回 undoLog）测试', () {
    final vfs = VirtualWorkspaceService.instance;
    final todoRepo = TodoRepository();
    final diaryRepo = DiaryRepository();

    test('1. 本轮新建的文件捕获为 existedBefore=false，恢复时删除', () async {
      vfs.startRecording();
      await vfs.writeFile(
        '/todos/撤回测试/新建待办.md',
        '---\npriority: normal\n---\n本轮新建',
      );
      final entries = vfs.stopRecording();

      final todoEntries = entries.where((e) => e.existedBefore == false).toList();
      expect(todoEntries, isNotEmpty);
      // 新建捕获无法解析出实体 id，保留原路径
      expect(todoEntries.first.path, '/todos/撤回测试/新建待办.md');

      // 恢复语义：删除本轮新建的待办
      await vfs.deleteFile(todoEntries.first.path);
      final all = await todoRepo.getAll();
      expect(all.any((t) => t.title == '新建待办'), isFalse);
    });

    test('2. 同轮多次修改同一路径只保留最旧快照', () async {
      await vfs.writeFile('/todos/撤回测试/多次修改.md', '---\n---\n版本1');
      final all = await todoRepo.getAll();
      final todo = all.where((t) => t.title == '多次修改').first;

      vfs.startRecording();
      await vfs.writeFile('/todos/撤回测试/多次修改.md', '---\nid: "${todo.id}"\n---\n版本2');
      await vfs.editFile('/todos/撤回测试/多次修改.md', '版本2', '版本3');
      final entries = vfs.stopRecording();

      // 标题路径与 id 路径（editFile 内部走 writeFile）都应去重为一条，且是最旧内容
      final todoEntries = entries
          .where((e) => e.path.startsWith('/todos/撤回测试/') && e.path.endsWith('.md'))
          .toList();
      expect(todoEntries.length, 1);
      expect(todoEntries.first.existedBefore, isTrue);
      expect(todoEntries.first.beforeContent, contains('版本1'));
      // 捕获路径规范化为实体 id 键
      expect(todoEntries.first.path, '/todos/撤回测试/${todo.id}.md');
    });

    test('3. 待办删除后按快照写回可复活软删记录', () async {
      final res = await vfs.writeFile(
        '/todos/撤回测试/待删除待办.md',
        '---\npriority: important\n---\n删除我',
      );
      final todoId = res['id'] as String;

      vfs.startRecording();
      await vfs.deleteFile('/todos/撤回测试/$todoId.md');
      final entries = vfs.stopRecording();
      expect(entries.first.existedBefore, isTrue);
      expect(entries.first.path, '/todos/撤回测试/$todoId.md');

      // 已软删除
      var all = await todoRepo.getAll();
      expect(all.any((t) => t.id == todoId), isFalse);

      // 写回快照 → 复活
      await vfs.writeFile(entries.first.path, entries.first.beforeContent!);
      all = await todoRepo.getAll();
      final revived = all.where((t) => t.id == todoId).firstOrNull;
      expect(revived, isNotNull);
      expect(revived!.isDeleted, isFalse);
      expect(revived.description, contains('删除我'));
    });

    test('4. timeline 单条删除的快照归一化到天文件，恢复后记录复活', () async {
      await vfs.writeFile(
        '/timeline/2026-01-10.md',
        '## [09:00] 撤回测试事件\n- 分类: 工作\n- 详情: 待撤回的流水',
      );
      final records = await diaryRepo.getByDate(DateTime(2026, 1, 10));
      final record = records.where((r) => r.title == '撤回测试事件').firstOrNull;
      expect(record, isNotNull);

      vfs.startRecording();
      // 用单条 id 路径删除（模型实际会用的路径形态）
      await vfs.deleteFile('/timeline/${record!.id}.md');
      final entries = vfs.stopRecording();

      // 归一化为天文件快照
      expect(entries.first.path, '/timeline/2026-01-10.md');
      expect(entries.first.existedBefore, isTrue);
      expect(entries.first.beforeContent, contains('撤回测试事件'));

      // 已软删除
      var afterDelete = await diaryRepo.getByDate(DateTime(2026, 1, 10));
      expect(afterDelete.any((r) => r.id == record.id), isFalse);

      // 写回天文件快照 → 记录复活
      await vfs.writeFile(entries.first.path, entries.first.beforeContent!);
      afterDelete = await diaryRepo.getByDate(DateTime(2026, 1, 10));
      final revived = afterDelete.where((r) => r.id == record.id).firstOrNull;
      expect(revived, isNotNull);
      expect(revived!.isDeleted, isFalse);
    });
  });
}
