import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 请求体里「思考强度」的参数形态
///
/// 各家 OpenAI 兼容端点对同一个语义用了不同字段：OpenAI 是 `reasoning_effort`，
/// 智谱是 `thinking.type`，通义是 `enable_thinking + thinking_budget`，
/// Gemini 原生则挂在 `generationConfig.thinkingConfig` 下。
enum _ReasoningParamStyle {
  /// OpenAI 系：`reasoning_effort: minimal|low|medium|high`
  openAiEffort,

  /// 智谱 GLM 系：`thinking: {type: enabled|disabled}`（只有开关两档）
  thinkingToggle,

  /// 通义千问系：`enable_thinking` + `thinking_budget`
  qwenThinking,

  /// OpenRouter 统一协议：`reasoning: {effort}`
  openRouterReasoning,

  /// Gemini 3：`thinkingConfig.thinkingLevel`
  geminiThinkingLevel,

  /// Gemini 2.5：`thinkingConfig.thinkingBudget`
  geminiThinkingBudget,
}

/// 单个模型的「思考强度」能力：支持哪些档位、参数写到哪里
///
/// 能力表只收录**参数形态已确认**的模型族；未收录的模型 [resolve] 返回 null，
/// 界面不展示入口、发信也不带任何思考参数——宁可不给，也不猜错字段把请求打挂。
class ModelReasoningCapability {
  /// 由弱到强支持的档位；「自动」不在列表里，由 null 表达
  final List<ReasoningEffort> levels;

  final _ReasoningParamStyle _style;

  /// 二值开关模型（目前是 GLM）：high 档在界面上显示为「开启」
  final bool _binary;

  const ModelReasoningCapability._(
    this.levels,
    this._style, {
    bool binary = false,
    this.isGeneric = false,
  }) : _binary = binary;

  /// 是否为「能力表未收录」的通用兜底
  ///
  /// 未收录模型也给出入口（对齐 ZCode：用户总能自己调），但按协议族最常见的
  /// 字段发送；网关不认时由 AiService 的 400 降级重发兜住，不会把对话打死。
  final bool isGeneric;

  /// 该档位是否受支持（切换模型后旧选择可能失效，调用方据此回落到「自动」）
  bool supports(ReasoningEffort effort) => levels.contains(effort);

  /// 档位展示名；null 表示「自动」
  String labelFor(ReasoningEffort? effort) {
    if (effort == null) {
      return '自动';
    }
    if (_binary && effort == ReasoningEffort.high) {
      return '开启';
    }
    return effort.label;
  }

