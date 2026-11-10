import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 角色级思考强度默认值：时间线提取固定不思考
///
/// 提取是结构化抽取，思考只会把单次提取拖长；这里的回归测试锁定
/// 「时间线角色覆盖模型级档位」与「不支持关闭的模型退到最低档」两件事。
void main() {
  AiConfig config(
    String modelName, {
    String provider = 'openai',
    ReasoningEffort? effort,
    List<ReasoningEffort>? efforts,
  }) {
    return AiConfig(
      providerId: 'provider-1',
      name: 'demo',
      provider: provider,
      modelName: modelName,
      apiKey: 'sk-test-00000000',
      baseUrl: 'https://gw.example.com/v1',
      reasoningEffort: effort,
      reasoningEfforts: efforts,
    );
  }

  test('时间线提取未设档位时默认关闭', () {
    final result = applyRoleReasoningDefault(
      'timelineOptimization',
      config('my-custom-model'),
    );

    expect(result.reasoningEffort, ReasoningEffort.none);
  });

  test('时间线提取覆盖模型级的显式档位', () {
    // 同一个模型可能还被小Q 对话使用，模型级设了高也不该拖慢提取
    final result = applyRoleReasoningDefault(
      'timelineOptimization',
      config('my-custom-model', effort: ReasoningEffort.high),
    );

    expect(result.reasoningEffort, ReasoningEffort.none);
  });

  test('不支持关闭的模型退到最低档', () {
    final oSeries = applyRoleReasoningDefault(
      'timelineOptimization',
      config('o3-mini'),
    );
    expect(oSeries.reasoningEffort, ReasoningEffort.low);

    final geminiPro = applyRoleReasoningDefault(
      'timelineOptimization',
      config('gemini-2.5-pro', provider: 'gemini'),
    );
    expect(geminiPro.reasoningEffort, ReasoningEffort.low);
  });

  test('自定义档位裁掉关闭与低档时，退到该模型可选的最低档', () {
    final result = applyRoleReasoningDefault(
      'timelineOptimization',
      config(
        'gpt-5.4-mini',
        effort: ReasoningEffort.high,
        efforts: [ReasoningEffort.minimal, ReasoningEffort.xhigh],
      ),
    );

    expect(result.reasoningEffort, ReasoningEffort.minimal);
  });

  test('其它角色不受影响', () {
    expect(
      applyRoleReasoningDefault(
        'assistant',
        config('my-custom-model'),
      ).reasoningEffort,
      isNull,
    );
    expect(
      applyRoleReasoningDefault(
        'assistant',
        config('my-custom-model', effort: ReasoningEffort.high),
      ).reasoningEffort,
      ReasoningEffort.high,
    );
    expect(
      applyRoleReasoningDefault(
        'imageGeneration',
        config('my-custom-model', effort: ReasoningEffort.medium),
      ).reasoningEffort,
      ReasoningEffort.medium,
    );
  });
}
