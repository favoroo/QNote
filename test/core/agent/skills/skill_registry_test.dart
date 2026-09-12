import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';

void main() {
  final registry = SkillRegistry.instance;
  const skillNames = [
    'todo-manager',
    'note-manager',
    'timeline-manager',
    'journal-manager',
    'folder-manager',
    'settings-manager',
    'stats-analyst',
  ];

  group('SkillRegistry 技能手册文档', () {
    test('七个技能均可加载且含 frontmatter', () {
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
  });
}
