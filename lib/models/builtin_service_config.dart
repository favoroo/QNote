import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:qnote_flutter/core/ai/builtin_service_secret.dart';

/// 内置模型服务远程配置（`builtin-config` 分支的 `qnote_builtin.json`）。
///
/// 只包含公开信息：隧道地址、模型别名、开关与维护公告。
/// 不包含 magpie 的 Key，也不包含真实上游模型名。
class BuiltinServiceConfig {
  /// 单调递增的配置版本；低于本地缓存版本的配置会被忽略，避免回滚。
  final int version;

  /// 原始 `updatedAt` 字符串（签名按原文计算，不能重新格式化）
  final String updatedAtRaw;

  /// 使用内置服务所需的最低 App 版本
  final String minAppVersion;

  /// 服务总开关；false 表示内置模型暂不可用
  final bool enabled;

  /// 对话能力
  final BuiltinCapability chat;

  /// 生图能力（`enabled` 为真后才会进入「生图模型」候选）
  final BuiltinCapability image;

  /// 维护模式；true 时卡片显示「维护中」且不参与选路
  final bool maintenance;

  /// 维护公告（可为空）
  final String maintenanceMessage;

  /// 完整性校验值
  final String signature;

  const BuiltinServiceConfig({
    required this.version,
    required this.updatedAtRaw,
    required this.minAppVersion,
    required this.enabled,
    required this.chat,
    required this.image,
    required this.maintenance,
    required this.maintenanceMessage,
    required this.signature,
  });

  /// 当前是否可用（总开关打开且不在维护中）
  bool get isUsable => enabled && !maintenance;

  /// 对话请求基址（形如 `https://xxx.trycloudflare.com/v1`）
  String get baseUrl => chat.baseUrl;

  /// 能否作为对话模型使用
  bool get hasChat => chat.enabled && chat.model.isNotEmpty && baseUrl.isNotEmpty;

  /// 能否作为生图模型使用
  bool get hasImage => image.enabled && image.model.isNotEmpty && baseUrl.isNotEmpty;

  BuiltinServiceConfig copyWith({bool? enabled, bool? maintenance, String? maintenanceMessage}) {
    return BuiltinServiceConfig(
      version: version,
      updatedAtRaw: updatedAtRaw,
      minAppVersion: minAppVersion,
      enabled: enabled ?? this.enabled,
      chat: chat,
      image: image,
      maintenance: maintenance ?? this.maintenance,
      maintenanceMessage: maintenanceMessage ?? this.maintenanceMessage,
      signature: signature,
    );
  }

  /// 参与签名的规范化字符串，字段顺序必须与 `tools/builtin_gateway/publish.js` 一致。
  String canonicalString() {
    return <String>[
      '$version',
      updatedAtRaw,
      minAppVersion,
      '$enabled',
      '${chat.enabled}',
      chat.baseUrl,
      chat.model,
      chat.displayName,
      '${chat.contextWindow}',
      '${chat.vision}',
      '${image.enabled}',
      image.model,
      image.displayName,
      '$maintenance',
      maintenanceMessage,
    ].join('\n');
  }

  /// 校验完整性（公开常量，只防误写/损坏，不是安全边界）
  bool verifySignature() {
    if (signature.isEmpty) return false;
    final expected = Hmac(
      sha256,
      utf8.encode(builtinConfigChecksumKey),
    ).convert(utf8.encode(canonicalString())).toString();
    return expected == signature;
  }

  /// 解析并校验远程配置；任何一项不合法都返回 null（调用方保留 last-known-good）
  static BuiltinServiceConfig? tryParse(String raw) {
    Map<String, dynamic> json;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      json = decoded;
    } catch (_) {
      return null;
    }

    final chat = BuiltinCapability.fromJson(json['chat']);
    final image = BuiltinCapability.fromJson(json['image']);
    final version = _asInt(json['version']);
    if (version == null || version <= 0) return null;

    final config = BuiltinServiceConfig(
      version: version,
      updatedAtRaw: (json['updatedAt'] ?? '').toString(),
      minAppVersion: (json['minAppVersion'] ?? '').toString(),
      enabled: json['enabled'] != false,
      chat: chat,
      image: image,
      maintenance: (json['maintenance'] is Map ? json['maintenance']['enabled'] : false) == true,
      maintenanceMessage: (json['maintenance'] is Map ? json['maintenance']['message'] : '')?.toString() ?? '',
      signature: (json['sig'] ?? '').toString(),
    );

    if (!config.verifySignature()) return null;
    if (config.chat.enabled && !isAllowedBaseUrl(config.chat.baseUrl)) return null;
    if (config.chat.enabled && config.chat.model.isEmpty) return null;
    return config;
  }

  /// 基址白名单：只允许 https + 受信任域名，拒绝 localhost / IP / 任意地址，
  /// 避免远程配置被篡改后把请求引到别处。
  static bool isAllowedBaseUrl(String raw) {
    final uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty) return false;
    final host = uri.host.toLowerCase();
    if (host == 'localhost' || host.endsWith('.localhost') || host.endsWith('.local')) return false;
    return _allowedBaseHosts.any((domain) => host == domain || host.endsWith('.$domain'));
  }

  /// 允许的基址域名；以后换自定义域名时在这里追加。
  static const List<String> _allowedBaseHosts = <String>['trycloudflare.com'];

  static int? _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }
}

/// 内置服务的一个能力块（对话 / 生图）
class BuiltinCapability {
  final bool enabled;
  final String model;
  final String displayName;

  /// 请求基址（仅对话块使用）
  final String baseUrl;

  /// 上下文窗口（仅对话块使用）
  final int contextWindow;

  /// 是否支持图片输入（仅对话块使用）
  final bool vision;

  const BuiltinCapability({
    required this.enabled,
    required this.model,
    required this.displayName,
    this.baseUrl = '',
    this.contextWindow = 0,
    this.vision = false,
  });

  factory BuiltinCapability.fromJson(Object? raw) {
    if (raw is! Map) {
      return const BuiltinCapability(enabled: false, model: '', displayName: '');
    }
    return BuiltinCapability(
      enabled: raw['enabled'] != false,
      model: (raw['model'] ?? '').toString(),
      displayName: (raw['displayName'] ?? '').toString(),
      baseUrl: (raw['baseUrl'] ?? '').toString().trim(),
      contextWindow: BuiltinServiceConfig._asInt(raw['contextWindow']) ?? 0,
      vision: raw['vision'] == true,
    );
  }
}
