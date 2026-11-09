import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/core/ai/vision_capability_probe.dart';
import 'package:qnote_flutter/models/ai_config.dart';

/// 构造一份最小可用的模型配置（探测只关心 modelName，其余字段占位）
AiConfig _config(String modelName) => AiConfig(
      providerId: 'provider-1',
      name: modelName,
      provider: 'openai',
      modelName: modelName,
      apiKey: 'sk-test',
      baseUrl: 'https://gw.example.com/v1',
    );

DioException _httpError(int statusCode, Object? data) {
  final options = RequestOptions(path: '/chat/completions');
  return DioException(
    requestOptions: options,
    response: Response<dynamic>(
      requestOptions: options,
      statusCode: statusCode,
      data: data,
    ),
    type: DioExceptionType.badResponse,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModelVisionCapability.resetForTest();
    VisionCapabilityProbe.resetForTest();
  });

  tearDown(VisionCapabilityProbe.resetForTest);

  group('能力已知时零请求', () {
    test('已有实测结论直接采用', () async {
      await ModelVisionCapability.recordProbeResult('my-private-llm', true);
      var calls = 0;
      VisionCapabilityProbe.checkerOverride = (_, _) async {
        calls++;
        return false;
      };

      expect(await VisionCapabilityProbe.ensure(_config('my-private-llm')), isTrue);
      expect(calls, 0, reason: '有结论就不该再发探测请求');
    });

    test('模型名命中视觉线索直接放行', () async {
      var calls = 0;
      VisionCapabilityProbe.checkerOverride = (_, _) async {
        calls++;
        return false;
      };

      expect(await VisionCapabilityProbe.ensure(_config('qwen-vl-max')), isTrue);
      expect(calls, 0, reason: '命名线索够用时不必花配额');
    });
  });

  group('能力未知时先实测再落盘', () {
    test('实测支持后落盘，后续不再探测', () async {
      var calls = 0;
      VisionCapabilityProbe.checkerOverride = (_, imageBase64) async {
        calls++;
        expect(imageBase64, isEmpty, reason: '测试桩路径不生成真实探测图');
        return true;
      };

      expect(await VisionCapabilityProbe.ensure(_config('my-private-llm')), isTrue);
      expect(calls, 1);
      expect(
        ModelVisionCapability.probedResult('my-private-llm'),
        isTrue,
        reason: '实测结论要落盘，下次进设置页/发图直接复用',
      );

      expect(await VisionCapabilityProbe.ensure(_config('my-private-llm')), isTrue);
      expect(calls, 1, reason: '已有结论时不应重复探测');
    });

    test('实测看不见时记为不支持，后续直接拦截', () async {
      VisionCapabilityProbe.checkerOverride = (_, _) async => false;

      expect(await VisionCapabilityProbe.ensure(_config('my-private-llm')), isFalse);
      expect(ModelVisionCapability.probedResult('my-private-llm'), isFalse);
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isFalse,
      );
    });

    test('并发探测合并为一次请求', () async {
      final completer = Completer<bool>();
      var calls = 0;
      VisionCapabilityProbe.checkerOverride = (_, _) {
        calls++;
        return completer.future;
      };

      final first = VisionCapabilityProbe.ensure(_config('my-private-llm'));
      final second = VisionCapabilityProbe.ensure(_config('my-private-llm'));
      expect(calls, 1);

      completer.complete(true);
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect(calls, 1);
    });
  });

  group('探测失败不误伤模型能力', () {
    test('网络/服务端故障时放行真实请求且不落盘', () async {
      VisionCapabilityProbe.checkerOverride = (_, _) async {
        throw _httpError(500, {'error': {'message': 'internal error'}});
      };

      expect(await VisionCapabilityProbe.ensure(_config('my-private-llm')), isTrue);
      expect(
        ModelVisionCapability.probedResult('my-private-llm'),
        isNull,
        reason: '一次请求失败不能证明模型看不见图',
      );
    });

    test('服务端明确拒绝图片输入时记为不支持', () async {
      VisionCapabilityProbe.checkerOverride = (_, _) async {
        throw _httpError(400, {
          'error': {'message': 'This model does not support image input'},
        });
      };

      expect(await VisionCapabilityProbe.ensure(_config('my-private-llm')), isFalse);
      expect(ModelVisionCapability.probedResult('my-private-llm'), isFalse);
    });

    test('400 与图片无关时不落盘', () async {
      VisionCapabilityProbe.checkerOverride = (_, _) async {
        throw _httpError(400, {
          'error': {'message': 'temperature is not supported'},
        });
      };

      expect(await VisionCapabilityProbe.ensure(_config('my-private-llm')), isTrue);
      expect(ModelVisionCapability.probedResult('my-private-llm'), isNull);
    });
  });

  test('探测图是合法 PNG', () async {
    final imageBase64 = await VisionCapabilityProbe.generateProbeImageBase64();
    final bytes = base64Decode(imageBase64);
    expect(
      bytes.take(8),
      [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
    );
  });
}
