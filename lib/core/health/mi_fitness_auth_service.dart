import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/health/mi_fitness_crypto.dart';

final miFitnessAuthServiceProvider = Provider<MiFitnessAuthService>((ref) {
  return MiFitnessAuthService();
});

/// 小米登录凭据结构体
class MiAuthCredentials {
  final String userId;
  final String serviceToken;
  final String ssecurity;
  final String? cUserId;
  final String? passToken;
  final DateTime expireTime;

  MiAuthCredentials({
    required this.userId,
    required this.serviceToken,
    required this.ssecurity,
    this.cUserId,
    this.passToken,
    required this.expireTime,
  });

  bool get isExpired => DateTime.now().isAfter(expireTime.subtract(const Duration(hours: 1)));

  Map<String, dynamic> toMap() => {
        'userId': userId,
        'serviceToken': serviceToken,
        'ssecurity': ssecurity,
        'cUserId': cUserId,
        'passToken': passToken,
        'expireTime': expireTime.toIso8601String(),
      };

  factory MiAuthCredentials.fromMap(Map<String, dynamic> map) => MiAuthCredentials(
        userId: map['userId'] as String? ?? '',
        serviceToken: map['serviceToken'] as String? ?? '',
        ssecurity: map['ssecurity'] as String? ?? '',
        cUserId: map['cUserId'] as String?,
        passToken: map['passToken'] as String?,
        expireTime: DateTime.tryParse(map['expireTime'] as String? ?? '') ??
            DateTime.now().add(const Duration(days: 30)),
      );
}

/// 扫码登录会话状态
class MiQrLoginSession {
  final String loginUrl;
  final String lp;
  final String qrCodeUrl;

  MiQrLoginSession({
    required this.loginUrl,
    required this.lp,
    required this.qrCodeUrl,
  });
}

/// 小米登录态相关的**确定性**失败（凭据被服务端拒绝、账号服务回业务错误码），
/// 与网络抖动区分开：只有 [needsRelogin] 为 true 才表示必须重新扫码授权。
class MiFitnessAuthException implements Exception {
  MiFitnessAuthException(this.message, {this.needsRelogin = false});

  final String message;
  final bool needsRelogin;

  @override
  String toString() => message;
}

/// passport 登录响应解析结果（扫码长轮询与 passToken 免密续期共用同一套字段规则）
class MiPassportLogin {
  const MiPassportLogin({
    this.code = -1,
    this.securityStatus = 0,
    this.userId = '',
    this.cUserId = '',
    this.passToken = '',
    this.ssecurity = '',
    this.nonce,
    this.location = '',
  });

  final int code;

  /// 非 0 表示小米要求安全确认（notification），此时凭据本身可能仍然有效
  final int securityStatus;
  final String userId;
  final String cUserId;
  final String passToken;
  final String ssecurity;

  /// clientSign 要用它原文拼串（JSON 里是数字，pragma 里可能是字符串），故保留原始类型
  final Object? nonce;
  final String location;

  /// 换取 serviceToken 所需的三要素是否齐全
  bool get hasStsInputs => ssecurity.isNotEmpty && nonce != null && location.isNotEmpty;
}

/// 扫码等待状态
enum MiQrPollStatus {
  waiting,
  scanned,
  success,
  expired,
  failed,
}

class MiQrPollResult {
  final MiQrPollStatus status;
  final MiAuthCredentials? credentials;
  final String? errorMsg;

  MiQrPollResult({
    required this.status,
    this.credentials,
    this.errorMsg,
  });
}

