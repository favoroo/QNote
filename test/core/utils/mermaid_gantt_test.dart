import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/mermaid_gantt.dart';

void main() {
  group('parseMermaidGantt', () {
    test('解析标题、分组、状态、持续时间与 after 依赖', () {
      final plan = parseMermaidGantt('''
gantt
    title 项目排期
    dateFormat YYYY-MM-DD
    axisFormat %m-%d
    section 设计
    需求梳理 :done, a1, 2026-11-02, 5d
    原型设计 :active, a2, after a1, 4d
    section 开发
    前端开发 :a3, after a2, 8d
    上线 :milestone, m1, after a3, 0d
''');
      expect(plan, isNotNull);
      expect(plan!.title, '项目排期');
      expect(plan.sections.map((s) => s.name).toList(), ['设计', '开发']);
      expect(plan.taskCount, 4);

      final a1 = plan.taskById['a1']!;
      expect(a1.status, GanttTaskStatus.done);
      expect(a1.start, DateTime(2026, 11, 2));
      expect(a1.end, DateTime(2026, 11, 7));

      final a2 = plan.taskById['a2']!;
      expect(a2.status, GanttTaskStatus.active);
      expect(a2.start, a1.end);
      expect(a2.end, DateTime(2026, 11, 11));

      final a3 = plan.taskById['a3']!;
      expect(a3.status, GanttTaskStatus.normal);
      expect(a3.start, a2.end);

      final milestone = plan.taskById['m1']!;
      expect(milestone.milestone, isTrue);
      expect(milestone.start, milestone.end);
      expect(milestone.start, a3.end);

      // 范围向两侧各留一天
      expect(plan.rangeStart, DateTime(2026, 11, 1));
      expect(plan.rangeEnd, DateTime(2026, 11, 20));
    });

    test('显式结束日期按包含当天换算成排他终点', () {
      final plan = parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    task 写文档 :t1, 2026-01-01, 2026-01-03
''');
      expect(plan, isNotNull);
      final task = plan!.taskById['t1']!;
      expect(task.start, DateTime(2026, 1, 1));
      expect(task.end, DateTime(2026, 1, 4));
      expect(task.durationDays, 3);
    });

    test('支持周/小时单位与斜杠日期格式', () {
      final plan = parseMermaidGantt('''
gantt
    dateFormat YYYY/MM/DD
    section 工作
    双周任务 :t1, 2026/01/01, 2w
    短任务 :t2, 2026/01/10, 6h
''');
      expect(plan, isNotNull);
      expect(plan!.taskById['t1']!.end, DateTime(2026, 1, 15));
      expect(plan.taskById['t2']!.duration.inHours, 6);
    });

    test('没有 section 的任务归入默认分组', () {
      final plan = parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    独立任务 :t1, 2026-01-01, 2d
''');
      expect(plan, isNotNull);
      expect(plan!.sections.single.name, '任务');
    });

    test('跳过 YAML frontmatter 与注释', () {
      final plan = parseMermaidGantt('''
---
config:
  theme: base
---
%% 这是注释
gantt
    dateFormat YYYY-MM-DD
    任务 :t1, 2026-01-01, 2d
''');
      expect(plan, isNotNull);
      expect(plan!.taskCount, 1);
    });

    test('非 gantt 源码返回 null', () {
      expect(parseMermaidGantt('flowchart TD\n  A --> B'), isNull);
      expect(parseMermaidGantt(''), isNull);
      expect(parseMermaidGantt('gantt'), isNull);
    });

    test('未知 after 引用返回 null', () {
      expect(
        parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    任务 :t1, after missing, 2d
'''),
        isNull,
      );
    });

    test('循环依赖返回 null', () {
      expect(
        parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    任务A :a, after b, 1d
    任务B :b, after a, 1d
'''),
        isNull,
      );
    });

    test('重复 id 返回 null', () {
      expect(
        parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    任务A :dup, 2026-01-01, 1d
    任务B :dup, 2026-01-02, 1d
'''),
        isNull,
      );
    });

    test('不支持的语义配置返回 null，交给 Mermaid 通用渲染', () {
      expect(
        parseMermaidGantt('''
gantt
    dateFormat DD-MM-YYYY
    任务 :t1, 01-01-2026, 2d
'''),
        isNull,
      );
      expect(
        parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    excludes weekends
    任务 :t1, 2026-01-01, 2d
'''),
        isNull,
      );
      expect(
        parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    inclusiveEndDates
    任务 :t1, 2026-01-01, 2026-01-03
'''),
        isNull,
      );
    });

    test('非法日期返回 null', () {
      expect(
        parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    任务 :t1, 2026-02-30, 2d
'''),
        isNull,
      );
    });

    test('里程碑显式结束日期不产生工期', () {
      final plan = parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    上线 :milestone, m1, 2026-11-19, 2026-11-19
''');
      expect(plan, isNotNull);
      final task = plan!.taskById['m1']!;
      expect(task.milestone, isTrue);
      expect(task.start, task.end);
      expect(task.duration, Duration.zero);
    });

    test('极短计划也至少覆盖 3 天，便于时间轴阅读', () {
      final plan = parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    上线 :milestone, m1, 2026-11-19, 0d
''');
      expect(plan, isNotNull);
      expect(plan!.daySpan, greaterThanOrEqualTo(3));
    });

    test('containsDate 按自然日判断范围', () {
      final plan = parseMermaidGantt('''
gantt
    dateFormat YYYY-MM-DD
    任务 :t1, 2026-01-01, 2d
''')!;
      expect(plan.containsDate(DateTime(2026, 1, 1, 23, 59)), isTrue);
      expect(plan.containsDate(DateTime(2026, 1, 5)), isFalse);
    });
  });
}
