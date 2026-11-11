import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_token_usage.dart';

/// token 用量解析的回归测试。
///
/// 这里锁的是「不同厂商字段名 → 统一三元组」的映射：一旦映射错位，配置页的
/// 累计卡片会静默显示错的数字，而这类错误在界面上完全看不出来。
void main() {
  group('OpenAI 兼容口径', () {
    test('读取 prompt / completion / total', () {
      final usage = AiTokenUsage.fromResponse({
        'usage': {'prompt_tokens': 120, 'completion_tokens': 80, 'total_tokens': 200},
      });

      expect(usage, isNotNull);
      expect(usage!.promptTokens, 120);
      expect(usage.completionTokens, 80);
      expect(usage.totalTokens, 200);
    });

    test('兼容 input_tokens / output_tokens 写法', () {
      final usage = AiTokenUsage.fromResponse({
        'usage': {'input_tokens': 10, 'output_tokens': 5},
      });

      expect(usage!.promptTokens, 10);
      expect(usage.completionTokens, 5);
      expect(usage.totalTokens, 15, reason: '未上报 total 时用输入+输出兜底');
    });

    test('total 缺省为 0 时同样走兜底', () {
      final usage = AiTokenUsage.fromResponse({
        'usage': {'prompt_tokens': 7, 'completion_tokens': 3, 'total_tokens': 0},
      });

      expect(usage!.totalTokens, 10);
    });

    test('字符串数字也能解析（部分中转把数字写成字符串）', () {
      final usage = AiTokenUsage.fromResponse({
        'usage': {'prompt_tokens': '42', 'completion_tokens': '8'},
      });

      expect(usage!.promptTokens, 42);
      expect(usage.totalTokens, 50);
    });
  });

  group('Gemini 口径', () {
    test('读取 usageMetadata 的 tokenCount 字段', () {
      final usage = AiTokenUsage.fromResponse({
        'usageMetadata': {'promptTokenCount': 300, 'candidatesTokenCount': 120, 'totalTokenCount': 420},
      });

      expect(usage!.promptTokens, 300);
      expect(usage.completionTokens, 120);
      expect(usage.totalTokens, 420);
    });

    test('total 含思考 token 时保留服务端口径', () {
      // Gemini 的 total 会额外包含 thoughts token，比输入+输出大，
      // 此时不能用兜底值把服务端算出来的真实总量抹掉
      final usage = AiTokenUsage.fromResponse({
        'usageMetadata': {'promptTokenCount': 100, 'candidatesTokenCount': 50, 'totalTokenCount': 500},
      });

      expect(usage!.totalTokens, 500);
    });
  });

  group('无用量时返回 null', () {
    test('没有 usage 字段', () {
      expect(AiTokenUsage.fromResponse({'choices': []}), isNull);
    });

    test('usage 全为 0', () {
      expect(
        AiTokenUsage.fromResponse({
          'usage': {'prompt_tokens': 0, 'completion_tokens': 0},
        }),
        isNull,
        reason: '零用量不该写一行统计',
      );
    });

    test('非 Map 输入', () {
      expect(AiTokenUsage.fromResponse('oops'), isNull);
      expect(AiTokenUsage.fromResponse(null), isNull);
    });
  });
}
