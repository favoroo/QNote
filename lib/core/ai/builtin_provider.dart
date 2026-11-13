import 'package:qnote_flutter/config/ai_vendors.dart';
import 'package:qnote_flutter/core/ai/builtin_service_config_service.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/builtin_service_config.dart';

/// 内置免费模型：以「虚拟厂商」形式注入，**不落 `ai_providers` 表**。
///
/// 这样它天然不参与 WebDAV 增量同步、备份导出与导入，也不会把任何凭证写进备份；
/// 同时仍能被现有的模型选择器、角色绑定与发信层识别。
class BuiltinProvider {
  BuiltinProvider._();

  /// 虚拟厂商固定 id（与真实 UUID 区分，便于各处拦截）
  static const String id = 'qnote_builtin';

  /// 虚拟厂商模板 id；`vendorAllowsKeyless` 对它放行
  static const String vendorId = kBuiltinVendorId;

  /// 展示名
  static const String name = '小Q 内置服务';

  /// 对外公开的模型别名（真实模型名只在网关侧映射）
  static const String chatModelId = 'qnote-free';
  static const String imageModelId = 'qnote-image-free';

  static const String _chatFallbackName = '小Q 免费模型';
  static const String _imageFallbackName = '小Q 免费生图';

  static bool isBuiltinId(String? value) => value == id;

  static bool isBuiltin(AiProvider provider) => provider.id == id;

  /// 当前配置对应的虚拟厂商；未配置 / 版本不满足 / 无对话能力时返回 null
  static AiProvider? current() => fromConfig(BuiltinServiceConfigService.instance.config);

  static AiProvider? fromConfig(BuiltinServiceConfig? config) {
    if (config == null) return null;
    if (!BuiltinServiceConfigService.instance.isAppSupportedFor(config)) return null;
    if (!config.hasChat) return null;

    final models = <AiProviderModel>[
      AiProviderModel.of(
        chatModelId,
        name: config.chat.displayName.trim().isEmpty ? _chatFallbackName : config.chat.displayName.trim(),
        rate: 0,
        contextWindow: config.chat.contextWindow > 0 ? config.chat.contextWindow : null,
        supportsVision: config.chat.vision,
      ),
      // 生图就绪后由远程配置翻开关，这里自动跟上，无需发版
      if (config.hasImage)
        AiProviderModel.of(
          imageModelId,
          name: config.image.displayName.trim().isEmpty ? _imageFallbackName : config.image.displayName.trim(),
          rate: 0,
          supportsImageGeneration: true,
        ),
    ];

    return AiProvider(
      id: id,
      vendorId: vendorId,
      name: name,
      providerType: 'openai',
      baseUrl: config.baseUrl,
      apiKeys: const <String>[],
      models: models,
      // 维护中或总开关关闭时保留条目但置为停用：选择器会自动跳过，卡片照常显示状态
      enabled: config.isUsable,
      isDefault: false,
      createdAt: DateTime.fromMillisecondsSinceEpoch(0),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// 把虚拟内置厂商合并进用户厂商列表。
///
/// 历史备份/增量里可能混进内置 id 的行，先过滤掉；内置条目追加在末尾，
/// 保证「默认厂商」和「首个可用厂商」的回落顺序仍以用户自己的配置优先。
List<AiProvider> mergeBuiltinProvider(List<AiProvider> stored, AiProvider? builtin) {
  final merged = stored.where((p) => !BuiltinProvider.isBuiltin(p)).toList();
  if (builtin != null) merged.add(builtin);
  return merged;
}
