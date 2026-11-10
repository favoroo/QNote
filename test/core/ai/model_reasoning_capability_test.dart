import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/model_reasoning_capability.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 思考强度能力表的回归测试
///
/// 这张表决定「界面给不给入口」与「请求带什么字段」，改错任何一格都会让
/// 用户选的档位静默失效或把请求打挂，因此逐厂商锁定参数形态。
void main() {
  ModelReasoningCapability capabilityOf(
    String modelName, {
    String providerType = 'openai',
    String? vendorId,
  }) {
    final capability = ModelReasoningCapability.resolve(
      modelName: modelName,
      providerType: providerType,
      vendorId: vendorId,
    );
    expect(capability, isNotNull, reason: '$modelName 应命中能力表');
    return capability!;
  }

  group('OpenAI 系 reasoning_effort', () {
    test('gpt-5 默认四档，none 写 minimal', () {
      final capability = capabilityOf('gpt-5.4-mini');
      expect(capability.levels, [
        ReasoningEffort.none,
        ReasoningEffort.low,
        ReasoningEffort.medium,
        ReasoningEffort.high,
      ]);

      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.none);
      expect(body['reasoning_effort'], 'minimal');
    });

    test('自定义勾选的 minimal/xhigh/max 会真实发出去', () {
      final capability = capabilityOf('gpt-5.4-mini').withLevels([
        ReasoningEffort.minimal,
        ReasoningEffort.xhigh,
        ReasoningEffort.max,
      ]);
      expect(capability.levels, [
        ReasoningEffort.minimal,
        ReasoningEffort.xhigh,
        ReasoningEffort.max,
      ]);

      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.xhigh);
      expect(body['reasoning_effort'], 'xhigh');

      final maxBody = <String, dynamic>{};
      capability.applyToOpenAiBody(maxBody, ReasoningEffort.max);
      expect(maxBody['reasoning_effort'], 'max');
    });

    test('自定义档位不在参数形态候选里时被过滤', () {
      // 二值开关表达不了中间档，不能给用户假精度
      final binary = capabilityOf('glm-4.6').withLevels([
        ReasoningEffort.none,
        ReasoningEffort.low,
        ReasoningEffort.high,
      ]);
      expect(binary.levels, [
        ReasoningEffort.none,
        ReasoningEffort.high,
      ]);
      expect(binary.configurableLevels, [
        ReasoningEffort.none,
        ReasoningEffort.high,
      ]);
    });

    test('o 系没有 none 档，选了也不发字段', () {
      final capability = capabilityOf('o3-mini');
      expect(capability.levels, [
        ReasoningEffort.low,
        ReasoningEffort.medium,
        ReasoningEffort.high,
      ]);

      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.none);
      expect(body, isEmpty);
    });

    test('gpt-5-chat 是对话模型，不提供入口', () {
      expect(
        ModelReasoningCapability.resolve(modelName: 'gpt-5-chat-latest'),
        isNull,
      );
    });

    test('未知模型不猜字段', () {
      expect(
        ModelReasoningCapability.resolve(modelName: 'my-custom-model'),
        isNull,
      );
    });
  });

  group('智谱 GLM 二值开关', () {
    test('只提供关闭/开启两档，文案为开关', () {
      final capability = capabilityOf('glm-4.6');
      expect(capability.levels, [ReasoningEffort.none, ReasoningEffort.high]);
      expect(capability.labelFor(null), '自动');
      expect(capability.labelFor(ReasoningEffort.none), '关闭');
      expect(capability.labelFor(ReasoningEffort.high), '开启');
    });

    test('写 thinking.type 而不是 reasoning_effort', () {
      final capability = capabilityOf('glm-4.6');
      final enabled = <String, dynamic>{};
      capability.applyToOpenAiBody(enabled, ReasoningEffort.high);
      expect(enabled, {
        'thinking': {'type': 'enabled'},
      });

      final disabled = <String, dynamic>{};
      capability.applyToOpenAiBody(disabled, ReasoningEffort.none);
      expect(disabled, {
        'thinking': {'type': 'disabled'},
      });
    });

    test('中间档位不受支持时静默跳过', () {
      final capability = capabilityOf('glm-4.5');
      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.medium);
      expect(body, isEmpty);
    });
  });

  group('通义千问思考预算', () {
    test('开启时同时写 enable_thinking 与 thinking_budget', () {
      final capability = capabilityOf('qwen3-235b-a22b');
      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.high);
      expect(body['enable_thinking'], isTrue);
      expect(body['thinking_budget'], 16384);
    });

    test('关闭时不写预算', () {
      final capability = capabilityOf('qwen-plus');
      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.none);
      expect(body['enable_thinking'], isFalse);
      expect(body.containsKey('thinking_budget'), isFalse);
    });
  });

  group('OpenRouter 统一协议', () {
    test('写 reasoning.effort', () {
      final capability = capabilityOf(
        'anthropic/claude-sonnet-4',
        vendorId: 'openrouter',
      );
      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.medium);
      expect(body, {
        'reasoning': {'effort': 'medium'},
      });
    });

    test('不在名单里的模型不提供入口', () {
      expect(
        ModelReasoningCapability.resolve(
          modelName: 'meta-llama/llama-4',
          vendorId: 'openrouter',
        ),
        isNull,
      );
    });
  });

  group('Gemini 原生 thinkingConfig', () {
    test('Gemini 3 只提供低/高，写 thinkingLevel', () {
      final capability = capabilityOf(
        'gemini-3-flash-preview',
        providerType: 'gemini',
      );
      expect(capability.levels, [ReasoningEffort.low, ReasoningEffort.high]);

      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.high);
      expect(body, isEmpty, reason: 'Gemini 参数挂在 generationConfig 下');

      expect(capability.geminiThinkingConfig(ReasoningEffort.high), {
        'thinkingLevel': 'high',
      });
    });

    test('Gemini 2.5 Pro 不允许关闭思考', () {
      final capability = capabilityOf('gemini-2.5-pro', providerType: 'gemini');
      expect(capability.supports(ReasoningEffort.none), isFalse);
      expect(capability.geminiThinkingConfig(ReasoningEffort.none), isNull);
      expect(capability.geminiThinkingConfig(ReasoningEffort.medium), {
        'thinkingBudget': 4096,
      });
    });

    test('Gemini 2.5 Flash 支持关闭（budget=0）', () {
      final capability = capabilityOf(
        'gemini-2.5-flash',
        providerType: 'gemini',
      );
      expect(capability.geminiThinkingConfig(ReasoningEffort.none), {
        'thinkingBudget': 0,
      });
    });

    test('OpenAI 兼容模型不会拿到 Gemini 配置', () {
      final capability = capabilityOf('gpt-5');
      expect(capability.geminiThinkingConfig(ReasoningEffort.high), isNull);
    });
  });

  test('空模型名返回 null', () {
    expect(ModelReasoningCapability.resolve(modelName: '   '), isNull);
  });

  group('未收录模型的通用兜底（界面入口永远可见）', () {
    test('OpenAI 兼容给全档位，none 写 minimal', () {
      final capability = ModelReasoningCapability.forUi(
        modelName: 'my-custom-model',
      );
      expect(capability.isGeneric, isTrue);
      expect(capability.levels, [
        ReasoningEffort.none,
        ReasoningEffort.low,
        ReasoningEffort.medium,
        ReasoningEffort.high,
      ]);

      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.medium);
      expect(body['reasoning_effort'], 'medium');

      final off = <String, dynamic>{};
      capability.applyToOpenAiBody(off, ReasoningEffort.none);
      expect(off['reasoning_effort'], 'minimal');
    });

    test('OpenRouter 兜底写 reasoning.effort 而不是顶层字段', () {
      final capability = ModelReasoningCapability.forUi(
        modelName: 'meta-llama/llama-4',
        vendorId: 'openrouter',
      );
      expect(capability.isGeneric, isTrue);

      final body = <String, dynamic>{};
      capability.applyToOpenAiBody(body, ReasoningEffort.low);
      expect(body, {
        'reasoning': {'effort': 'low'},
      });
    });

    test('Gemini 兜底写 thinkingBudget', () {
      final capability = ModelReasoningCapability.forUi(
        modelName: 'gemini-unknown-preview',
        providerType: 'gemini',
      );
      expect(capability.geminiThinkingConfig(ReasoningEffort.high), {
        'thinkingBudget': 16384,
      });
    });

    test('已收录模型仍走精确能力，不被兜底覆盖', () {
      final capability = ModelReasoningCapability.forUi(modelName: 'glm-4.6');
      expect(capability.isGeneric, isFalse);
      expect(capability.levels, [ReasoningEffort.none, ReasoningEffort.high]);
    });
  });
}
