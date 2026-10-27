import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:qnote_flutter/core/ai/model_vision_capability.dart';
import 'package:qnote_flutter/models/ai_config.dart';

/// 构造一份最小可用的模型配置（判定只看 modelName，其余字段占位）
AiConfig _config(String modelName) => AiConfig(
      providerId: 'provider-1',
      name: modelName,
      provider: 'openai',
      modelName: modelName,
      apiKey: 'sk-test',
      baseUrl: 'https://gw.example.com/v1',
    );

/// 能力判定全程是内存查表，**一次网络请求都不发**，所以这里不需要任何桩。
///
/// 内置模型的实测白/黑名单已随内置模型下线：现在的结论只来自
/// ① 用户手动「识图检测」的持久化结果；② 模型名里的视觉关键词。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ModelVisionCapability.resetForTest();
  });

  group('模型名启发式', () {
    test('命中视觉命名线索即视为支持', () {
      for (final name in const [
        'gpt-4o',
        'qwen-vl-max',
        'gemini-2.5-pro',
        'claude-sonnet-4',
        'kimi-vision',
      ]) {
        expect(
          ModelVisionCapability.supportsVision(_config(name)),
          isTrue,
          reason: '$name 应命中视觉关键词',
        );
      }
    });

    test('没有线索的私有模型按不支持处理（宁可多问一次也不让它编造）', () {
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isFalse,
      );
    });

    test('生图模型名里的 image 不算识图线索', () {
      expect(
        ModelVisionCapability.supportsVision(_config('gpt-image-1')),
        isFalse,
      );
      expect(
        ModelVisionCapability.supportsVision(_config('dall-e-3')),
        isFalse,
      );
    });

    test('大小写与首尾空格不影响判定', () {
      expect(
        ModelVisionCapability.supportsVision(_config(' GPT-4O ')),
        isTrue,
      );
    });
  });

  group('手动检测结论', () {
    test('检测结论优先于关键词启发式', () async {
      await ModelVisionCapability.recordProbeResult('gpt-4o', false);
      expect(
        ModelVisionCapability.supportsVision(_config('gpt-4o')),
        isFalse,
      );

      await ModelVisionCapability.recordProbeResult('my-private-llm', true);
      expect(
        ModelVisionCapability.supportsVision(_config('my-private-llm')),
        isTrue,
      );
    });

    test('落盘后重启（清内存镜像再预热）仍保留结论', () async {
      await ModelVisionCapability.recordProbeResult('my-private-llm', true);

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

    test('设置页徽标只在有真实检测结论时显示', () async {
      expect(ModelVisionCapability.probeConclusion('my-private-llm'), isNull);

      await ModelVisionCapability.recordProbeResult('my-private-llm', false);
      expect(
        ModelVisionCapability.probeConclusion('my-private-llm'),
        isFalse,
      );
      // 关键词命中只用于兜底判定，不构成「检测过」的事实，因此不显示徽标
      expect(ModelVisionCapability.probeConclusion('gpt-4o'), isNull);
    });

    test('probedResult 只回答「是否检测过」', () async {
      expect(ModelVisionCapability.probedResult('gpt-4o'), isNull);
      await ModelVisionCapability.recordProbeResult('gpt-4o', true);
      expect(ModelVisionCapability.probedResult('gpt-4o'), isTrue);
    });
  });
}