import 'package:qnote_flutter/core/storage/config_repository.dart';

/// 知识图谱的用户配置键与默认值。
///
/// 配置写在 `app_configs`（随 WebDAV 同步），但图谱本身不写 sync_log：
/// 配置是用户偏好，图谱是派生数据，两者生命周期不同。
abstract final class KgConfigKeys {
  static const String enabled = 'kg_enabled';
  static const String semanticEnabled = 'kg_llm_enabled';
  static const String dailyDocLimit = 'kg_daily_doc_limit';
}

class KgConfig {
  static final ConfigRepository _config = ConfigRepository.instance;

  static const int defaultDailyDocLimit = 30;

  /// 图谱是否启用（默认开）
  static Future<bool> isEnabled() async {
    final raw = await _config.getAppConfig(KgConfigKeys.enabled);
    if (raw == null || raw.trim().isEmpty) return true;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  /// 是否允许笔记/日记语义抽取（默认开；关闭后仍保留规则图谱）
  static Future<bool> isSemanticEnabled() async {
    final raw = await _config.getAppConfig(KgConfigKeys.semanticEnabled);
    if (raw == null || raw.trim().isEmpty) return true;
    return raw == '1' || raw.toLowerCase() == 'true';
  }

  /// 每日语义抽取文档上限
  static Future<int> dailyDocLimit() async {
    final raw = await _config.getAppConfig(KgConfigKeys.dailyDocLimit);
    final parsed = int.tryParse(raw ?? '');
    if (parsed == null) return defaultDailyDocLimit;
    return parsed.clamp(0, 500);
  }

  static Future<void> setEnabled(bool value) => _config.setAppConfig(KgConfigKeys.enabled, value ? '1' : '0');

  static Future<void> setSemanticEnabled(bool value) =>
      _config.setAppConfig(KgConfigKeys.semanticEnabled, value ? '1' : '0');

  static Future<void> setDailyDocLimit(int value) =>
      _config.setAppConfig(KgConfigKeys.dailyDocLimit, value.clamp(0, 500).toString());
}
