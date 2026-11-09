import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/image_model_detection.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

/// 生图模型识别：厂商声明优先、ID 关键词兜底
void main() {
  group('imageGenerationFromCatalogEntry', () {
    test('Loomy 形态：type=image + capabilities.output_modalities 含 image', () {
      expect(
        imageGenerationFromCatalogEntry({
          'id': 'doubao-seedream-5-lite',
          'type': 'image',
          'capabilities': {
            'output_modalities': ['image'],
            'input_modalities': ['text', 'image'],
          },
        }),
        isTrue,
      );
    });

    test('输出模态只有 text：明确不是生图，返回 false 而不是未知', () {
      expect(
        imageGenerationFromCatalogEntry({
          'id': 'GLM-5.3-Flash',
          'type': 'chat',
          'capabilities': {
            'vision': true,
            'output_modalities': ['text'],
          },
        }),
        isFalse,
      );
    });

    test('顶层 output_modalities / modalities.output 也能识别', () {
      expect(
        imageGenerationFromCatalogEntry({
          'id': 'flux-1.1-pro',
          'output_modalities': ['image'],
        }),
        isTrue,
      );
      expect(
        imageGenerationFromCatalogEntry({
          'id': 'gpt-image-1',
          'modalities': {
            'output': ['image'],
          },
        }),
        isTrue,
      );
    });

    test('tags 里的生图标签', () {
      expect(
        imageGenerationFromCatalogEntry({
          'tags': ['general', 'image-generation'],
        }),
        isTrue,
      );
      // vision 是图片输入，不能当成生图
      expect(
        imageGenerationFromCatalogEntry({
          'tags': ['general', 'vision'],
        }),
        isNull,
      );
    });

    test('什么声明都没有时返回 null，交给调用方决定（不猜）', () {
      expect(imageGenerationFromCatalogEntry({'name': 'raccoon-090dd3'}), isNull);
      expect(imageGenerationFromCatalogEntry(null), isNull);
    });
  });

  group('looksLikeImageGenerationModel', () {
    test('主流生图模型命名命中', () {
      for (final id in [
        'gpt-image-1',
        'dall-e-3',
        'flux-1.1-pro',
        'doubao-seedream-5-lite',
        'qwen-image-3.0-pro',
        'cogview-4',
        'stable-diffusion-xl',
        'wanx-v1',
        'kolors',
        'hunyuan-hidream',
        'gemini-2.5-flash-image',
        'nano-banana',
        'imagen-4.0',
      ]) {
        expect(looksLikeImageGenerationModel(id), isTrue, reason: id);
      }
    });

    test('对话 / 向量 / 语音模型不会被误判', () {
      for (final id in [
        'GLM-5.3-Flash',
        'deepseek-v4-flash',
        'gpt-4o',
        'text-embedding-3-large',
        'whisper-1',
        'auto',
      ]) {
        expect(looksLikeImageGenerationModel(id), isFalse, reason: id);
      }
    });

    test('大小写与空串', () {
      expect(looksLikeImageGenerationModel('GPT-IMAGE-1'), isTrue);
      expect(looksLikeImageGenerationModel('  '), isFalse);
    });
  });

  group('isImageGenerationModel', () {
    test('厂商声明优先；没声明时按 ID 兜底', () {
      // 老配置没有 image_gen 字段，靠模型名也能立刻识别
      expect(isImageGenerationModel(AiProviderModel.of('gpt-image-1')), isTrue);
      expect(isImageGenerationModel(AiProviderModel.of('gpt-4o')), isFalse);
      expect(
        isImageGenerationModel(
          AiProviderModel.of('flux-1.1-pro', supportsImageGeneration: false),
        ),
        isFalse,
      );
      expect(
        isImageGenerationModel(
          AiProviderModel.of('my-relay-drawer', supportsImageGeneration: true),
        ),
        isTrue,
      );
    });
  });
}