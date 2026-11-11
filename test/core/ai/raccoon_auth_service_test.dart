import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/raccoon_auth_service.dart';

/// 小浣熊登录态的纯解析逻辑（不触库、不联网）
void main() {
  String jwt(Map<String, dynamic> claims) {
    String enc(dynamic value) => base64Url.encode(utf8.encode(jsonEncode(value))).replaceAll('=', '');
    return '${enc({'alg': 'none'})}.${enc(claims)}.sig';
  }

  test('JWT 解析出过期时间与账号 id（sid 十六进制转十进制）', () {
    final token = jwt({'sid': '0x1f', 'name': '张三', 'exp': 2000000000});

    final claims = RaccoonAuthService.decodeJwtForTest(token);
    expect(claims?['name'], '张三');
    expect(RaccoonAuthService.extractUidForTest(token), '31');
    expect(RaccoonAuthService.jwtExpiryForTest(token), DateTime.fromMillisecondsSinceEpoch(2000000000 * 1000));
  });

  test('JWT 没有 sid 时回落到 sub/id/user_id', () {
    expect(RaccoonAuthService.extractUidForTest(jwt({'sub': 'user-1'})), 'user-1');
    expect(RaccoonAuthService.extractUidForTest(jwt({'id': 42})), '42');
  });

  test('非法 token 不抛异常', () {
    expect(RaccoonAuthService.decodeJwtForTest('not-a-jwt'), isNull);
    expect(RaccoonAuthService.jwtExpiryForTest('not-a-jwt'), isNull);
    expect(RaccoonAuthService.extractUidForTest('not-a-jwt'), isEmpty);
  });

  test('手机号脱敏：+86 / 0086 / 裸号 / 太短', () {
    expect(RaccoonAuthService.maskPhoneForTest('+86 13800138000'), '138****8000');
    expect(RaccoonAuthService.maskPhoneForTest('0086-13800138000'), '138****8000');
    expect(RaccoonAuthService.maskPhoneForTest('13800138000'), '138****8000');
    expect(RaccoonAuthService.maskPhoneForTest('12345'), isEmpty);
  });

  test('模型目录按 categories/models 解析，保留展示名并去重', () {
    final models = RaccoonAuthService.modelsFromCatalogForTest({
      'data': {
        'categories': [
          {
            'models': [
              {'name': 'raccoon-8c4485', 'display_name': 'Raccoon-Work'},
              {'name': 'sn-glm-5-3', 'description': 'GLM-5-3'},
              {'name': 'raccoon-8c4485', 'display_name': '重复项'},
            ],
          },
        ],
      },
    });

    expect(models.map((m) => m.id), ['raccoon-8c4485', 'sn-glm-5-3', 'raccoon-chat-ml-5-5']);
    expect(models.first.name, 'Raccoon-Work');
    expect(models[1].name, 'GLM-5-3');
    expect(models.last.name, 'Raccoon Chat (默认)');
  });

  test('模型目录带出倍率、限免与上下文等计费信息', () {
    final models = RaccoonAuthService.modelsFromCatalogForTest({
      'data': {
        'categories': [
          {
            'models': [
              {
                'name': 'sn-sensenova-6-8-flash',
                'description': 'SenseNova-6.8-Flash',
                'tags': ['chat', 'vision'],
                'params': {'context_window': 256000, 'max_tokens': 63999},
                'billing_multiplier': 0.5,
                'billing_effective_multiplier': 0,
                'billing_status': 'limited_free',
                'billing_status_note': '限免至11月30日',
              },
              {
                'name': 'sn-glm-5-3-flash',
                'description': 'GLM-5-3-Flash',
                'tags': ['chat', 'fast'],
                'params': {'context_window': 1000000},
                'billing_multiplier': 0.2,
                'billing_effective_multiplier': 0.2,
              },
              {
                // 厂商没给计费字段：不能凭空标成免费或 1×
                'name': 'raccoon-8c4485',
                'display_name': 'Raccoon-Work',
              },
            ],
          },
        ],
      },
    });

    final free = models.firstWhere((m) => m.id == 'sn-sensenova-6-8-flash');
    expect(free.rate, 0);
    expect(free.rateWas, 0.5);
    expect(free.isFree, isTrue);
    expect(free.hasDiscount, isTrue);
    expect(free.contextWindow, 256000);
    expect(free.rateNote, '限免至11月30日');
    expect(free.supportsVision, isTrue);
    // 小浣熊目录目前只有对话模型，没有输出模态声明：生图标识保持未知
    expect(free.supportsImageGeneration, isNull);

    final cheap = models.firstWhere((m) => m.id == 'sn-glm-5-3-flash');
    expect(cheap.rate, 0.2);
    expect(cheap.rateWas, isNull);
    expect(cheap.isFree, isFalse);
    expect(cheap.hasDiscount, isFalse);
    expect(cheap.contextWindow, 1000000);
    expect(cheap.rateNote, isNull);
    // tags 里没有 vision：按厂商明确声明「不支持」处理
    expect(cheap.supportsVision, isFalse);

    final unknown = models.firstWhere((m) => m.id == 'raccoon-8c4485');
    expect(unknown.rate, isNull);
    expect(unknown.isFree, isFalse);
    expect(unknown.contextWindow, isNull);
    expect(unknown.supportsVision, isNull);
  });

  test('目录为空时至少给出默认模型，避免启用列表为空', () {
    final models = RaccoonAuthService.modelsFromCatalogForTest({});
    expect(models.single.id, 'raccoon-chat-ml-5-5');
    expect(models.single.rate, 1);
    expect(models.single.contextWindow, 180000);
  });
}