/// 小米运动健康鉴权服务
class MiFitnessAuthService {
  static const String _prefKey = 'mi_fitness_auth_credentials';
  static const String sid = 'miothealth'; // 小米运动健康专用统一业务 sid
  static const String accountBase = 'https://account.xiaomi.com';

  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 15),
    receiveTimeout: const Duration(seconds: 15),
    // passport 系接口一律按纯文本收，再用 parsePassportResponse 剥壳，理由见该方法注释。
    responseType: ResponseType.plain,
    headers: {
      'User-Agent':
          'APP/com.xiaomi.wearable APPV/2.12.0 iosPassportSDK/3.9.0 iOS/17.4',
    },
  ));

  MiAuthCredentials? _cachedCredentials;

  /// 解析 passport 系接口的响应体
  ///
  /// 小米为防 JSON 劫持，会在正文外包一层 `&&&START&&&` / `&&&END&&&`，而 passport 接口
  /// 又把 Content-Type 标成 `application/json`——交给 Dio 默认的 JSON transformer 会在
  /// offset 0 直接抛 FormatException（历史踩坑：静默刷新登录态因此从来没成功过一次，
  /// serviceToken 一过期就再也拿不到数据）。扫码与续期两条链路都走这里剥壳。
  static Map<String, dynamic> parsePassportResponse(dynamic body) {
    var text = body == null ? '' : (body is String ? body : body.toString());
    text = text.trim();
    const prefix = '&&&START&&&';
    const suffix = '&&&END&&&';
    if (text.startsWith(prefix)) text = text.substring(prefix.length);
    if (text.endsWith(suffix)) {
      text = text.substring(0, text.length - suffix.length);
    }
    text = text.trim();

    final decoded = json.decode(text);
    if (decoded is! Map<String, dynamic>) {
      throw FormatException('小米 passport 响应不是 JSON 对象', text);
    }
    return decoded;
  }

  /// 从 Set-Cookie 头里精确取某个 cookie 的值
  ///
  /// 必须比对完整名字：健康票据的 cookie 名是 `miothealth_serviceToken`，用宽松的
  /// `serviceToken=` 子串匹配会顺带命中它（名字前缀被吃掉），一旦服务端同时下发
  /// `serviceToken`（账号域票据）就会取错值。Dio 把每条 cookie 放在 list 的一个元素里，
  /// 但同一元素仍可能挤多条，故按 `;`/`,` 边界逐段匹配。
  static String? findCookie(List<String>? setCookieHeaders, String name) {
    final pattern = RegExp('(?:^|[;,\\s])${RegExp.escape(name)}=([^;,\\s]*)');
    for (final header in setCookieHeaders ?? const <String>[]) {
      final value = pattern.firstMatch(header)?.group(1);
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  /// 解析响应头 `Extension-Pragma`：passport 在个别链路上把 ssecurity/nonce 放在这里
  /// 而非 JSON 正文，只读 JSON 会判成「响应不完整」。
  static Map<String, dynamic> parseExtensionPragma(List<String>? pragmaHeaders) {
    final raw = (pragmaHeaders == null || pragmaHeaders.isEmpty) ? null : pragmaHeaders.first;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = json.decode(raw);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }

  /// 解析 passport 登录响应，字段优先级与官方 APK 的 `processLoginContent` 一致
  ///
  /// `userId`/`passToken`/`cUserId` 依次取 JSON → 响应 Cookie → 本地已有值：服务端会
  /// **轮换** passToken，而轮换值有时只走 Set-Cookie，只读 JSON 会让旧 token 被一直用
  /// 到失效。`ssecurity`/`nonce` 依次取 JSON → Extension-Pragma 头。
  static MiPassportLogin parsePassportLogin(
    Map<String, dynamic> json, {
    List<String>? setCookieHeaders,
    Map<String, dynamic> pragma = const {},
    MiAuthCredentials? known,
  }) {
    String pick(String name, String? stored) {
      final fromJson = json[name]?.toString() ?? '';
      if (fromJson.isNotEmpty) return fromJson;
      final fromCookie = findCookie(setCookieHeaders, name);
      if (fromCookie != null && fromCookie.isNotEmpty) return fromCookie;
      return stored ?? '';
    }

    final jsonSsecurity = json['ssecurity']?.toString() ?? '';
    final pragmaSsecurity = pragma['ssecurity']?.toString() ?? '';
    return MiPassportLogin(
      code: (json['code'] as num?)?.toInt() ?? -1,
      securityStatus: (json['securityStatus'] as num?)?.toInt() ?? 0,
      userId: pick('userId', known?.userId),
      cUserId: pick('cUserId', known?.cUserId),
      passToken: pick('passToken', known?.passToken),
      ssecurity: jsonSsecurity.isNotEmpty ? jsonSsecurity : pragmaSsecurity,
      nonce: json['nonce'] ?? pragma['nonce'],
      location: json['location']?.toString() ?? '',
    );
  }

  /// 初始化并加载已存储凭据
  Future<MiAuthCredentials?> loadCredentials() async {
    if (_cachedCredentials != null) return _cachedCredentials;
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = json.decode(raw) as Map<String, dynamic>;
      _cachedCredentials = MiAuthCredentials.fromMap(map);
      return _cachedCredentials;
    } catch (e) {
      LoggerService.instance.warning('Failed to parse MiAuthCredentials: $e');
      return null;
    }
  }

  /// 保存凭据到本地安全存储
  Future<void> saveCredentials(MiAuthCredentials credentials) async {
    _cachedCredentials = credentials;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, json.encode(credentials.toMap()));
    LoggerService.instance.info('MiFitness credentials saved for user: ${credentials.userId}');
  }

  /// 清除凭据（注销授权）
  Future<void> clearCredentials() async {
    _cachedCredentials = null;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefKey);
    LoggerService.instance.info('MiFitness credentials cleared');
  }

  /// 创建扫码登录会话
  Future<MiQrLoginSession> createQrSession() async {
    final res = await _dio.get(
      '$accountBase/longPolling/loginUrl',
      queryParameters: {
        '_json': 'true',
        'sid': sid,
        'qs': '%3Fsid%3D$sid',
        '_locale': 'zh_CN',
      },
    );

    final jsonMap = parsePassportResponse(res.data);

    final loginUrl = jsonMap['loginUrl'] as String;
    final lp = jsonMap['lp'] as String;
    final qr = jsonMap['qr'] as String?;

    final qrUrl = (qr != null && qr.isNotEmpty) ? qr : loginUrl;

    return MiQrLoginSession(
      loginUrl: loginUrl,
      lp: lp,
      qrCodeUrl: qrUrl,
    );
  }

  /// 轮询长轮询接口查询用户扫码结果
  Future<MiQrPollResult> pollQrStatus(String lp) async {
    try {
      final res = await _dio.get(
        lp,
        queryParameters: {'_json': 'true'},
        options: Options(receiveTimeout: const Duration(seconds: 40)),
      );

      final jsonMap = parsePassportResponse(res.data);

      final code = jsonMap['code'] as int? ?? -1;

      if (code == 70016) {
        // 二维码已过期
        return MiQrPollResult(status: MiQrPollStatus.expired, errorMsg: '二维码已过期');
      } else if (code == 0) {
        // 扫码成功，拿到 passToken 与 location 重定向地址
        // passToken/userId/cUserId 在个别链路上只走 Set-Cookie，故统一走 parsePassportLogin
        final login = parsePassportLogin(
          jsonMap,
          setCookieHeaders: res.headers['set-cookie'],
        );
        final location = login.location;
        final ssecurity = login.ssecurity;
        final userId = login.userId;
        final cUserId = login.cUserId;
        final passToken = login.passToken;
        final nonce = login.nonce;

        if (location.isNotEmpty && nonce != null && ssecurity.isNotEmpty) {
          // 通过 location 换取真正的 serviceToken
          final creds = await _exchangeServiceToken(
            location: location,
            nonce: nonce,
            ssecurity: ssecurity,
            userId: userId,
            cUserId: cUserId,
            passToken: passToken,
          );
          if (creds != null) {
            await saveCredentials(creds);
            return MiQrPollResult(status: MiQrPollStatus.success, credentials: creds);
          }
        }

        // 若 location 直接包含了或没有单独返回 serviceToken，但有 ssecurity
        if (ssecurity.isNotEmpty && userId.isNotEmpty) {
          final creds = MiAuthCredentials(
            userId: userId,
            serviceToken: '',
            ssecurity: ssecurity,
            cUserId: cUserId,
            passToken: passToken,
            expireTime: DateTime.now().add(const Duration(days: 30)),
          );
          await saveCredentials(creds);
          return MiQrPollResult(status: MiQrPollStatus.success, credentials: creds);
        }

        return MiQrPollResult(status: MiQrPollStatus.failed, errorMsg: '未获取到完整安全凭证');
      } else {
        // 等待扫码中或其他中间状态 (如已扫描待确认)
        return MiQrPollResult(status: MiQrPollStatus.waiting);
      }
    } on DioException catch (e) {
      if (e.type == DioExceptionType.receiveTimeout) {
        // 单次长轮询超时属于正常，外部继续调用即可
        return MiQrPollResult(status: MiQrPollStatus.waiting);
      }
      return MiQrPollResult(status: MiQrPollStatus.failed, errorMsg: e.message);
    } catch (e) {
      return MiQrPollResult(status: MiQrPollStatus.failed, errorMsg: e.toString());
    }
  }

  /// 用 location 换 serviceToken
  ///
  /// 官方 APK 就是从**这一跳**的 `Set-Cookie` 里读票据、不跟随跳转（`findCookie` 已按
  /// 名字精确匹配），故这里保持 `followRedirects: false`；读取时优先取
  /// `<sid>_serviceToken`，再退回 `serviceToken`。
  Future<MiAuthCredentials?> _exchangeServiceToken({
    required String location,
    required dynamic nonce,
    required String ssecurity,
    required String userId,
    String? cUserId,
    String? passToken,
  }) async {
    try {
      final clientSign = MiFitnessCrypto.buildClientSign(nonce, ssecurity);
      // location 一定带 query（带 sign 参数），故直接追加；clientSign 已 URL 编码
      final url = '$location&clientSign=$clientSign';

      final res = await _dio.get(
        url,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      final cookies = res.headers['set-cookie'];
      final serviceToken = findCookie(cookies, '${sid}_serviceToken') ??
          findCookie(cookies, 'serviceToken') ??
          '';

      return MiAuthCredentials(
        userId: userId,
        serviceToken: serviceToken,
        ssecurity: ssecurity,
        cUserId: cUserId,
        passToken: passToken,
        expireTime: DateTime.now().add(const Duration(days: 30)),
      );
    } catch (e) {
      LoggerService.instance.warning('Failed to exchange serviceToken: $e');
      return null;
    }
  }

  /// 正在进行的静默刷新任务（并发去重：一次同步会拉多个指标，401 时只需刷新一次）
  Future<MiAuthCredentials>? _refreshing;

  /// 用 passToken 静默换取新的 serviceToken（无需重新扫码）。
  ///
  /// 成功返回新凭据（已保存到本地）；passToken 被服务端明确拒绝（code=70016）时清理
  /// 本地凭据。所有失败路径都抛 [MiFitnessAuthException]，`needsRelogin` 区分「凭据死了
  /// 要重新扫码」与「临时故障，下次再试」。
  Future<MiAuthCredentials> refreshServiceToken() {
    return _refreshing ??= _doRefreshServiceToken().whenComplete(() => _refreshing = null);
  }

  /// passToken 免密续期，复刻官方 App 的 `XMPassport.loginByPassToken`
  ///
  /// 必须走 `GET /pass/serviceLogin` 且把 passToken/userId 放进 **Cookie**：这是小米账号
  /// 服务认的免密链路（与扫码长轮询共用同一套响应解析）。历史实现用
  /// `POST /pass/serviceLoginAuth2` 把 passToken 当**表单字段**发，服务端回
  /// `code=70016 登录验证失败`，而当时把任意非 0 code 都当成凭据作废直接清本地凭据，
  /// 于是每次 serviceToken 过期都必然要求重新扫码。
  Future<MiAuthCredentials> _doRefreshServiceToken() async {
    final creds = await loadCredentials();
    if (creds == null || (creds.passToken ?? '').isEmpty || creds.userId.isEmpty) {
      throw MiFitnessAuthException(
        '本地缺少 passToken/userId，无法静默刷新小米登录态，请重新扫码授权',
        needsRelogin: true,
      );
    }

    Response res;
    try {
      res = await _dio.get(
        '$accountBase/pass/serviceLogin',
        queryParameters: {'sid': sid, '_json': 'true'},
        options: Options(
          headers: {
            'Cookie': 'userId=${creds.userId}; passToken=${creds.passToken}',
          },
          // 关闭自动重定向：passToken 失效时服务端会跳到登录页，以此区分「被拒绝」与「网络异常」
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );
    } catch (e) {
      throw MiFitnessAuthException('刷新小米登录态失败（请求异常）：$e');
    }

    // HTTP 非 200（3xx 跳登录页、5xx 账号服务故障）时凭据状态未知，保留本地凭据下次再试：
    // 旧实现在这里清凭据，一次服务端抖动就要用户重新扫码。
    if (res.statusCode != 200) {
      throw MiFitnessAuthException('刷新小米登录态失败：serviceLogin HTTP ${res.statusCode}');
    }

    Map<String, dynamic> jsonMap;
    try {
      jsonMap = parsePassportResponse(res.data);
    } catch (e) {
      throw MiFitnessAuthException('刷新小米登录态失败（响应无法解析）：$e');
    }

    final login = parsePassportLogin(
      jsonMap,
      setCookieHeaders: res.headers['set-cookie'],
      pragma: parseExtensionPragma(res.headers['extension-pragma']),
      known: creds,
    );

    // 70016 = 凭据无效，是唯一能确定 passToken 已死的错误码（与官方 App 的
    // InvalidCredentialException 对应）；其余 code 一律只报错、不动本地凭据
    if (login.code == 70016) {
      await clearCredentials();
      throw MiFitnessAuthException(
        '小米登录态已失效（passToken 被拒绝），请重新扫码授权',
        needsRelogin: true,
      );
    }
    if (login.code != 0) {
      throw MiFitnessAuthException('小米账号服务返回异常（code=${login.code}），本次未刷新登录态');
    }
    // 安全确认（notification）不是凭据作废，但后台无法静默完成，提示用户去小米端确认
    if (login.securityStatus != 0) {
      throw MiFitnessAuthException('小米账号要求安全确认，请在小米 App 中确认后重试');
    }
    if (!login.hasStsInputs) {
      throw MiFitnessAuthException('小米账号服务未返回完整登录凭证，本次未刷新登录态');
    }

    // 与扫码成功后的流程一致：通过 location 重定向换取新的 serviceToken
    final newCreds = await _exchangeServiceToken(
      location: login.location,
      nonce: login.nonce,
      ssecurity: login.ssecurity,
      userId: login.userId,
      cUserId: login.cUserId,
      // passToken 轮换值必须落盘：一直用旧值会到点失效，只有跟着服务端走才能长期免密
      passToken: login.passToken,
    );
    if (newCreds == null || newCreds.serviceToken.isEmpty) {
      throw MiFitnessAuthException('刷新小米登录态失败：未换取到新的 serviceToken，本次未刷新登录态');
    }

    // 必须落盘：否则下次冷启动读到的还是过期 serviceToken，每个指标都要先吃一次 401 再刷新
    await saveCredentials(newCreds);
    LoggerService.instance.info('MiFitness serviceToken refreshed silently via passToken');
    return newCreds;
  }
}
