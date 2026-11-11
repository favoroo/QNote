import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_meta_badges.dart';

/// 模型元数据徽标的顺序与「不编数据」口径
void main() {
  test('限免模型：免费 + 原价 + 上下文', () {
    final model = AiProviderModel.of(
      'sn-sensenova-6-8-flash',
      rate: 0,
      rateWas: 0.5,
      contextWindow: 256000,
      supportsVision: true,
    );

    expect(modelMetaBadges(model), ['免费', '原 0.5×', '256K', '识图']);
  });

  test('付费模型：只给倍率与上下文，不出现「原价」', () {
    final model = AiProviderModel.of('sn-glm-5-3-flash', rate: 0.2, contextWindow: 1000000);

    expect(modelMetaBadges(model), ['0.2×', '1M']);
  });

  test('生图模型：徽标排在上下文之后、识图之前', () {
    final model = AiProviderModel.of('qwen-image-3.0-pro', contextWindow: 128000, supportsImageGeneration: true);

    expect(modelMetaBadges(model), ['128K', '生图']);
  });

  test('厂商没给元数据时一个徽标都不出（不默认成 1× 或免费）', () {
    final model = AiProviderModel.of('m', name: 'm');

    expect(modelMetaBadges(model), isEmpty);
  });
}
