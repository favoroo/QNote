import 'package:qnote_flutter/core/ai/anthropic_protocol.dart';
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

  /// Anthropic Messages：`thinking: {type: enabled, budget_tokens}`（预算由协议模块给）
  anthropicThinking,
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

  const ModelReasoningCapability._(this.levels, this._style, {bool binary = false, this.isGeneric = false})
    : _binary = binary;

  /// 是否为「能力表未收录」的通用兜底
  ///
  /// 未收录模型也给出入口（对齐 ZCode：用户总能自己调），但按协议族最常见的
  /// 字段发送；网关不认时由 AiService 的 400 降级重发兜住，不会把对话打死。
  final bool isGeneric;

  /// 是否为二值开关模型（目前是 GLM）
  bool get isBinary => _binary;

  /// 默认开放的档位：只给能力表确认过的四档
  ///
  /// `minimal` / `xhigh` / `max` 不是每家都认，默认不放进对话面板；用户可在
  /// 模型配置里按需勾选，避免一上来就给出 8 个 chips。
  static const List<ReasoningEffort> _defaultLevels = [
    ReasoningEffort.none,
    ReasoningEffort.low,
    ReasoningEffort.medium,
    ReasoningEffort.high,
  ];

  /// 参数形态的中文说明，配置页用来解释「这些档位会怎么发出去」
  String get paramStyleLabel {
    switch (_style) {
      case _ReasoningParamStyle.openAiEffort:
        return '按 reasoning_effort 发送';
      case _ReasoningParamStyle.thinkingToggle:
        return '按 thinking.type 开关发送，档位同时附带 reasoning_effort';
      case _ReasoningParamStyle.qwenThinking:
        return '按 enable_thinking + thinking_budget 发送';
      case _ReasoningParamStyle.openRouterReasoning:
        return '按 reasoning.effort 发送';
      case _ReasoningParamStyle.geminiThinkingLevel:
        return '按 thinkingLevel 发送，只区分低/高';
      case _ReasoningParamStyle.geminiThinkingBudget:
        return '按 thinkingBudget 发送';
      case _ReasoningParamStyle.anthropicThinking:
        return '按 thinking.budget_tokens 发送';
    }
  }

  /// 配置页的候选档位：始终给完整档位
  ///
  /// 不按协议收缩：同一个模型经不同网关转发时能表达的档位并不一致，替用户
  /// 预先裁掉中间档只会让「想加一档」变成改代码。不能单独表达的档位会在配置
  /// 页按 [wireValueFor] 展示实际发送值，网关拒绝时再由 400 降级兜住。
  List<ReasoningEffort> get configurableLevels => ReasoningEffort.values;

  /// 档位在请求里的实际写法，配置页展示给愿意看参数的用户
  String wireValueFor(ReasoningEffort effort) {
    switch (_style) {
      case _ReasoningParamStyle.openAiEffort:
        // OpenAI 兼容端点大多没有真正的「关闭」，用 minimal 表达
        return effort == ReasoningEffort.none || effort == ReasoningEffort.minimal
            ? 'reasoning_effort: minimal'
            : 'reasoning_effort: ${effort.wireName}';
      case _ReasoningParamStyle.thinkingToggle:
        // 开关表达不了强度，额外带一个 reasoning_effort 尽力表达；网关不认时
        // 由发信层的 400 降级把两个参数一起摘掉
        return effort == ReasoningEffort.none
            ? 'thinking.type: disabled'
            : 'thinking.type: enabled + reasoning_effort: ${effort.wireName}';
      case _ReasoningParamStyle.qwenThinking:
        return effort == ReasoningEffort.none ? 'enable_thinking: false' : 'thinking_budget: ${_budgetFor(effort)}';
      case _ReasoningParamStyle.openRouterReasoning:
        return 'reasoning.effort: ${effort.wireName}';
      case _ReasoningParamStyle.geminiThinkingLevel:
        return 'thinkingLevel: ${_geminiIsHigh(effort) ? 'high' : 'low'}';
      case _ReasoningParamStyle.geminiThinkingBudget:
        return 'thinkingBudget: ${_budgetFor(effort)}';
      case _ReasoningParamStyle.anthropicThinking:
        final budget = anthropicThinkingBudget(effort.wireName);
        return budget == null ? 'thinking: 不发送（关闭）' : 'thinking.budget_tokens: $budget';
    }
  }

  /// 用自定义档位集合覆盖自动识别结果
  ///
  /// 传 null 或空集合表示沿用自动识别；其余档位一律保留，只做去重与排序。
  /// 是否「能发出去」交给 [supports] 与配置页的实际发送值说明，不在这里
  /// 替用户裁剪。
  ModelReasoningCapability withLevels(List<ReasoningEffort>? customLevels) {
    if (customLevels == null || customLevels.isEmpty) {
      return this;
    }
    final normalized = [
      for (final effort in ReasoningEffort.values)
        if (customLevels.contains(effort)) effort,
    ];
    if (normalized.isEmpty) {
      return this;
    }
    return ModelReasoningCapability._(List.unmodifiable(normalized), _style, binary: _binary, isGeneric: isGeneric);
  }

  /// 该档位是否受支持（切换模型后旧选择可能失效，调用方据此回落到「自动」）
  bool supports(ReasoningEffort effort) => levels.contains(effort);

  /// 档位展示名；null 表示「自动」
  ///
  /// 二值模型也不再把 high 改叫「开启」：档位集合可能被用户扩成低/中/高，
  /// 单独一个「开启」夹在中间只会让人以为它们互斥。
  String labelFor(ReasoningEffort? effort) => effort?.label ?? '自动';

  /// 解析模型能力；null 表示该模型不支持配置思考强度
  ///
  /// 匹配顺序即协议优先级：原生 Gemini > Anthropic Messages > OpenRouter >
  /// 各厂商 OpenAI 兼容字段。
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
        return const ModelReasoningCapability._(_defaultLevels, _ReasoningParamStyle.geminiThinkingBudget);
      }
      return null;
    }

    // 2. Anthropic Messages：思考预算写在顶层 thinking.budget_tokens 下
    if (providerType == 'anthropic') {
      // 未命中已知族时返回 null（界面不展示入口），由 forUi 的通用兜底接手
      return _claudeThinking.hasMatch(name)
          ? const ModelReasoningCapability._(_defaultLevels, _ReasoningParamStyle.anthropicThinking)
          : null;
    }

    // 3. OpenRouter：统一 reasoning.effort，不跟随各厂商私有字段
    if (vendorId == 'openrouter') {
      return _openRouterReasoningModels.hasMatch(name)
          ? const ModelReasoningCapability._([
              ReasoningEffort.low,
              ReasoningEffort.medium,
              ReasoningEffort.high,
            ], _ReasoningParamStyle.openRouterReasoning)
          : null;
    }

    // 4. OpenAI 兼容协议：各家把「思考」塞进不同顶层字段
    // gpt-5-chat 是非推理对话模型，不接受 reasoning_effort
    if (_gpt5Chat.hasMatch(name)) {
      return null;
    }
    if (_gpt5.hasMatch(name)) {
      return const ModelReasoningCapability._(_defaultLevels, _ReasoningParamStyle.openAiEffort);
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
      return const ModelReasoningCapability._(_defaultLevels, _ReasoningParamStyle.qwenThinking);
    }
    if (_glmThinking.hasMatch(name)) {
      // 默认就给四档：GLM 的 thinking.type 是开关，但对话面板不该只剩
      // 「开启/关闭」，中间档由 reasoning_effort 尽力表达
      return const ModelReasoningCapability._(_defaultLevels, _ReasoningParamStyle.thinkingToggle, binary: true);
    }
    return null;
  }

  /// 未收录模型的通用兜底：按协议族最常见的字段给出全部四档
  ///
  /// 「关闭」也要真实发出去：时间线提取默认不思考，未收录模型若缺少该档位，
  /// 用户看到的「关闭」与实际行为会不一致（请求里什么都没带，模型照常思考）。
  /// OpenAI 兼容协议的 `minimal` 是「尽量少想」，对提取场景已足够；参数不被
  /// 接受时由发信层的 400 降级兜住，不会把请求打挂。
  static ModelReasoningCapability genericFor({String providerType = 'openai', String? vendorId}) {
    if (providerType == 'gemini') {
      return const ModelReasoningCapability._(
        _defaultLevels,
        _ReasoningParamStyle.geminiThinkingBudget,
        isGeneric: true,
      );
    }
    if (vendorId == 'openrouter') {
      // OpenRouter 只认统一的 reasoning.effort，写 reasoning_effort 会被忽略
      return const ModelReasoningCapability._(
        _defaultLevels,
        _ReasoningParamStyle.openRouterReasoning,
        isGeneric: true,
      );
    }
    if (providerType == 'anthropic') {
      // Messages 协议下未收录的模型也按 thinking.budget_tokens 发（同族形态一致），
      // 不认该字段的接入点由 400 降级兜住
      return const ModelReasoningCapability._(_defaultLevels, _ReasoningParamStyle.anthropicThinking, isGeneric: true);
    }
    return const ModelReasoningCapability._(_defaultLevels, _ReasoningParamStyle.openAiEffort, isGeneric: true);
  }

  /// 界面侧解析：能力表未收录时返回通用兜底，保证入口永远可见
  ///
  /// [customLevels] 是用户在模型配置里勾选的档位集合；为空或 null 时沿用
  /// 自动识别结果。
  static ModelReasoningCapability forUi({
    required String modelName,
    String providerType = 'openai',
    String? vendorId,
    List<ReasoningEffort>? customLevels,
  }) {
    final base =
        resolve(modelName: modelName, providerType: providerType, vendorId: vendorId) ??
        genericFor(providerType: providerType, vendorId: vendorId);
    return base.withLevels(customLevels);
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
      body['reasoning_effort'] = effort == ReasoningEffort.none ? 'minimal' : effort.wireName;
    } else if (_style == _ReasoningParamStyle.thinkingToggle) {
      body['thinking'] = {'type': effort == ReasoningEffort.none ? 'disabled' : 'enabled'};
      // 开关本身只有两态，附带 effort 让支持该字段的网关能表达中间档；
      // 不支持的网关会忽略或 400，后者由降级重发兜住
      if (effort != ReasoningEffort.none) {
        body['reasoning_effort'] = effort.wireName;
      }
    } else if (_style == _ReasoningParamStyle.qwenThinking) {
      final enabled = effort != ReasoningEffort.none;
      body['enable_thinking'] = enabled;
      if (enabled) {
        body['thinking_budget'] = _budgetFor(effort);
      }
    } else if (_style == _ReasoningParamStyle.openRouterReasoning) {
      body['reasoning'] = {'effort': effort.wireName};
    }
    // Gemini 与 Anthropic 的形态各自由 [geminiThinkingConfig] /
    // `anthropic_protocol.buildAnthropicBody` 负责，不写顶层字段
  }

  /// Gemini 的 `thinkingConfig`；调用方合并进 `generationConfig`
  Map<String, dynamic>? geminiThinkingConfig(ReasoningEffort effort) {
    if (!supports(effort)) {
      return null;
    }
    if (_style == _ReasoningParamStyle.geminiThinkingLevel) {
      // Gemini 3 只有 low/high 两个真实档位；用户勾选的中间档按就近折叠，
      // 配置页会展示折叠后的实际值
      return {'thinkingLevel': _geminiIsHigh(effort) ? 'high' : 'low'};
    }
    if (_style == _ReasoningParamStyle.geminiThinkingBudget) {
      return {'thinkingBudget': effort == ReasoningEffort.none ? 0 : _budgetFor(effort)};
    }
    return null;
  }

  /// Gemini 3 只有低/高：中档及以上都按高发送，避免「中」被折叠成低
  static bool _geminiIsHigh(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.none:
      case ReasoningEffort.minimal:
      case ReasoningEffort.low:
        return false;
      case ReasoningEffort.medium:
      case ReasoningEffort.high:
      case ReasoningEffort.xhigh:
      case ReasoningEffort.max:
        return true;
    }
  }

  /// 档位到 token 预算的映射（Qwen / Gemini 2.5 共用）
  static int _budgetFor(ReasoningEffort effort) {
    switch (effort) {
      case ReasoningEffort.none:
        return 0;
      case ReasoningEffort.minimal:
        return 512;
      case ReasoningEffort.low:
        return 1024;
      case ReasoningEffort.medium:
        return 4096;
      case ReasoningEffort.high:
        return 16384;
      case ReasoningEffort.xhigh:
        return 32768;
      case ReasoningEffort.max:
        return 65536;
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
  static final RegExp _qwenThinking = RegExp(r'qwen3|qwen-(?:plus|max|turbo|flash)');

  /// 智谱 GLM-4.5 起支持 thinking.type 开关
  static final RegExp _glmThinking = RegExp(r'glm-(?:4\.[5-9]|5(?:\.\d+)?)');

  static final RegExp _gemini3 = RegExp(r'gemini-3(?:\.\d+)?(?:-|$)');

  static final RegExp _gemini25Pro = RegExp(r'gemini-2\.5-pro');

  static final RegExp _gemini25Flash = RegExp(r'gemini-2\.5-(?:flash|flash-lite)');

  /// OpenRouter 上确认支持 reasoning.effort 的推理模型族
  static final RegExp _openRouterReasoningModels = RegExp(
    r'gpt-5|gpt-oss|(?:^|/)(?:o1|o3|o4)(?:-|$)|claude|gemini|glm|qwen|'
    r'deepseek-reasoner|kimi-k2|minimax-m2',
  );

  /// Anthropic Messages 协议下的 Claude 模型：3.7 起支持 extended thinking
  static final RegExp _claudeThinking = RegExp(r'claude-(?:3[-.]7|[4-9]|fable|opus|sonnet|haiku)');
}
