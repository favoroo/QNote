import 'package:qnote_flutter/core/utils/model_meta_format.dart';
import 'package:qnote_flutter/models/ai_provider.dart';

/// 模型元数据徽标文案：免费 / 倍率 / 原价 / 上下文 / 识图
///
/// 模型列表与选择器共用同一份口径与顺序，避免「免费」在一处叫法、另一处漏掉。
/// 厂商没给的项不出现——宁可少一个徽标，也不要编一个错的倍率出来。
List<String> modelMetaBadges(AiProviderModel model) {
  final badges = <String>[];
  final rateText = formatRate(model.rate);
  if (model.isFree) {
    badges.add('免费');
  } else if (rateText != null) {
    badges.add(rateText);
  }
  final wasText = model.hasDiscount ? formatRate(model.rateWas) : null;
  if (wasText != null) badges.add('原 $wasText');
  final contextText = formatContextWindow(model.contextWindow);
  if (contextText != null) badges.add(contextText);
  if (model.supportsVision == true) badges.add('识图');
  return badges;
}
