import 'package:qnote_flutter/models/ai_provider.dart';

/// 订阅账号的一次登录态（表 `ai_accounts`）
///
/// 与 [AiProvider] 分开存放的原因：
/// - refresh token 是长期凭据，不能跟着厂商条目一起进 WebDAV 备份/多端同步；
/// - 一个厂商条目可以同时登录多个账号，选号策略与亲和时长属于厂商条目
///   （`ai_providers.account_routing` / `account_affinity`），账号本身只管凭证。
///
/// 本表**不写** `sync_log`，也不会出现在备份导出清单里，换设备/恢复备份后
/// 需要重新登录。
class AiAccount {
  /// 账号类型：商汤小浣熊
  static const String kindRaccoon = 'raccoon';

  static const String statusActive = 'active';
  static const String statusExpired = 'expired';

  /// 账号行主键（uuid）
  ///
  /// 同一个厂商下可以有多行（多账号），因此不能用 providerId 当主键。
  final String id;

  /// 对应的厂商条目 id
  final String providerId;

  /// 账号类型，目前只有 [kindRaccoon]；为后续接入其他订阅型服务预留
  final String kind;

  /// 用户自定义备注（如「工作号」「小号」），空时界面用 [label]
  final String alias;

  final String accessToken;

  /// 为空表示只能等 access token 到期后重新登录（手动粘贴 JWT 的兜底场景）
  final String refreshToken;

  /// access token 的 JWT `exp`（解析不到时为 null）
  final DateTime? expiresAt;

  /// 账号在厂商侧的 id（JWT 里的 sid/sub 等）
  final String uid;

  /// 账号展示名（JWT 的 name；没有时回落 uid）
  final String displayName;

  /// 脱敏手机号，例如 `138****8000`
  final String phone;

  /// `active` | `expired`
  final String status;

  /// 是否参与轮换：关掉的账号保留登录态，但不会被选中
  final bool enabled;

  /// 轮换顺序（升序；「顺序」策略按它排优先级）
  final int sortOrder;

  final DateTime createdAt;
  final DateTime updatedAt;

  const AiAccount({
    required this.id,
    required this.providerId,
    this.kind = kindRaccoon,
    this.alias = '',
    required this.accessToken,
    this.refreshToken = '',
    this.expiresAt,
    this.uid = '',
    this.displayName = '',
    this.phone = '',
    this.status = statusActive,
    this.enabled = true,
    this.sortOrder = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  bool get isExpired => status == statusExpired;

  /// 是否已到/快到（默认提前 60 秒）需要刷新
  bool isStale({Duration margin = const Duration(seconds: 60)}) {
    final at = expiresAt;
    if (at == null) return false;
    return !DateTime.now().isBefore(at.subtract(margin));
  }

  /// 界面上展示的账号名：备注优先，其次手机号、JWT 名、uid
  String get label {
    if (alias.trim().isNotEmpty) return alias.trim();
    if (phone.trim().isNotEmpty) return phone;
    if (displayName.trim().isNotEmpty) return displayName;
    if (uid.trim().isNotEmpty) return uid;
    return '小浣熊账号';
  }

  /// 是否与另一份登录态指向同一个厂商账号（重登同一账号时用来去重）
  ///
  /// uid 是首选判据；手动粘贴 JWT 可能解析不出 uid，此时退到脱敏手机号。
  /// 两者都拿不到时返回 false，宁可多一行也不要把两个账号合并。
  bool isSameVendorAccount(AiAccount other) {
    if (uid.trim().isNotEmpty && other.uid.trim().isNotEmpty) {
      return uid.trim() == other.uid.trim();
    }
    if (phone.trim().isNotEmpty && other.phone.trim().isNotEmpty) {
      return phone.trim() == other.phone.trim();
    }
    return false;
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'provider_id': providerId,
      'kind': kind,
      'alias': alias,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt?.toIso8601String(),
      'uid': uid,
      'display_name': displayName,
      'phone': phone,
      'status': status,
      'enabled': enabled ? 1 : 0,
      'sort_order': sortOrder,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AiAccount.fromMap(Map<String, dynamic> map) {
    final providerId = (map['provider_id'] as String?) ?? '';
    final id = (map['id'] as String?)?.trim() ?? '';
    return AiAccount(
      // v30 的老库没有 id 列，迁移时以 provider_id 兜底
      id: id.isEmpty ? providerId : id,
      providerId: providerId,
      kind: (map['kind'] as String?) ?? kindRaccoon,
      alias: (map['alias'] as String?) ?? '',
      accessToken: (map['access_token'] as String?) ?? '',
      refreshToken: (map['refresh_token'] as String?) ?? '',
      expiresAt: _parseTime(map['expires_at'] as String?),
      uid: (map['uid'] as String?) ?? '',
      displayName: (map['display_name'] as String?) ?? '',
      phone: (map['phone'] as String?) ?? '',
      status: (map['status'] as String?) ?? statusActive,
      enabled: (map['enabled'] as int? ?? 1) == 1,
      sortOrder: (map['sort_order'] as int?) ?? 0,
      createdAt: _parseTime(map['created_at'] as String?) ?? DateTime.now(),
      updatedAt: _parseTime(map['updated_at'] as String?) ?? DateTime.now(),
    );
  }

  AiAccount copyWith({
    String? alias,
    String? accessToken,
    String? refreshToken,
    Object? expiresAt = _unset,
    String? uid,
    String? displayName,
    String? phone,
    String? status,
    bool? enabled,
    int? sortOrder,
    DateTime? updatedAt,
  }) {
    return AiAccount(
      id: id,
      providerId: providerId,
      kind: kind,
      alias: alias ?? this.alias,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt:
          identical(expiresAt, _unset) ? this.expiresAt : expiresAt as DateTime?,
      uid: uid ?? this.uid,
      displayName: displayName ?? this.displayName,
      phone: phone ?? this.phone,
      status: status ?? this.status,
      enabled: enabled ?? this.enabled,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  static const Object _unset = Object();

  static DateTime? _parseTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    return DateTime.tryParse(raw);
  }
}