  /// 解析模型能力；null 表示该模型不支持配置思考强度
  ///
  /// 匹配顺序即协议优先级：原生 Gemini > OpenRouter > 各厂商 OpenAI 兼容字段。
  static ModelReasoningCapability? resolve({
    required String modelName,
    String providerType = 'openai',
    String? vendorId,
  }) {
    final name = modelName.trim().toLowerCase();
    if (name.isEmpty) {
      return null;
    }

    // 1. 原生 Gemini：思考参数在 generationConfig.thinkingConfig 下
    if (providerType == 'gemini') {
      if (_gemini3.hasMatch(name)) {
        return const ModelReasoningCapability._([
          ReasoningEffort.low,
          ReasoningEffort.high,
        ], _ReasoningParamStyle.geminiThinkingLevel);
      }
      if (_gemini25Pro.hasMatch(name)) {
        // Gemini 2.5 Pro 不允许关闭思考（budget=0 会 400）
        return const ModelReasoningCapability._([
          ReasoningEffort.low,
          ReasoningEffort.medium,
          ReasoningEffort.high,
        ], _ReasoningParamStyle.geminiThinkingBudget);
      }
      if (_gemini25Flash.hasMatch(name)) {
        return const ModelReasoningCapability._(
          ReasoningEffort.values,
          _ReasoningParamStyle.geminiThinkingBudget,
        );
      }
      return null;
    }

    // 2. OpenRouter：统一 reasoning.effort，不跟随各厂商私有字段
    if (vendorId == 'openrouter') {
      return _openRouterReasoningModels.hasMatch(name)
          ? const ModelReasoningCapability._([
              ReasoningEffort.low,
              ReasoningEffort.medium,
              ReasoningEffort.high,
            ], _ReasoningParamStyle.openRouterReasoning)
          : null;
    }

    // 3. OpenAI 兼容协议：各家把「思考」塞进不同顶层字段
    // gpt-5-chat 是非推理对话模型，不接受 reasoning_effort
    if (_gpt5Chat.hasMatch(name)) {
      return null;
    }
    if (_gpt5.hasMatch(name)) {
      return const ModelReasoningCapability._(
        ReasoningEffort.values,
        _ReasoningParamStyle.openAiEffort,
      );
    }
    if (_oSeries.hasMatch(name)) {
      return const ModelReasoningCapability._([
        ReasoningEffort.low,
        ReasoningEffort.medium,
        ReasoningEffort.high,
      ], _ReasoningParamStyle.openAiEffort);
    }
    if (_gptOss.hasMatch(name)) {
      return const ModelReasoningCapability._([
        ReasoningEffort.low,
        ReasoningEffort.medium,
        ReasoningEffort.high,
      ], _ReasoningParamStyle.openAiEffort);
    }
    if (_qwenThinking.hasMatch(name)) {
      return const ModelReasoningCapability._(
        ReasoningEffort.values,
        _ReasoningParamStyle.qwenThinking,
      );
    }
    if (_glmThinking.hasMatch(name)) {
      return const ModelReasoningCapability._(
        [ReasoningEffort.none, ReasoningEffort.high],
        _ReasoningParamStyle.thinkingToggle,
        binary: true,
      );
    }
    return null;
  }

  /// 未收录模型的通用兜底：按协议族最常见的字段给出三档
  ///
  /// 只开放低/中/高：「关闭」在多数网关里并没有可靠的表达（OpenAI 的
  /// `minimal` 是「尽量少想」而不是「不想」），不如交给「自动」不做干预。
  /// 界面会显式标注这是通用参数，用户选错时由发信层的 400 降级兜住。
  static ModelReasoningCapability genericFor({
    String providerType = 'openai',
    String? vendorId,
  }) {
    if (providerType == 'gemini') {
      return const ModelReasoningCapability._(
        [ReasoningEffort.low, ReasoningEffort.medium, ReasoningEffort.high],
        _ReasoningParamStyle.geminiThinkingBudget,
        isGeneric: true,
      );
    }
    if (vendorId == 'openrouter') {
      // OpenRouter 只认统一的 reasoning.effort，写 reasoning_effort 会被忽略
      return const ModelReasoningCapability._(
        [ReasoningEffort.low, ReasoningEffort.medium, ReasoningEffort.high],
        _ReasoningParamStyle.openRouterReasoning,
        isGeneric: true,
      );
    }
    return const ModelReasoningCapability._(
      [ReasoningEffort.low, ReasoningEffort.medium, ReasoningEffort.high],
      _ReasoningParamStyle.openAiEffort,
      isGeneric: true,
    );
  }

  /// 界面侧解析：能力表未收录时返回通用兜底，保证入口永远可见
  static ModelReasoningCapability forUi({
    required String modelName,
    String providerType = 'openai',
    String? vendorId,
  }) {
    return resolve(
          modelName: modelName,
          providerType: providerType,
          vendorId: vendorId,
        ) ??
        genericFor(providerType: providerType, vendorId: vendorId);
  }

