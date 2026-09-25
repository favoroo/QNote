import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/models/ai_config.dart';

/// 构造一份最小可用的模型配置（判定只看 modelName，其余字段占位）
AiConfig _config(String modelName) => AiConfig(
      id: 'cfg-$modelName',
      name: modelName,
      provider: 'openai',
      modelName: modelName,
      apiKey: 'sk-test',
      baseUrl: 'https://token.sensenova.cn/v1',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 能力判定全程是内存查表，**一次网络请求都不发**，所以这里不需要任何桩。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModelVisionCapability.resetForTest();
  });

  group('内置模型的实测结论', () {
    test('头牌 glm-5.2 不支持图片输入（实测收图不报错、直接编造）', () {
      expect(ModelVisionCapability.supportsVision(_config('glm-5.2')), isFalse);
    });

    test('识图链路与次选模型支持图片输入', () {
      expect(
        ModelVisionCapability.supportsVision(_config('sensenova-6.8-flash-lite')),
        isTrue,
      );
      expect(
        ModelVisionCapability.supportsVision(_config('deepseek-flash')),
        isTrue,
      );
    });

    test('大小写与首尾空格不影响判定（模型名常被模型端大小写混写）', () {
      expect(
        ModelVisionCapability.supportsVision(_config(' GLM-5.2 ')),
        isFalse,
      );
      expect(
        ModelVisionCapability.supportsVision(_config('SenseNova-6.8-Flash-Lite')),
        isTrue,
      );
    });
  });

  group('自定义模型', () {
    test('命中视觉命名线索即视为支持', () {
      for (final name in const [
        'gpt-4o',
        'qwen-vl-max',
        'llama-3.2-vision-11b',
        'gemini-2.5-pro',
        'claude-sonnet-4-6',
        'kimi-latest',
      ]) {
        expect(
          ModelVisionCapability.supportsVision(_config(name)),
          isTrue,
          reason: '$name 应被识别为支持图片输入',
        );
      }
    });

    test('判不准时按不支持处理（漏判只多一次工具调用，误判会让模型编造画面）', () {
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isFalse,
      );
      expect(ModelVisionCapability.supportsVision(_config('')), isFalse);
    });

    test('生图模型名不算支持图片输入', () {
      // sensenova-u1.5-lite 是文生图后端，收图只会报错，不能因为名字像就多模态对待
      expect(
        ModelVisionCapability.supportsVision(_config('sensenova-u1.5-lite')),
        isFalse,
      );
    });
  });

  group('手动检测结论的持久化', () {
    test('记录后立即生效，模拟重启后仍能读到', () async {
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isFalse,
      );

      await ModelVisionCapability.recordProbeResult('my-private-llm', true);
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isTrue,
      );

      // 只清内存镜像、保留磁盘值，等价于 App 重启后 loadFromPrefs 的起点
      await ModelVisionCapability.resetForTest(keepDisk: true);
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isFalse,
        reason: '内存镜像已清空，说明判定确实依赖预热',
      );

      await ModelVisionCapability.loadFromPrefs();
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isTrue,
      );
    });

    test('内置实测表优先于手动检测，误点也不会翻转内置模型的判定', () async {
      await ModelVisionCapability.recordProbeResult('glm-5.2', true);
      expect(
        ModelVisionCapability.supportsVision(_config('glm-5.2')),
        isFalse,
        reason: '内置结论由本仓实测掌控，不该被设备上一次点击改写',
      );
    });

    test('设置页徽标只在有真实结论时显示', () async {
      expect(ModelVisionCapability.probeConclusion('my-private-llm'), isNull);
      expect(
        ModelVisionCapability.probeConclusion('sensenova-6.8-flash-lite'),
        isTrue,
      );

      await ModelVisionCapability.recordProbeResult('my-private-llm', false);
      expect(
        ModelVisionCapability.probeConclusion('my-private-llm'),
        isFalse,
      );
      // 关键词命中只用于兜底判定，不构成「检测过」的事实，因此不显示徽标
      expect(ModelVisionCapability.probeConclusion('gpt-4o'), isNull);
    });
  });

  group('withVisionFallback', () {
    test('不发图时一律保持原配置', () {
      final roleConfig = _config('glm-5.2');
      final out = ModelVisionCapability.withVisionFallback(
        roleConfig,
        sendingImage: false,
      );
      expect(identical(out, roleConfig), isTrue);
    });

    test('发图且模型支持时保持原配置', () {
      final roleConfig = _config('deepseek-flash');
      final out = ModelVisionCapability.withVisionFallback(
        roleConfig,
        sendingImage: true,
      );
      expect(identical(out, roleConfig), isTrue);
    });

    test('发图而模型看不了时切到内置识图链路', () {
      final out = ModelVisionCapability.withVisionFallback(
        _config('glm-5.2'),
        sendingImage: true,
      );
      expect(out.modelName, 'sensenova-6.8-flash-lite');
      expect(out.baseUrl, 'https://token.sensenova.cn/v1');
      // 识图链路属内置池，必须保持 free_model 语义才走 Key 轮换
      expect(out.vendorId, 'free_model');
    });
  });
}
