import 'package:qnote_flutter/models/ai_provider.dart';

/// 订阅账号的一次登录态（表 `ai_accounts`）
///
/// 与 [AiProvider] 分开存放的原因：
/// - refresh token 是长期凭据，不能跟着厂商条目一起进 WebDAV 备份/多端同步；
/// - 一个厂商条目在账号型模式下只有一份登录态，独立表可以按 providerId 直接取。
///
/// 本表**不写** `sync_log`，也不会出现在备份导出清单里，换设备/恢复备份后
/// 需要重新登录。
class AiAccount {
  /// 账号类型：商汤小浣熊
  static const String kindRaccoon = 'raccoon';

  static const String statusActive = 'active';
  static const String statusExpired = 'expired';

  /// 对应的厂商条目 id（一个条目一份登录态）
  final String providerId;

  /// 账号类型，目前只有 [kindRaccoon]；为后续接入其他订阅型服务预留
  final String kind;

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

  final DateTime createdAt;
  final DateTime updatedAt;

  const AiAccount({
    required this.providerId,
    this.kind = kindRaccoon,
    required this.accessToken,
    this.refreshToken = '',
    this.expiresAt,
    this.uid = '',
    this.displayName = '',
    this.phone = '',
    this.status = statusActive,
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

  /// 界面上展示的账号名：手机号优先，其次 JWT 名，最后 uid
  String get label {
    if (phone.trim().isNotEmpty) return phone;
    if (displayName.trim().isNotEmpty) return displayName;
    if (uid.trim().isNotEmpty) return uid;
    return '小浣熊账号';
  }

  Map<String, dynamic> toMap() {
    return {
      'provider_id': providerId,
      'kind': kind,
      'access_token': accessToken,
      'refresh_token': refreshToken,
      'expires_at': expiresAt?.toIso8601String(),
      'uid': uid,
      'display_name': displayName,
      'phone': phone,
      'status': status,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AiAccount.fromMap(Map<String, dynamic> map) {
    return AiAccount(
      providerId: (map['provider_id'] as String?) ?? '',
      kind: (map['kind'] as String?) ?? kindRaccoon,
      accessToken: (map['access_token'] as String?) ?? '',
      refreshToken: (map['refresh_token'] as String?) ?? '',
      expiresAt: _parseTime(map['expires_at'] as String?),
      uid: (map['uid'] as String?) ?? '',
      displayName: (map['display_name'] as String?) ?? '',
      phone: (map['phone'] as String?) ?? '',
      status: (map['status'] as String?) ?? statusActive,
      createdAt: _parseTime(map['created_at'] as String?) ?? DateTime.now(),
      updatedAt: _parseTime(map['updated_at'] as String?) ?? DateTime.now(),
    );
  }

  AiAccount copyWith({
    String? accessToken,
    String? refreshToken,
    Object? expiresAt = _unset,
    String? uid,
    String? displayName,
    String? phone,
    String? status,
    DateTime? updatedAt,
  }) {
    return AiAccount(
      providerId: providerId,
      kind: kind,
      accessToken: accessToken ?? this.accessToken,
      refreshToken: refreshToken ?? this.refreshToken,
      expiresAt:
          identical(expiresAt, _unset) ? this.expiresAt : expiresAt as DateTime?,
      uid: uid ?? this.uid,
      displayName: displayName ?? this.displayName,
      phone: phone ?? this.phone,
      status: status ?? this.status,
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
