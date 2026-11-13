import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/config/app_version.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/utils/version_utils.dart';
import 'package:qnote_flutter/models/builtin_service_config.dart';

/// 一个远程配置来源
class _BuiltinConfigSource {
  final String label;
  final String url;

  /// Gitee 的 Contents API 返回 base64 包装，需要单独解码
  final bool giteeApi;

  const _BuiltinConfigSource(this.label, this.url, {this.giteeApi = false});
}

/// 内置模型服务的远程配置：多源拉取、签名校验、last-known-good 缓存。
///
/// 缓存放 SharedPreferences：不进备份导出、不参与 WebDAV 同步，
/// 因此不会被其它设备或旧备份把地址改回去。
class BuiltinServiceConfigService {
  BuiltinServiceConfigService._();

  static final BuiltinServiceConfigService instance = BuiltinServiceConfigService._();

  static const String _cacheKey = 'builtin_service_config_v1';
  static const String _fetchedAtKey = 'builtin_service_config_fetched_at';
  static const Duration _ttl = Duration(hours: 6);

  /// 国内优先：Gitee Contents API → jsDelivr → GitHub raw → 国内镜像
  static const List<_BuiltinConfigSource> _sources = <_BuiltinConfigSource>[
    _BuiltinConfigSource(
      'Gitee API',
      'https://gitee.com/api/v5/repos/favo9/qnote/contents/qnote_builtin.json?ref=builtin-config',
      giteeApi: true,
    ),
    _BuiltinConfigSource('jsDelivr', 'https://cdn.jsdelivr.net/gh/favoroo/QNote@builtin-config/qnote_builtin.json'),
    _BuiltinConfigSource(
      'GitHub raw',
      'https://raw.githubusercontent.com/favoroo/QNote/builtin-config/qnote_builtin.json',
    ),
    _BuiltinConfigSource(
      'ghfast',
      'https://ghfast.top/https://raw.githubusercontent.com/favoroo/QNote/builtin-config/qnote_builtin.json',
    ),
  ];

  final ValueNotifier<BuiltinServiceConfig?> configNotifier = ValueNotifier<BuiltinServiceConfig?>(null);

  /// 配置内容变化时自增；UI 与厂商列表据此刷新
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 最近一次拉取失败原因（成功后清空）
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// 是否正在拉取
  final ValueNotifier<bool> refreshing = ValueNotifier<bool>(false);

  DateTime? fetchedAt;

  BuiltinServiceConfig? get config => configNotifier.value;

  bool get hasConfig => configNotifier.value != null;

  /// 缓存是否已过期（无缓存也算过期）
  bool get isStale {
    final at = fetchedAt;
    if (at == null) return true;
    return DateTime.now().difference(at) > _ttl;
  }

  /// 当前配置要求的最低 App 版本是否满足
  bool get isAppSupported {
    final current = configNotifier.value;
    return current == null || isAppSupportedFor(current);
  }

  /// 指定配置要求的最低 App 版本是否满足（便于纯单测）
  bool isAppSupportedFor(BuiltinServiceConfig current) {
    if (current.minAppVersion.trim().isEmpty) return true;
    String appVersion;
    try {
      appVersion = AppVersion.version;
    } catch (_) {
      // 测试或极早期调用时 AppVersion 可能还没初始化，按「满足」处理
      return true;
    }
    return !isVersionNewer(candidate: current.minAppVersion, current: appVersion);
  }

  /// 启动期只读本地缓存，不联网、不阻塞首帧
  Future<void> loadCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_cacheKey);
      if (raw == null || raw.isEmpty) return;
      final parsed = BuiltinServiceConfig.tryParse(raw);
      if (parsed == null) {
        LoggerService.instance.warning('内置服务配置缓存校验失败，已忽略');
        return;
      }
      configNotifier.value = parsed;
      final ts = prefs.getInt(_fetchedAtKey);
      fetchedAt = ts == null ? null : DateTime.fromMillisecondsSinceEpoch(ts);
      revision.value++;
    } catch (e) {
      LoggerService.instance.warning('读取内置服务配置缓存失败: $e');
    }
  }

  /// 过期或强制时才拉取
  Future<bool> refreshIfStale({bool force = false}) async {
    if (!force && !isStale) return false;
    return refresh();
  }

  /// 依次尝试所有来源；任一成功即写缓存并返回 true
  Future<bool> refresh() async {
    if (refreshing.value) return false;
    refreshing.value = true;
    try {
      final dio = Dio(
        BaseOptions(
          connectTimeout: const Duration(seconds: 5),
          receiveTimeout: const Duration(seconds: 8),
          followRedirects: true,
        ),
      );
      for (final source in _sources) {
        try {
          final raw = await _fetchSource(dio, source);
          if (raw == null || raw.isEmpty) continue;
          final parsed = BuiltinServiceConfig.tryParse(raw);
          if (parsed == null) {
            LoggerService.instance.logNetwork('内置服务配置校验失败：${source.label}');
            continue;
          }
          final current = configNotifier.value;
          if (current != null && parsed.version < current.version) {
            // 远端回滚：保留本地较新配置，避免把地址改回失效的旧值
            LoggerService.instance.logNetwork('内置服务配置版本回退（远端 v${parsed.version} < 本地 v${current.version}），已忽略');
            continue;
          }
          await _save(parsed, raw);
          lastError.value = null;
          LoggerService.instance.logNetwork('内置服务配置已更新：v${parsed.version}（来源 ${source.label}）');
          return true;
        } catch (e) {
          LoggerService.instance.logNetwork('内置服务配置源失败：${source.label} → $e');
        }
      }
      lastError.value = '内置服务暂不可用';
      LoggerService.instance.warning('内置服务配置全部来源失败');
      return false;
    } finally {
      refreshing.value = false;
    }
  }

  Future<String?> _fetchSource(Dio dio, _BuiltinConfigSource source) async {
    // GitHub raw / jsDelivr 有 CDN 缓存，加时间戳尽量拿到最新一版（Gitee API 不需要）
    final url = source.giteeApi
        ? source.url
        : '${source.url}${source.url.contains('?') ? '&' : '?'}t=${DateTime.now().millisecondsSinceEpoch}';
    final res = await dio.get<dynamic>(
      url,
      options: Options(responseType: source.giteeApi ? ResponseType.json : ResponseType.plain),
    );
    final data = res.data;
    if (source.giteeApi) {
      if (data is Map && data['encoding'] == 'base64' && data['content'] is String) {
        return utf8.decode(base64Decode(data['content'] as String));
      }
      return null;
    }
    if (data is String) return data;
    if (data is Map) return jsonEncode(data);
    return null;
  }

  Future<void> _save(BuiltinServiceConfig parsed, String raw) async {
    final changed = configNotifier.value?.version != parsed.version;
    configNotifier.value = parsed;
    fetchedAt = DateTime.now();
    if (changed) revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cacheKey, raw);
      await prefs.setInt(_fetchedAtKey, fetchedAt!.millisecondsSinceEpoch);
    } catch (e) {
      LoggerService.instance.warning('写入内置服务配置缓存失败: $e');
    }
  }
}
