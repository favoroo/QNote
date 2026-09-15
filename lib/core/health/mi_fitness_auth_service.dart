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
    headers: {
      'User-Agent':
          'APP/com.xiaomi.wearable APPV/2.12.0 iosPassportSDK/3.9.0 iOS/17.4',
    },
  ));

  MiAuthCredentials? _cachedCredentials;

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

    // 小米接口通常返回 "&&&START&&&{"code":0,...}"
    final bodyStr = res.data.toString();
    final jsonStr = bodyStr.replaceFirst('&&&START&&&', '').trim();
    final jsonMap = json.decode(jsonStr) as Map<String, dynamic>;

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

      final bodyStr = res.data.toString();
      final jsonStr = bodyStr.replaceFirst('&&&START&&&', '').trim();
      final jsonMap = json.decode(jsonStr) as Map<String, dynamic>;

      final code = jsonMap['code'] as int? ?? -1;

      if (code == 70016) {
        // 二维码已过期
        return MiQrPollResult(status: MiQrPollStatus.expired, errorMsg: '二维码已过期');
      } else if (code == 0) {
        // 扫码成功，拿到 passToken 与 location 重定向地址
        final location = jsonMap['location'] as String? ?? '';
        final ssecurity = jsonMap['ssecurity'] as String? ?? '';
        final userId = jsonMap['userId']?.toString() ?? '';
        final cUserId = jsonMap['cUserId'] as String?;
        final passToken = jsonMap['passToken'] as String?;
        final nonce = jsonMap['nonce'];

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

  /// 换取 serviceToken
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
      final url = '$location&clientSign=$clientSign';

      final res = await _dio.get(
        url,
        options: Options(
          followRedirects: false,
          validateStatus: (status) => status != null && status < 500,
        ),
      );

      String serviceToken = '';
      // 从 Set-Cookie 中提取 serviceToken
      final cookies = res.headers['set-cookie'] ?? [];
      for (final cookie in cookies) {
        if (cookie.contains('serviceToken=')) {
          final match = RegExp(r'serviceToken=([^;]+)').firstMatch(cookie);
          if (match != null) {
            serviceToken = match.group(1) ?? '';
            break;
          }
        }
      }

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
}
