import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';

/// 日记列表展示标题（displayTitle）纯逻辑测试。
///
/// 只测静态纯函数，不触碰 JournalService 单例，避免拉起 sqflite。
void main() {
  group('JournalService.displayTitle', () {
    test('标准 yyyy-MM-dd 标题去掉年份前缀，只留 MM-dd', () {
      expect(JournalService.displayTitle('2026-11-12'), '11-12');
      expect(JournalService.displayTitle('2024-01-01'), '01-01');
    });

    test('非标准标题原样返回（历史/异常数据兜底）', () {
      expect(JournalService.displayTitle('随手记'), '随手记');
      expect(JournalService.displayTitle('2026-11'), '2026-11');
      // 月份/日期未补零不符合 yyyy-MM-dd，不裁剪
      expect(JournalService.displayTitle('2026-1-12'), '2026-1-12');
      // 带时间后缀不裁剪
      expect(JournalService.displayTitle('2026-11-12 08:30'), '2026-11-12 08:30');
    });
  });
}
