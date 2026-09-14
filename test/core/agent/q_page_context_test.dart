import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/services/q_page_context.dart';

void main() {
  group('QPageContext.fromLocation 路由推导', () {
    test('五个 tab 页与批量管理页映射正确', () {
      final cases = {
        '/diary': (QContextType.diaryList, 'page:diary'),
        '/diary/batch': (QContextType.diaryList, 'page:diary'),
        '/notes': (QContextType.notesList, 'page:notes'),
        '/todo': (QContextType.todoList, 'page:todo'),
        '/statistics': (QContextType.statistics, 'page:statistics'),
        '/ai': (QContextType.aiPage, 'page:ai'),
      };
      cases.forEach((location, expected) {
        final ctx = QPageContext.fromLocation(location);
        expect(ctx.type, expected.$1, reason: location);
        expect(ctx.signature, expected.$2, reason: location);
      });
    });

    test('设置类页面归入 other 且共享同一签名', () {
      for (final location in [
        '/settings/profile',
        '/settings/ai-config',
        '/settings/data?tab=backup',
      ]) {
        final ctx = QPageContext.fromLocation(location);
        expect(ctx.type, QContextType.other, reason: location);
        expect(ctx.signature, 'page:settings', reason: location);
      }
    });

    test('query 参数不影响列表页识别', () {
      final ctx = QPageContext.fromLocation('/diary?date=2026-09-12');
      expect(ctx.type, QContextType.diaryList);
    });

    test('未知路径走 fallback', () {
      final ctx = QPageContext.fromLocation('/unknown');
      expect(ctx.signature, QPageContext.fallback.signature);
      expect(ctx.type, QContextType.other);
    });
  });

  group('QPageContext.hasFileTarget', () {
    test('详情类上下文携带目标 id 时视为有文件目标', () {
      const note = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        signature: 'note:n1',
        displayLabel: '笔记',
      );
      const journal = QPageContext(
        type: QContextType.journal,
        targetId: '2026-09-12',
        signature: 'journal:2026-09-12',
        displayLabel: '日记',
      );
      expect(note.hasFileTarget, isTrue);
      expect(journal.hasFileTarget, isTrue);
    });

    test('列表类上下文无文件目标', () {
      const list = QPageContext(
        type: QContextType.notesList,
        signature: 'page:notes',
        displayLabel: '笔记库',
      );
      expect(list.hasFileTarget, isFalse);
    });
  });

  group('QPageContext.toPromptBlock 动态上下文', () {
    test('journal 注入确定性天文件路径', () async {
      const ctx = QPageContext(
        type: QContextType.journal,
        targetId: '2026-09-12',
        targetTitle: '2026-09-12',
        signature: 'journal:2026-09-12',
        displayLabel: '每日日记',
      );
      final block = await ctx.toPromptBlock();
      expect(block, isNotNull);
      expect(block, contains('/journal/2026-09-12.md'));
      expect(block, contains('每日日记编辑页'));
      expect(block, contains('read_file'));
    });

    test('列表页注入页面说明但不含文件路径', () async {
      const ctx = QPageContext(
        type: QContextType.todoList,
        signature: 'page:todo',
        displayLabel: '待办',
      );
      final block = await ctx.toPromptBlock();
      expect(block, isNotNull);
      expect(block, contains('待办页'));
      expect(block, isNot(contains('.md')));
    });

    test('other/aiPage 类型无需注入（返回 null）', () async {
      const other = QPageContext(
        type: QContextType.other,
        signature: 'page:settings',
        displayLabel: '设置',
      );
      const ai = QPageContext(
        type: QContextType.aiPage,
        signature: 'page:ai',
        displayLabel: '小Q',
      );
      expect(await other.toPromptBlock(), isNull);
      expect(await ai.toPromptBlock(), isNull);
    });
  });

  group('QPageContext 相等性', () {
    test('同字段值相等（出栈按值匹配依赖此语义）', () {
      const a = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        targetTitle: 'T',
        signature: 'note:n1',
        displayLabel: '笔记《T》',
      );
      final b = QPageContext(
        type: QContextType.noteDetail,
        targetId: 'n1',
        targetTitle: 'T',
        signature: 'note:n1',
        displayLabel: '笔记《T》',
      );
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
    });
  });
}
