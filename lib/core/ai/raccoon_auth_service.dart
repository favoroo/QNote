import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'package:qnote_flutter/core/ai/raccoon_login.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/ai_account_repository.dart';
import 'package:qnote_flutter/models/ai_account.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

/// 订阅账号未登录/登录失效：发信前抛出，交给界面提示重新登录
class RaccoonAuthRequiredException implements Exception {
  final String providerId;
  final String message;

  const RaccoonAuthRequiredException(
    this.providerId, {
    this.message = '商汤小浣熊账号未登录或登录已过期，请到「设置 → AI 模型配置」重新登录',
  });

  @override
  String toString() => message;
}

/// 浏览器登录句柄：弹层负责打开 [url]，等待 [result]
class RaccoonLoginHandle {
  final String url;
  final Future<AiAccount> result;
  final void Function() cancel;

  const RaccoonLoginHandle({
    required this.url,
    required this.result,
    required this.cancel,
  });
}

/// 商汤小浣熊（xiaohuanxiong.com）订阅账号的登录、刷新与模型目录
///
/// 接口来自 magpie 社区插件 `@magpie-community/opencode-raccoon-auth`：
/// - 登录：浏览器授权页 → `http://127.0.0.1:<port>/auth/callback?code=...`
///   → `POST /api/web/auth/v1/login_with_authorization_code`；
/// - 刷新：`POST /api/web/auth/v1/refresh`；
/// - 聊天：`POST /api/web/llm/v2/chat/completions`，标准 OpenAI 格式；
/// - 模型：`GET /api/web/llm/v2/model_catalog`。
///
/// token 存在 `ai_accounts` 表，不参与 WebDAV 同步与备份导出。
class RaccoonAuthService {
  RaccoonAuthService._();

  static final RaccoonAuthService instance = RaccoonAuthService._();

  static const String mainOrigin = 'https://xiaohuanxiong.com';
  static const String authBase = '$mainOrigin/api/web/auth/v1';
  static const String llmBase = '$mainOrigin/api/web/llm/v2';

  /// 提前多久刷新（与插件一致的 60 秒量级）
  static const Duration refreshMargin = Duration(seconds: 60);

