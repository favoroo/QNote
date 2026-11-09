import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/reasoning_effort.dart';

/// 发信层使用的模型配置（请求时值对象）
///
/// **不再是数据库行**：唯一数据源是 [AiProvider] 厂商条目，本对象在每次发起
/// 请求前由「厂商条目 + 模型名」现场组装，供 [AiService]/识图能力判定/工具链路
/// 这类只关心「用哪个地址、哪把 Key、哪个模型」的消费方使用。
///
/// [apiKey] 是池中首把 Key，仅作兜底；多把 Key 的厂商在真正发信前会被
/// `ApiKeyPool` 轮换出的 Key 逐请求覆写 header。
class AiConfig {
  /// 厂商条目 id（Key 池定位依据）
  final String providerId;

  /// 展示名，如「DeepSeek · deepseek-v4-flash」
  final String name;

  /// 接口类型：`openai` | `gemini`
  final String provider;

  final String modelName;

  /// 发信兜底 Key（厂商条目里密钥池的首把；订阅账号型为空，发信前现取）
  final String apiKey;

  final String baseUrl;

  /// 凭证类型：`api_key` | `raccoon`
  ///
  /// 订阅账号型由 `RaccoonAuthService` 在每次发信前取 token，
  /// [apiKey] 不参与鉴权。
  final String authMode;

  /// 厂商模板 id（推理强度等厂商级默认值的来源）
  final String? vendorId;

  /// 模型级思考强度；null 表示「自动」（沿用厂商默认或不干预）
  final ReasoningEffort? reasoningEffort;

  const AiConfig({
    required this.providerId,
    required this.name,
    required this.provider,
    required this.modelName,
    required this.apiKey,
    required this.baseUrl,
    this.authMode = AiProvider.authModeApiKey,
    this.vendorId,
    this.reasoningEffort,
  });

  /// 是否由订阅账号提供凭证
  bool get usesAccountAuth => authMode != AiProvider.authModeApiKey;

  /// 由厂商条目 + 模型名组装请求配置
  factory AiConfig.fromProvider(
    AiProvider provider,
    String modelName, {
    String? displayName,
  }) {
    final model = provider.models.where((m) => m.id == modelName).firstOrNull;
    final keys = provider.apiKeys.where((k) => k.trim().isNotEmpty).toList();
    return AiConfig(
      providerId: provider.id,
      name:
          displayName ??
          (model?.name.isNotEmpty == true ? model!.name : modelName),
      provider: provider.providerType,
      modelName: modelName,
      apiKey: keys.isEmpty ? '' : keys.first,
      baseUrl: provider.baseUrl,
      authMode: provider.authMode,
      vendorId: provider.vendorId,
      reasoningEffort: model?.reasoningEffort,
    );
  }

  AiConfig copyWith({
    String? providerId,
    String? name,
    String? provider,
    String? modelName,
    String? apiKey,
    String? baseUrl,
    String? authMode,
    String? vendorId,
    ReasoningEffort? reasoningEffort,
  }) {
    return AiConfig(
      providerId: providerId ?? this.providerId,
      name: name ?? this.name,
      provider: provider ?? this.provider,
      modelName: modelName ?? this.modelName,
      apiKey: apiKey ?? this.apiKey,
      baseUrl: baseUrl ?? this.baseUrl,
      authMode: authMode ?? this.authMode,
      vendorId: vendorId ?? this.vendorId,
      reasoningEffort: reasoningEffort ?? this.reasoningEffort,
    );
  }

  @override
  String toString() => 'AiConfig($providerId/$modelName @ $baseUrl)';
}
