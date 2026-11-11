import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/providers/drawer_nav_provider.dart';

void main() {
  group('DrawerNavMemory', () {
    test('初始状态没有可恢复入口', () {
      final memory = DrawerNavMemory();
      expect(memory.entryId, isNull);
      expect(memory.resumableEntryId(), isNull);
    });

    test('关闭后立刻重开，恢复上次停留的入口', () {
      final closedAt = DateTime(2026, 11, 8, 10, 0);
      final memory = DrawerNavMemory()..recordClosed(entryId: 'ai-config', now: closedAt);

      expect(memory.resumableEntryId(now: closedAt), 'ai-config');
      expect(memory.resumableEntryId(now: closedAt.add(const Duration(seconds: 59))), 'ai-config');
    });

    test('超过时间窗口就不再恢复', () {
      final closedAt = DateTime(2026, 11, 8, 10, 0);
      final memory = DrawerNavMemory()..recordClosed(entryId: 'ai-config', now: closedAt);

      expect(memory.resumableEntryId(now: closedAt.add(const Duration(minutes: 1, seconds: 1))), isNull);
    });

    test('窗口边界（正好 1 分钟）仍然恢复', () {
      final closedAt = DateTime(2026, 11, 8, 10, 0);
      final memory = DrawerNavMemory()..recordClosed(entryId: 'about', now: closedAt);

      expect(memory.resumableEntryId(now: closedAt.add(kDrawerResumeWindow)), 'about');
    });

    test('停在一级菜单时关闭，下次打开不恢复任何入口', () {
      final closedAt = DateTime(2026, 11, 8, 10, 0);
      final memory = DrawerNavMemory()..recordClosed(entryId: null, now: closedAt);

      expect(memory.resumableEntryId(now: closedAt), isNull);
    });

    test('过期记录会被下一次关闭覆盖，不会反复复活旧入口', () {
      final firstClose = DateTime(2026, 11, 8, 10, 0);
      final memory = DrawerNavMemory()..recordClosed(entryId: 'ai-config', now: firstClose);

      // 隔了很久重开只看到菜单，用户随即再次关闭
      final secondClose = firstClose.add(const Duration(minutes: 10));
      expect(memory.resumableEntryId(now: secondClose), isNull);
      memory.recordClosed(entryId: null, now: secondClose);

      expect(memory.resumableEntryId(now: secondClose.add(const Duration(seconds: 5))), isNull);
    });

    test('记住的入口与关闭时间一起被替换，不会残留旧时间戳', () {
      final memory = DrawerNavMemory()
        ..recordClosed(entryId: 'about', now: DateTime(2026, 11, 8, 10, 0))
        ..recordClosed(entryId: 'data', now: DateTime(2026, 11, 8, 10, 0, 30));

      expect(memory.entryId, 'data');
      expect(memory.closedAt, DateTime(2026, 11, 8, 10, 0, 30));
    });
  });
}