  final AiAccountRepository _repository = AiAccountRepository.instance;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 30),
      headers: const {'Accept': 'application/json'},
    ),
  );

  /// providerId → 登录态（进程内缓存；登录/刷新/退出都会更新）
  final Map<String, AiAccount> _cache = {};

  /// 同一账号的并发刷新合并成一次，避免 refresh token 被重复消费
  final Map<String, Future<AiAccount>> _refreshing = {};

  /// 测试注入：替换底层 HTTP adapter（不联网校验换取/刷新/目录）
  @visibleForTesting
  set httpClientAdapterForTest(HttpClientAdapter adapter) {
    _dio.httpClientAdapter = adapter;
  }

  /// 读取登录态（默认走缓存；[forceReload] 用于设置页刷新）
  Future<AiAccount?> sessionFor(
    String providerId, {
    bool forceReload = false,
  }) async {
    if (!forceReload) {
      final cached = _cache[providerId];
      if (cached != null) return cached;
    }
    final stored = await _repository.getByProvider(providerId);
    if (stored == null) {
      _cache.remove(providerId);
      return null;
    }
    _cache[providerId] = stored;
    return stored;
  }

  /// 发信前取 access token：临近过期会先刷新；刷新失败按「需要重新登录」处理
  Future<String?> accessTokenFor(String providerId) async {
    final loader = accessTokenLoaderForTest;
    if (loader != null) return loader(providerId);
    final account = await sessionFor(providerId);
    if (account == null) return null;
    if (account.accessToken.trim().isEmpty) return null;
    final needsRefresh =
        account.isExpired || account.isStale(margin: refreshMargin);
    if (!needsRefresh) return account.accessToken;
    try {
      final refreshed = await refresh(providerId, force: true);
      return refreshed.accessToken;
    } on RaccoonAuthRequiredException {
      // 只有厂商明确拒绝（4xx / 没有 refresh token）才标记失效；
      // 网络抖动不能把用户踢下线
      await _markExpired(providerId);
      return null;
    } catch (_) {
      return null;
    }
  }

  /// 测试注入：绕开数据库直接返回 token（仅发信层单测用）
  @visibleForTesting
  static Future<String?> Function(String providerId)? accessTokenLoaderForTest;

  /// 发信前取 token 的严格版本：没有可用登录态直接抛给上层提示
  Future<String> requireAccessToken(String providerId) async {
    final token = await accessTokenFor(providerId);
    if (token == null || token.trim().isEmpty) {
      throw RaccoonAuthRequiredException(providerId);
    }
    return token;
  }

  /// 刷新 access token（[force] 为 false 时，仍新鲜则直接返回缓存）
  Future<AiAccount> refresh(String providerId, {bool force = false}) {
    final running = _refreshing[providerId];
    if (running != null) return running;

    final future = _refresh(providerId, force: force).whenComplete(() {
      _refreshing.remove(providerId);
    });
    _refreshing[providerId] = future;
    return future;
  }

  Future<AiAccount> _refresh(String providerId, {required bool force}) async {
    final account = await sessionFor(providerId, forceReload: true);
    if (account == null) {
      throw RaccoonAuthRequiredException(providerId);
    }
    if (!force && !account.isStale(margin: refreshMargin) && !account.isExpired) {
      return account;
    }
    final refreshToken = account.refreshToken.trim();
    if (refreshToken.isEmpty) {
      await _markExpired(providerId);
      throw RaccoonAuthRequiredException(
        providerId,
        message: '小浣熊登录已过期且没有刷新凭证，请重新登录',
      );
    }

    try {
      final response = await _dio.post<dynamic>(
        '$authBase/refresh',
        data: {'refresh_token': refreshToken},
      );
      final access = _tokenFromResponse(response.data, 'access_token');
      final nextRefresh =
          _tokenFromResponse(response.data, 'refresh_token') ?? refreshToken;
      if (access == null || access.isEmpty) {
        throw const FormatException('刷新接口没有返回 access_token');
      }
      final next = await _accountFromTokens(
        providerId,
        access: access,
        refresh: nextRefresh,
        previous: account,
        fetchProfile: true,
      );
      await _save(next);
      LoggerService.instance.logAI(
        '小浣熊登录态已刷新: ${next.label}',
        details: '有效期至 ${next.expiresAt?.toIso8601String() ?? '未知'}',
      );
      return next;
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      LoggerService.instance.logAI(
        '小浣熊刷新登录态失败: HTTP $status',
        level: LogLevel.warning,
        details: '${e.response?.data ?? e.message}',
      );
      if (status != null && status >= 400 && status < 500) {
        await _markExpired(providerId);
        throw RaccoonAuthRequiredException(
          providerId,
          message: '小浣熊登录已失效，请重新登录',
        );
      }
      rethrow;
    }
  }

  /// 浏览器回环登录：返回句柄，由弹层打开 [RaccoonLoginHandle.url]
  Future<RaccoonLoginHandle> startBrowserLogin(String providerId) async {
    final loopback = await startRaccoonLoopbackLogin();
    final result = () async {
      final code = await loopback.code;
      return exchangeCode(providerId, code);
    }();
    return RaccoonLoginHandle(
      url: loopback.url,
      result: result,
      cancel: loopback.cancel,
    );
  }

  /// 授权码换 token
  Future<AiAccount> exchangeCode(String providerId, String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('授权码为空');
    }
    try {
      final response = await _dio.post<dynamic>(
        '$authBase/login_with_authorization_code',
        data: {'authorization_code': trimmed},
      );
      final access = _tokenFromResponse(response.data, 'access_token');
      final refresh = _tokenFromResponse(response.data, 'refresh_token');
      if (access == null || access.isEmpty || refresh == null) {
        throw FormatException(_vendorError(response.data, '换取登录凭证失败'));
      }
      final account = await _accountFromTokens(
        providerId,
        access: access,
        refresh: refresh,
        fetchProfile: true,
      );
      await _save(account);
      LoggerService.instance.logAI('小浣熊登录成功: ${account.label}');
      return account;
    } on DioException catch (e) {
      final payload = e.response?.data;
      if (payload is Map && '${payload['code']}' == '200035') {
        throw const FormatException('授权码已失效，请重新发起网页登录');
      }
      throw FormatException(_vendorError(payload, '换取登录凭证失败（HTTP ${e.response?.statusCode}）'));
    }
  }

  /// 手动兜底：粘贴完整回调链接、JWT，或 `{"access_token":...,"refresh_token":...}`
  Future<AiAccount> loginWithPastedInput(
    String providerId,
    String raw,
  ) async {
    final text = raw.trim();
    if (text.isEmpty) {
      throw const FormatException('请输入回调链接或 Token');
    }

    // JSON token pair
    if (text.startsWith('{')) {
      final decoded = jsonDecode(text);
      if (decoded is! Map) {
        throw const FormatException('JSON 格式不正确');
      }
      final access = (decoded['access_token'] ?? decoded['accessToken'])
          ?.toString()
          .trim();
      final refresh =
          (decoded['refresh_token'] ?? decoded['refreshToken'])?.toString().trim();
      if (access == null || access.isEmpty) {
        throw const FormatException('JSON 中缺少 access_token');
      }
      final account = await _accountFromTokens(
        providerId,
        access: _stripBearer(access),
        refresh: refresh ?? '',
        fetchProfile: true,
      );
      await _save(account);
      return account;
    }

    // 裸 JWT（没有 refresh token，到期后需要重新登录）
    if (text.split('.').length == 3 && !text.contains('://')) {
      final account = await _accountFromTokens(
        providerId,
        access: _stripBearer(text),
        refresh: '',
        fetchProfile: true,
      );
      await _save(account);
      return account;
    }

    // 回调链接：office-raccoon://auth/callback?code=... 或 http://127.0.0.1/...
    final uri = Uri.tryParse(text);
    if (uri == null) {
      throw const FormatException('无效的回调链接或 Token 格式');
    }
    final code = uri.queryParameters['code']?.trim() ?? '';
    if (code.isEmpty) {
      throw const FormatException('回调链接中缺少授权码 code');
    }
    return exchangeCode(providerId, code);
  }

  /// 拉取模型目录（[token] 为空时用匿名请求，部分账号的目录是公开的）
  Future<List<AiProviderModel>> fetchModels({String? token}) async {
    try {
      final response = await _dio.get<dynamic>(
        '$llmBase/model_catalog',
        options: Options(
          headers: {
            if (token != null && token.trim().isNotEmpty)
              'Authorization': 'Bearer ${_stripBearer(token)}',
          },
        ),
      );
      final models = _modelsFromCatalog(response.data);
      if (models.isEmpty) {
        throw const FormatException('模型目录为空');
      }
      return models;
    } on DioException catch (e) {
      throw FormatException(
        _vendorError(e.response?.data, '获取小浣熊模型目录失败（HTTP ${e.response?.statusCode}）'),
      );
    }
  }

  /// 带登录态的模型目录：401 时刷新一次再试
  Future<List<AiProviderModel>> fetchModelsForProvider(
    String providerId,
  ) async {
    final token = await requireAccessToken(providerId);
    try {
      return await fetchModels(token: token);
    } on FormatException {
      // 目录接口的 401 会以 FormatException 抛出：刷新一次再试
      final refreshed = await refresh(providerId, force: true);
      return fetchModels(token: refreshed.accessToken);
    }
  }

  Future<void> logout(String providerId) async {
    _cache.remove(providerId);
    await _repository.delete(providerId);
  }

  /// 数据管理页清空全部数据后清掉进程内缓存
  void clearCache() {
    _cache.clear();
  }

  Future<void> _save(AiAccount account) async {
    await _repository.upsert(account);
    _cache[account.providerId] = account;
  }

  Future<void> _markExpired(String providerId) async {
    final account = await sessionFor(providerId);
    if (account == null) return;
    final next = account.copyWith(
      status: AiAccount.statusExpired,
      updatedAt: DateTime.now(),
    );
    await _save(next);
  }

  Future<AiAccount> _accountFromTokens(
    String providerId, {
    required String access,
    required String refresh,
    AiAccount? previous,
    bool fetchProfile = false,
  }) async {
    final cleanAccess = _stripBearer(access);
    final claims = _decodeJwtClaims(cleanAccess);
    final now = DateTime.now();
    var phone = previous?.phone ?? '';
    if (fetchProfile) {
      final fetched = await _fetchPhone(cleanAccess);
      if (fetched.isNotEmpty) phone = fetched;
    }
    return AiAccount(
      providerId: providerId,
      kind: AiAccount.kindRaccoon,
      accessToken: cleanAccess,
      refreshToken: refresh.trim(),
      expiresAt: _jwtExpiry(claims),
      uid: _extractUid(claims),
      displayName: _extractName(claims),
      phone: phone,
      status: AiAccount.statusActive,
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
    );
  }

  /// 账号手机号（脱敏）：best effort，失败不影响登录
  Future<String> _fetchPhone(String access) async {
    try {
      final response = await _dio.get<dynamic>(
        '$authBase/user_info',
        options: Options(
          headers: {'Authorization': 'Bearer $access'},
          // 手机号只是卡片展示的加分项，不能拖慢登录/刷新
          receiveTimeout: const Duration(seconds: 8),
        ),
      );
      final data = response.data;
      if (data is Map) {
        final inner = data['data'];
        if (inner is Map) {
          return _maskPhone(inner['phone']?.toString() ?? '');
        }
        return _maskPhone(data['phone']?.toString() ?? '');
      }
      return '';
    } catch (_) {
      return '';
    }
  }

  static String? _tokenFromResponse(dynamic payload, String key) {
    if (payload is! Map) return null;
    final data = payload['data'] is Map ? payload['data'] as Map : payload;
    final value = data[key]?.toString().trim();
    if (value == null || value.isEmpty) return null;
    return _stripBearer(value);
  }

  static String _stripBearer(String value) {
    final trimmed = value.trim();
    if (trimmed.toLowerCase().startsWith('bearer ')) {
      return trimmed.substring(7).trim();
    }
    return trimmed;
  }

  static String _vendorError(dynamic payload, String fallback) {
    if (payload is Map) {
      for (final key in ['details', 'message', 'msg']) {
        final value = payload[key]?.toString().trim();
        if (value != null && value.isNotEmpty) return value;
      }
      final error = payload['error'];
      if (error is Map) {
        final message = error['message']?.toString().trim();
        if (message != null && message.isNotEmpty) return message;
      }
    }
    return fallback;
  }

  static List<AiProviderModel> _modelsFromCatalog(dynamic payload) {
    final root = payload is Map && payload['data'] is Map
        ? payload['data'] as Map
        : payload;
    if (root is! Map) return const [];
    final categories = root['categories'];
    final result = <AiProviderModel>[];
    final seen = <String>{};
    if (categories is List) {
      for (final category in categories) {
        if (category is! Map) continue;
        final models = category['models'];
        if (models is! List) continue;
        for (final entry in models) {
          if (entry is! Map) continue;
          final id = (entry['name'] ?? entry['model_name'])?.toString().trim();
          if (id == null || id.isEmpty || !seen.add(id)) continue;
          final rawName = (entry['display_name'] ?? entry['description'])
              ?.toString()
              .trim();
          final name = (rawName != null &&
                  rawName.isNotEmpty &&
                  rawName.length <= 64)
              ? rawName
              : id;
          result.add(AiProviderModel.of(id, name: name));
        }
      }
    }
    // 目录没列默认模型时补上，避免启用列表为空
    if (seen.add('raccoon-chat-ml-5-5')) {
      result.add(
        AiProviderModel.of('raccoon-chat-ml-5-5', name: 'Raccoon Chat (默认)'),
      );
    }
    return result;
  }

  static Map<String, dynamic>? _decodeJwtClaims(String token) {
    final parts = token.split('.');
    if (parts.length < 2 || parts[1].isEmpty) return null;
    try {
      final normalized = base64Url.normalize(parts[1]);
      final decoded = utf8.decode(base64Url.decode(normalized));
      final value = jsonDecode(decoded);
      return value is Map ? Map<String, dynamic>.from(value) : null;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _jwtExpiry(Map<String, dynamic>? claims) {
    final exp = claims?['exp'];
    final seconds = exp is num ? exp.toInt() : int.tryParse('${exp ?? ''}');
    if (seconds == null || seconds <= 0) return null;
    return DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  static String _extractUid(Map<String, dynamic>? claims) {
    if (claims == null) return '';
    for (final key in ['sid', 'iss']) {
      final decimal = _hexToDecimal(claims[key]?.toString() ?? '');
      if (decimal.isNotEmpty) return decimal;
    }
    for (final key in ['sub', 'id', 'user_id']) {
      final value = claims[key]?.toString().trim() ?? '';
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  static String _extractName(Map<String, dynamic>? claims) =>
      claims?['name']?.toString().trim() ?? '';

  static String _hexToDecimal(String value) {
    final raw = value.trim().replaceFirst(RegExp(r'^0x', caseSensitive: false), '');
    if (raw.isEmpty || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(raw)) return '';
    try {
      return BigInt.parse(raw, radix: 16).toString();
    } catch (_) {
      return '';
    }
  }

  static String _maskPhone(String raw) {
    var digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.startsWith('0086') && digits.length - 4 >= 7) {
      digits = digits.substring(4);
    } else if (digits.startsWith('86') && digits.length - 2 >= 7) {
      digits = digits.substring(2);
    }
    if (digits.length < 11) return '';
    return '${digits.substring(0, 3)}****${digits.substring(digits.length - 4)}';
  }

  // ── 测试用纯函数入口（不触库、不联网） ──────────────────

  @visibleForTesting
  static Map<String, dynamic>? decodeJwtForTest(String token) =>
      _decodeJwtClaims(_stripBearer(token));

  @visibleForTesting
  static DateTime? jwtExpiryForTest(String token) =>
      _jwtExpiry(_decodeJwtClaims(_stripBearer(token)));

  @visibleForTesting
  static String extractUidForTest(String token) =>
      _extractUid(_decodeJwtClaims(_stripBearer(token)));

  @visibleForTesting
  static List<AiProviderModel> modelsFromCatalogForTest(dynamic payload) =>
      _modelsFromCatalog(payload);

  @visibleForTesting
  static String maskPhoneForTest(String raw) => _maskPhone(raw);

  @visibleForTesting
  void resetForTest() {
    _cache.clear();
    _refreshing.clear();
    accessTokenLoaderForTest = null;
  }
}
