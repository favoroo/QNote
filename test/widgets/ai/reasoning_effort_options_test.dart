import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';
import 'package:qnote_flutter/widgets/ai/reasoning_effort_options.dart';

/// 对话面板的档位来源：首项固定「自动」，能力表未命中时用通用兜底
void main() {
  test('OpenAI 默认四档', () {
    final options = reasoningEffortOptions(modelName: 'gpt-5.4-mini', providerType: 'openai');

    expect(options, hasLength(5));
    expect(options.first.effort, isNull);
    expect(options.first.label, '自动');
    expect(options.skip(1).map((o) => o.effort), [
      ReasoningEffort.none,
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
    ]);
  });

  test('GLM 默认也有低/中/高，不再只剩开启/关闭', () {
    final options = reasoningEffortOptions(modelName: 'glm-4.6', providerType: 'openai', vendorId: 'zhipu');

    expect(options.map((o) => o.label), ['自动', '关闭', '低', '中', '高']);
    expect(options.map((o) => o.effort), [
      null,
      ReasoningEffort.none,
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
    ]);
  });

  test('未收录模型给通用兜底档位，入口不隐藏', () {
    final options = reasoningEffortOptions(modelName: 'my-custom-model', providerType: 'openai');

    // 「关闭」也要可选：时间线提取默认关闭思考，缺了该档位用户会以为设置没生效
    expect(options.map((o) => o.label), ['自动', '关闭', '低', '中', '高']);
  });

  test('自定义档位覆盖自动识别', () {
    final options = reasoningEffortOptions(
      modelName: 'gpt-5.4-mini',
      providerType: 'openai',
      customLevels: [ReasoningEffort.minimal, ReasoningEffort.xhigh],
    );

    expect(options.map((o) => o.label), ['自动', '最少', '极高']);
    expect(options.map((o) => o.effort), [null, ReasoningEffort.minimal, ReasoningEffort.xhigh]);
  });

  test('二值模型的中间档不再被过滤', () {
    final options = reasoningEffortOptions(
      modelName: 'glm-4.6',
      providerType: 'openai',
      vendorId: 'zhipu',
      customLevels: [ReasoningEffort.none, ReasoningEffort.low, ReasoningEffort.medium, ReasoningEffort.high],
    );

    expect(options.map((o) => o.label), ['自动', '关闭', '低', '中', '高']);
  });
}
