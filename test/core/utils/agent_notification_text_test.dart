import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/agent_notification_text.dart';

void main() {
  group('agentNotificationSummary', () {
    test('压平换行与多余空白', () {
      expect(agentNotificationSummary('整理今天的\n\n日记  和待办'), '整理今天的 日记 和待办');
    });

    test('去掉 Markdown 标题/列表/强调/代码标记', () {
      expect(agentNotificationSummary('## 标题\n\n- **重点** `code` 内容'), '标题 重点 code 内容');
    });

    test('超长按上限截断并加省略号', () {
      final long = '一' * 100;
      final out = agentNotificationSummary(long);
      expect(out.endsWith('…'), isTrue);
      expect(out.length, kAgentNotificationTextMaxLength + 1);
    });

    test('不截断半个代理对（emoji）', () {
      // 33 个占位字符 + 一个 emoji（2 个 UTF-16 单元），截断点恰好落在 emoji 中间
      final raw = 'a' * 35 + '😀';
      final out = agentNotificationSummary(raw);
      expect(out.endsWith('…'), isTrue);
      // 绝不能留孤立代理单元（渲染成乱码方框）
      expect(out.codeUnits.any((c) => c >= 0xD800 && c <= 0xDFFF), isFalse);
    });

    test('空文本回退默认文案', () {
      expect(agentNotificationSummary('   \n  '), '小Q 任务');
      expect(agentNotificationSummary(null), '小Q 任务');
      expect(agentNotificationSummary('', fallback: '兜底'), '兜底');
    });
  });
}
