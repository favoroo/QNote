import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/agent/vfs/virtual_workspace_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/models/agent_skill.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final registry = SkillRegistry.instance;
  const skillNames = [
    'todo-manager',
    'note-manager',
    'timeline-manager',
    'journal-manager',
    'folder-manager',
    'settings-manager',
    'stats-analyst',
    'frontend-design',
  ];

  group('SkillRegistry 技能手册文档', () {
    test('八个技能均可加载且含 frontmatter', () {
      for (final name in skillNames) {
        final doc = registry.getSkillContent(name);
        expect(doc, isNotNull, reason: '$name 应可加载');
        expect(doc!.startsWith('---'), isTrue, reason: '$name 应以 frontmatter 开头');
        expect(doc.contains('name:'), isTrue, reason: '$name 应含 name 字段');
      }
    });

    test('note-manager 的 grep 示例使用 scope 而非 path', () {
      final doc = registry.getSkillContent('note-manager')!;
      expect(doc.contains('grep(query'), isTrue, reason: '应保留 grep 调用示例');
      expect(doc.contains('scope: "notes"'), isTrue, reason: '示例应使用 scope 参数');
      expect(
        doc.contains('path: "/notes")'),
        isFalse,
        reason: 'grep 工具没有 path 参数，旧错误写法不应存在',
      );
    });

    test('note-manager 覆盖多文件类型与图片插入规范', () {
      final doc = registry.getSkillContent('note-manager')!;
      expect(doc.contains('.html'), isTrue, reason: '应说明非 Markdown 文件支持');
      expect(doc.contains('![image]'), isTrue, reason: '应说明图片插入写法');
    });

    test('journal-manager 含复盘方法论、九宫格与时间线素材指引', () {
      final doc = registry.getSkillContent('journal-manager')!;
      expect(doc.contains('GRAI'), isTrue);
      expect(doc.contains('KPT'), isTrue);
      expect(doc.contains('九宫格'), isTrue);
      expect(doc.contains('/timeline/YYYY-MM-DD.md'), isTrue, reason: '应引导先读时间线取素材');
    });

    test('stats-analyst 含四个评分维度与空数据处理', () {
      final doc = registry.getSkillContent('stats-analyst')!;
      for (final dim in ['sleep', 'diet', 'activity', 'health']) {
        expect(doc.contains(dim), isTrue, reason: '应包含维度 $dim');
      }
      expect(doc.contains('严禁编造'), isTrue, reason: '应含空数据处理禁令');
      expect(doc.contains('weight.json'), isTrue, reason: '应含个性化分析联动');
    });

    test('folder-manager 说明系统默认分类', () {
      final doc = registry.getSkillContent('folder-manager')!;
      expect(doc.contains('今日'), isTrue);
      expect(doc.contains('长期'), isTrue);
      expect(doc.contains('todo_default_'), isTrue);
    });

    test('settings-manager 覆盖 webdav 字段与 shortcuts 写入限制', () {
      final doc = registry.getSkillContent('settings-manager')!;
      expect(doc.contains('server_url'), isTrue, reason: 'webdav 应使用下划线风格字段');
      expect(doc.contains('不会持久化'), isTrue, reason: '应标注 shortcuts fields 写入不生效');
      expect(doc.contains('isTimePoint'), isTrue, reason: 'fixed_events 应含完整字段');
    });

    test('todo-manager 含 GTD 四象限与批量操作指引', () {
      final doc = registry.getSkillContent('todo-manager')!;
      expect(doc.contains('四象限'), isTrue);
      expect(doc.contains('ask_user'), isTrue, reason: '批量删除应要求二次确认');
    });

    test('timeline-manager 保持原有 id 注释关键规范未被破坏', () {
      final doc = registry.getSkillContent('timeline-manager')!;
      expect(doc.contains('<!-- id: xxx -->'), isTrue);
      expect(doc.contains('严禁使用 YAML Frontmatter'), isTrue);
    });

    test('frontend-design 覆盖交付、移动端与反模式关键规范', () {
      final doc = registry.getSkillContent('frontend-design')!;
      expect(
        doc.contains('width=device-width, initial-scale=1.0'),
        isTrue,
        reason: '应强调 viewport 必备',
      );
      expect(
        doc.contains('/notes/<标题>.html'),
        isTrue,
        reason: '应说明单文件 HTML 写入路径',
      );
      expect(
        doc.contains('系统浏览器'),
        isTrue,
        reason: '应说明外链点击会被系统浏览器接管',
      );
      expect(doc.contains('44'), isTrue, reason: '应含触控目标尺寸规范');
      expect(doc.contains('16px'), isTrue, reason: '应含输入框字号规范');
      expect(doc.contains('safe-area'), isTrue, reason: '应含刘海屏安全区适配');
      expect(doc.contains('prefers-reduced-motion'), isTrue, reason: '应含动效降级');
      expect(doc.contains('Inter'), isTrue, reason: '反模式应点名禁用字体');
      expect(doc.contains('紫色渐变'), isTrue, reason: '应含反 AI 味反模式');
    });

    test('frontend-design 支持别名与虚拟路径解析', () {
      for (final key in ['frontend', 'web', 'design', 'ui', '/skills/frontend-design.md']) {
        expect(
          registry.getSkillContent(key),
          registry.getSkillContent('frontend-design'),
          reason: '别名 "$key" 应解析到同一份手册',
        );
      }
    });
  });

  group('SkillRegistry 用户技能（内置 + 用户双层）', () {
    tearDown(() async {
      // 清理测试产生的用户技能，避免污染其他用例
      final skills = await ConfigRepository.instance.getUserSkills();
      for (final s in skills) {
        await ConfigRepository.instance.deleteUserSkill(s.name);
      }
      await registry.reload();
    });

    test('保存后进入清单与内容查询，来源标记为 user', () async {
      await registry.saveUserSkill(
        AgentSkill(
          name: 'invest-review',
          description: '投资复盘技能：持仓记录、盈亏归因与月度复盘',
          content: '# 投资复盘技能\n\n## 1. 复盘流程',
        ),
      );

      final inList = registry.listSkills().firstWhere(
            (s) => s['name'] == 'invest-review',
          );
      expect(inList['origin'], AgentSkillOrigin.user);
      expect(inList['path'], '/skills/invest-review.md');

      // 读取输出合成 frontmatter，与内置技能格式一致
      final content = registry.getSkillContent('invest-review');
      expect(content, contains('name: invest-review'));
      expect(content, contains('## 1. 复盘流程'));

      await registry.deleteUserSkill('invest-review');
      expect(registry.getUserSkill('invest-review'), isNull);
      expect(registry.getSkillContent('invest-review'), isNull);
    });

    test('持久化到 app_configs 并可重载恢复', () async {
      await registry.saveUserSkill(
        AgentSkill(
          name: 'reading-notes',
          description: '读书笔记技能',
          content: '# 读书笔记',
        ),
      );
      final stored = await ConfigRepository.instance.getUserSkills();
      expect(stored.any((s) => s.name == 'reading-notes'), isTrue);

      // 强制重载后缓存仍包含（模拟下次会话/云同步导入后的加载）
      await registry.reload();
      expect(registry.getUserSkill('reading-notes'), isNotNull);
      await registry.deleteUserSkill('reading-notes');
    });

    test('内置名与别名占用、非法名均被拒绝', () async {
      // 内置主名
      expect(
        () => registry.saveUserSkill(
          AgentSkill(name: 'todo-manager', content: 'x'),
        ),
        throwsException,
      );
      // 内置别名（模糊匹配名同样保留）
      expect(
        () => registry.saveUserSkill(
          AgentSkill(name: 'stats', content: 'x'),
        ),
        throwsException,
      );
      // 非法名（含空白 / 路径分隔符）
      expect(
        () => registry.saveUserSkill(
          AgentSkill(name: 'my skill', content: 'x'),
        ),
        throwsException,
      );
      expect(
        () => registry.saveUserSkill(
          AgentSkill(name: 'a/b', content: 'x'),
        ),
        throwsException,
      );
      // 删除内置技能直接拒绝
      expect(
        () => registry.deleteUserSkill('note-manager'),
        throwsException,
      );
    });
  });

  group('VFS /skills/ 用户技能读写', () {
    final vfs = VirtualWorkspaceService.instance;

    tearDown(() async {
      final skills = await ConfigRepository.instance.getUserSkills();
      for (final s in skills) {
        await ConfigRepository.instance.deleteUserSkill(s.name);
      }
      await registry.reload();
    });

    test('write_file 创建/更新自定义技能，清单与读取自动包含', () async {
      final res = await vfs.writeFile(
        '/skills/morning-routine.md',
        '---\nname: morning-routine\ndescription: 晨间例行流程技能\n---\n\n# 晨间例行流程\n\n## 1. 步骤',
      );
      expect(res['status'], 'created');
      expect(registry.getUserSkill('morning-routine'), isNotNull);

      final readBack = await vfs.readFile('/skills/morning-routine.md');
      expect(readBack, contains('晨间例行流程'));

      // 二次写入为更新
      final res2 = await vfs.writeFile(
        '/skills/morning-routine.md',
        '---\ndescription: 更新后的描述\n---\n\n# 晨间例行流程 v2',
      );
      expect(res2['status'], 'updated');
      expect(
        registry.getUserSkill('morning-routine')!.description,
        '更新后的描述',
      );

      // 目录列举自动包含用户技能
      expect(await vfs.listDir('/skills'), contains('morning-routine.md'));

      await vfs.deleteFile('/skills/morning-routine.md');
      expect(registry.getUserSkill('morning-routine'), isNull);
    });

    test('无 frontmatter 写入时从正文提取描述，纯标题正文取标题文本', () async {
      await vfs.writeFile(
        '/skills/no-meta-skill.md',
        '# 无元数据技能\n\n这是第一个普通段落，作为描述回退来源。',
      );
      final skill = registry.getUserSkill('no-meta-skill')!;
      expect(skill.description, contains('这是第一个普通段落'));
      await vfs.deleteFile('/skills/no-meta-skill.md');

      // 正文只有标题时，描述回退为标题文本
      await vfs.writeFile('/skills/title-only-skill.md', '# 只有标题');
      final titleOnly = registry.getUserSkill('title-only-skill')!;
      expect(titleOnly.description, '只有标题');
      await vfs.deleteFile('/skills/title-only-skill.md');
    });

    test('内置技能写入与删除均被拒绝，内容不受影响', () async {
      expect(
        () => vfs.writeFile('/skills/todo-manager.md', '# 覆盖内置技能'),
        throwsException,
      );
      expect(
        () => vfs.deleteFile('/skills/todo-manager.md'),
        throwsException,
      );
      expect(registry.getSkillContent('todo-manager'), isNotNull);
    });
  });
}