  /// 把强度写进 OpenAI 兼容请求体
  ///
  /// 档位不受支持时静默跳过：模型能力可能随切换/升级变化，调用方不必先自行校验。
  void applyToOpenAiBody(Map<String, dynamic> body, ReasoningEffort effort) {
    if (!supports(effort)) {
      return;
    }
    if (_style == _ReasoningParamStyle.openAiEffort) {
      // OpenAI 的「关闭」叫 minimal；o 系不支持该档，能力表里本来就没给 none
      body['reasoning_effort'] = effort == ReasoningEffort.none
          ? 'minimal'
          : effort.wireName;
    } else if (_style == _ReasoningParamStyle.thinkingToggle) {
      body['thinking'] = {
        'type': effort == ReasoningEffort.none ? 'disabled' : 'enabled',
      };
    } else if (_style == _ReasoningParamStyle.qwenThinking) {
      final enabled = effort != ReasoningEffort.none;
      body['enable_thinking'] = enabled;
      if (enabled) {
        body['thinking_budget'] = _budgetFor(effort);
      }
    } else if (_style == _ReasoningParamStyle.openRouterReasoning) {
      body['reasoning'] = {'effort': effort.wireName};
    }
    // Gemini 两种形态由 [geminiThinkingConfig] 负责，不写顶层字段
  }

  /// Gemini 的 `thinkingConfig`；调用方合并进 `generationConfig`
  Map<String, dynamic>? geminiThinkingConfig(ReasoningEffort effort) {
    if (!supports(effort)) {
      return null;
    }
    if (_style == _ReasoningParamStyle.geminiThinkingLevel) {
      // Gemini 3 只区分低/高（能力表也只提供这两档）
      return {'thinkingLevel': effort == ReasoningEffort.high ? 'high' : 'low'};
    }
    if (_style == _ReasoningParamStyle.geminiThinkingBudget) {
      return {
        'thinkingBudget': effort == ReasoningEffort.none
            ? 0
            : _budgetFor(effort),
      };
    }
    return null;
  }

  /// 档位到 token 预算的映射（Qwen / Gemini 2.5 共用）
  static int _budgetFor(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.none:
        return 0;
      case ReasoningEffort.low:
        return 1024;
      case ReasoningEffort.medium:
        return 4096;
      case ReasoningEffort.high:
        return 16384;
    }
  }

  // ── 模型族匹配 ──────────────────────────────────────────
  // 模型名可能带厂商前缀（openai/gpt-5.4）或 :free 后缀，统一用宽松匹配

  /// gpt-5 系列的非推理对话变体（gpt-5-chat-latest 等）
  static final RegExp _gpt5Chat = RegExp(r'gpt-5(?:\.\d+)?-chat');

  static final RegExp _gpt5 = RegExp(r'gpt-5(?:\.\d+)?(?:-|$)');

  /// o1/o3/o4 推理模型，允许 openai/ 前缀与 -mini 等后缀
  static final RegExp _oSeries = RegExp(r'(?:^|/)(?:o1|o3|o4)(?:-|$)');

  static final RegExp _gptOss = RegExp(r'gpt-oss');

  /// Qwen3 与通义最新商业线；qwen2.5 等老模型没有思考开关
  static final RegExp _qwenThinking = RegExp(
    r'qwen3|qwen-(?:plus|max|turbo|flash)',
  );

  /// 智谱 GLM-4.5 起支持 thinking.type 开关
  static final RegExp _glmThinking = RegExp(r'glm-(?:4\.[5-9]|5(?:\.\d+)?)');

  static final RegExp _gemini3 = RegExp(r'gemini-3(?:\.\d+)?(?:-|$)');

  static final RegExp _gemini25Pro = RegExp(r'gemini-2\.5-pro');

  static final RegExp _gemini25Flash = RegExp(
    r'gemini-2\.5-(?:flash|flash-lite)',
  );

  /// OpenRouter 上确认支持 reasoning.effort 的推理模型族
  static final RegExp _openRouterReasoningModels = RegExp(
    r'gpt-5|gpt-oss|(?:^|/)(?:o1|o3|o4)(?:-|$)|claude|gemini|glm|qwen|'
    r'deepseek-reasoner|kimi-k2|minimax-m2',
  );
}
