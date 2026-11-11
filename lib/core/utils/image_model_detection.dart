/// 生图模型识别：先看厂商目录声明，没声明时按模型 ID 兜底推断
///
/// 判定口径对齐 magpie（`internal/catalog/catalog.go` 的 `DrawsID`）：厂商的
/// 模型目录里 `output_modalities` 含 `image`、或 `type` 为 `image` 时直接采用；
/// 目录没给这些字段（多数 OpenAI 兼容中转只回 `id`）时，按 ID 里的生图关键词
/// 推断。宁可漏标也不要把对话模型误标成「生图」。
library;

import 'package:qnote_flutter/models/ai_provider.dart';

/// 模型的生图判定：厂商声明优先，没声明（null）时按模型 ID 兜底
///
/// UI 与生图模型筛选都走这一个入口：老配置没有 `image_gen` 字段时也能
/// 靠模型名立刻识别出 `gpt-image-1`、`seedream` 这类模型，不必先重新扫描。
bool isImageGenerationModel(AiProviderModel model) =>
    model.supportsImageGeneration ?? looksLikeImageGenerationModel(model.id);

/// 厂商目录条目 → 是否生图模型；null 表示厂商没有声明，不能据此否定
///
/// 支持三种常见声明形态：
/// - Loomy：`type: "image"` + `capabilities.output_modalities: ["image"]`
/// - OpenAI/OpenRouter 中转：顶层 `output_modalities` 或 `modalities.output`
/// - 部分聚合站：`tags` 里写 `image-generation` / `text-to-image`
bool? imageGenerationFromCatalogEntry(Object? entry) {
  if (entry is! Map) return null;

  // 输出模态最权威：只要声明了输出，就按声明判定（[text] 即非生图）
  final caps = entry['capabilities'];
  final modalities = entry['modalities'];
  final outputs =
      (caps is Map ? caps['output_modalities'] : null) ??
      entry['output_modalities'] ??
      (modalities is Map ? modalities['output'] : null);
  if (outputs is List && outputs.isNotEmpty) {
    return outputs.any((item) => item.toString().trim().toLowerCase() == 'image');
  }

  final tags = entry['tags'];
  if (tags is List) {
    const imageTags = {'image-generation', 'image_generation', 'text-to-image', 'text_to_image'};
    final matched = tags.any((tag) => imageTags.contains(tag.toString().trim().toLowerCase()));
    if (matched) return true;
  }

  final type = (entry['type'] ?? entry['model_type'])?.toString().trim().toLowerCase();
  if (type == 'image' || type == 'image-generation' || type == 'image_generation') {
    return true;
  }
  if (type == 'chat' || type == 'text') return false;
  return null;
}

/// 模型 ID 是否像生图模型（目录没声明能力时的兜底）
///
/// 关键词表与 magpie 的 `catalog.DrawsID` 一致：`image` 覆盖 `gpt-image-1`、
/// `qwen-image`、`gemini-*-image` 等，其余覆盖主流生图家族。
bool looksLikeImageGenerationModel(String id) {
  final normalized = id.trim().toLowerCase();
  if (normalized.isEmpty) return false;
  const keywords = [
    'image',
    'imagen',
    'imagine',
    'dall-e',
    'flux',
    'seedream',
    'cogview',
    'stable-diffusion',
    'sdxl',
    'wanx',
    'kolors',
    'hidream',
    'banana',
  ];
  return keywords.any(normalized.contains);
}
