import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/config/defaults.dart';

/// 内置提示词模板护栏测试
///
/// 防止后续编辑重新引入未替换占位符、非法 JSON 示例注释、以及诱导模型编造时间的示例。
void main() {
  group('defaultSystemPrompts', () {
    test('daily_score_system 不含未替换占位符且 JSON 示例可标准解析', () {
      final prompt = defaultSystemPrompts['daily_score_system']!;
      expect(prompt, isNot(contains('{{')));

      final jsonStart = prompt.indexOf('{');
      final jsonEnd = prompt.lastIndexOf('}');
      expect(jsonStart, greaterThanOrEqualTo(0));
      expect(jsonEnd, greaterThan(jsonStart));

      final sampleJson = prompt.substring(jsonStart, jsonEnd + 1);
      final decoded = jsonDecode(sampleJson) as Map<String, dynamic>;
      expect(decoded['canScore'], isTrue);
      expect(decoded['dimensionScores'], isA<Map<String, dynamic>>());
    });

    test('unified_extraction 明确以 recordDate 为基准且示例不凭空编造时间或空 health 标签', () {
      final prompt = defaultSystemPrompts['unified_extraction']!;
      expect(prompt, contains('recordDate'));
      expect(prompt, contains('严禁编造时间'));
      // 必须包含占位符以便 AiService 按是否含图片动态裁剪提示词
      expect(prompt, contains('{{imageRules}}'));
      expect(prompt, contains('{{outputFormat}}'));
      expect(prompt, contains('{{imageExamples}}'));
      // 曾经诱导模型瞎猜时间的坏示例不能回归
      expect(prompt, isNot(contains('"time":"18:00"')));
      expect(prompt, isNot(contains('"time":"20:00"')));
    });
  });
}
