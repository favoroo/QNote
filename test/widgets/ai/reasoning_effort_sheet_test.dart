import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';
import 'package:qnote_flutter/widgets/ai/reasoning_effort_sheet.dart';

/// 思考强度弹层的选项来源：首项固定「自动」，能力表未命中时整体隐藏
void main() {
  test('OpenAI 全档位：自动 + 四档', () {
    final options = reasoningEffortOptions(
      modelName: 'gpt-5.4-mini',
      providerType: 'openai',
    );

    expect(options, hasLength(5));
    expect(options.first.effort, isNull);
    expect(options.first.label, '自动');
    expect(options.skip(1).map((o) => o.effort), ReasoningEffort.values);
  });

  test('GLM 二值开关文案', () {
    final options = reasoningEffortOptions(
      modelName: 'glm-4.6',
      providerType: 'openai',
      vendorId: 'zhipu',
    );

    expect(options.map((o) => o.label), ['自动', '关闭', '开启']);
    expect(options.map((o) => o.effort), [
      null,
      ReasoningEffort.none,
      ReasoningEffort.high,
    ]);
  });

  test('未收录模型返回空列表（调用方据此隐藏入口）', () {
    expect(
      reasoningEffortOptions(
        modelName: 'my-custom-model',
        providerType: 'openai',
      ),
      isEmpty,
    );
  });
}
