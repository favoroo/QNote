/// Anthropic Messages 协议适配（纯函数，无 UI / 无状态）
///
/// 与 OpenAI 兼容协议的差异集中在四处：端点（`/v1/messages`）、鉴权头
/// （`x-api-key` + 必需的 `anthropic-version`）、请求体（`system` 提到顶层、
/// 内容块用 `image` 而不是 `image_url`、`max_tokens` 必填）与流式事件
/// （`content_block_delta` 而非 `choices[].delta`）。这些差异全部收在本文件，
/// 发信层只在原有的 `provider == 'gemini'` 分支旁加一条同形分支，互不影响。
///
/// 刻意**不含工具调用**：Messages 的 `tools` / `tool_use` / `tool_result` 与流式
/// `input_json_delta` 是另一套状态机，本次按分阶段方案不做，由发信层降级为纯文本
/// 对话并显式提示用户（见 `AiService.chatStreamWithTools`）。
library;

import 'package:qnote_flutter/models/ai_token_usage.dart';

/// Messages 接口要求的版本头；Anthropic 不接受不带该头的请求
const String anthropicApiVersion = '2023-06-01';

/// 官方基址（厂商条目里留空时兜底，与 Gemini 的处理同口径）
const String anthropicDefaultBaseUrl = 'https://api.anthropic.com';

/// 思考强度 → `thinking.budget_tokens`（Anthropic 要求 ≥ 1024）
///
/// 档位语义与 `ReasoningEffort.wireName` 对齐；`none` 与未知档位返回 null，
/// 表示不发 `thinking`（关闭思考）。
const Map<String, int> anthropicThinkingBudgets = {
  'minimal': 1024,
  'low': 2048,
  'medium': 8192,
  'high': 24000,
  'xhigh': 32000,
  'max': 48000,
};

/// 基址归一化
///
/// 用户经常把完整端点（`…/v1/messages`）整个粘进来。Anthropic 与各家的
/// anthropic 兼容入口都以根地址为准（`ANTHROPIC_BASE_URL` 语义），因此这里
/// 去掉末尾的 `/v1/messages`、`/v1` 与多余斜杠，避免拼成 `…/v1/v1/messages`。
String anthropicBaseUrl(String raw) {
  var base = raw.trim().replaceAll(RegExp(r'[,\s]+$'), '');
  while (base.endsWith('/')) {
    base = base.substring(0, base.length - 1);
  }
  for (final suffix in const ['/v1/messages', '/v1/chat/completions', '/v1']) {
    if (base.endsWith(suffix)) {
      base = base.substring(0, base.length - suffix.length);
      break;
    }
  }
  return base;
}

/// 聊天端点（绝对地址，路由组换成员时也不会打错主机）
String anthropicChatEndpoint(String baseUrl) => '${anthropicBaseUrl(baseUrl)}/v1/messages';

/// 模型列表端点（Messages 的 `/v1/models`）
String anthropicModelsEndpoint(String baseUrl) => '${anthropicBaseUrl(baseUrl)}/v1/models';

/// 鉴权头：`x-api-key` + 版本头，并显式清掉 `Authorization`
///
/// 清 `Authorization` 是 Dio 的删除语义：同一把 [Dio] 实例在路由组切换成员时
/// 会残留上一家的 Bearer 头，两个凭证同时发出去会被 Anthropic 拒绝。
Map<String, dynamic> anthropicAuthHeaders(String key) => {
  'x-api-key': key,
  'anthropic-version': anthropicApiVersion,
  'Authorization': null,
};

/// OpenAI 形态的 messages → Messages 请求体
///
/// 输入沿用发信层的既有形态（`{role, content}`，content 可能是字符串，也可能是
/// 含 `text` / `image_url` 的块数组），这样各调用点不必为 anthropic 单独组装消息。
/// - `system` 角色被抽到顶层 `system` 字段：Messages 的 messages 只接受 user/assistant；
/// - `tool` 角色与未知块类型被丢弃：本次不支持工具调用，发出去反而会 400；
/// - `image_url` 的 data URL 转成 `image.source.base64`。
Map<String, dynamic> buildAnthropicBody({
  required String model,
  required List<dynamic> messages,
  double? temperature,
  int? maxTokens,
  bool stream = false,
  String? thinkingEffort,
}) {
  final systemParts = <String>[];
  final converted = <Map<String, dynamic>>[];

  for (final raw in messages) {
    if (raw is! Map) continue;
    final role = raw['role']?.toString() ?? '';
    if (role == 'system') {
      final text = _textOf(raw['content']);
      if (text.isNotEmpty) systemParts.add(text);
      continue;
    }
    if (role != 'user' && role != 'assistant') continue;
    final content = _contentBlocks(raw['content']);
    if (content == null) continue;
    converted.add({'role': role, 'content': content});
  }

  // max_tokens 是 Messages 的必填项；思考预算必须小于它，否则直接被 400 拒
  final budget = anthropicThinkingBudget(thinkingEffort);
  var effectiveMaxTokens = maxTokens ?? 4096;
  if (budget != null && effectiveMaxTokens <= budget) {
    effectiveMaxTokens = budget + 2048;
  }

  final body = <String, dynamic>{'model': model, 'messages': converted, 'max_tokens': effectiveMaxTokens};
  if (systemParts.isNotEmpty) body['system'] = systemParts.join('\n\n');
  if (temperature != null) body['temperature'] = temperature;
  if (stream) body['stream'] = true;
  if (budget != null) body['thinking'] = {'type': 'enabled', 'budget_tokens': budget};
  return body;
}

/// 思考预算；`none` 与未知档位返回 null（不发 `thinking`）
int? anthropicThinkingBudget(String? effort) {
  if (effort == null) return null;
  return anthropicThinkingBudgets[effort.trim().toLowerCase()];
}

/// 把 content 压成纯文本（system 提示词用）
String _textOf(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    final buffer = StringBuffer();
    for (final block in content) {
      if (block is Map && block['type'] == 'text') {
        buffer.write(block['text']?.toString() ?? '');
      } else if (block is String) {
        buffer.write(block);
      }
    }
    return buffer.toString();
  }
  return '';
}

/// 转换单条消息的 content；空内容返回 null（调用方丢弃整条消息）
dynamic _contentBlocks(dynamic content) {
  if (content is String) return content.trim().isEmpty ? null : content;
  if (content is! List) return null;

  final blocks = <Map<String, dynamic>>[];
  for (final block in content) {
    if (block is! Map) continue;
    switch (block['type']) {
      case 'text':
        final text = block['text']?.toString() ?? '';
        if (text.isNotEmpty) blocks.add({'type': 'text', 'text': text});
      case 'image_url':
        final image = _imageBlockFromDataUrl((block['image_url'] as Map?)?['url']?.toString());
        if (image != null) blocks.add(image);
    }
  }
  if (blocks.isEmpty) return null;
  // 只有一个文本块时退化成字符串：更贴近 Messages 的常见形态，也少一层嵌套
  if (blocks.length == 1 && blocks.first['type'] == 'text') return blocks.first['text'];
  return blocks;
}

/// `data:<mime>;base64,<data>` → `{type:'image', source:{...}}`
Map<String, dynamic>? _imageBlockFromDataUrl(String? url) {
  if (url == null || !url.startsWith('data:')) return null;
  final commaIndex = url.indexOf(',');
  if (commaIndex <= 0) return null;
  final header = url.substring(5, commaIndex);
  final data = url.substring(commaIndex + 1);
  if (data.isEmpty) return null;
  final mime = header.contains(';') ? header.split(';').first : header;
  return {
    'type': 'image',
    'source': {'type': 'base64', 'media_type': mime.isEmpty ? 'image/jpeg' : mime, 'data': data},
  };
}

/// 非流式响应取正文：拼接 `content[].text`（跳过 thinking 块）
String anthropicExtractText(Object? data) {
  if (data is! Map) return '';
  final content = data['content'];
  if (content is! List) return '';
  final buffer = StringBuffer();
  for (final block in content) {
    if (block is Map && block['type'] == 'text') {
      buffer.write(block['text']?.toString() ?? '');
    }
  }
  return buffer.toString();
}

/// 非流式响应里的结束原因（`max_tokens` 表示被截断，与 OpenAI 的 finish_reason 同口径）
String? anthropicExtractStopReason(Object? data) {
  if (data is! Map) return null;
  return data['stop_reason']?.toString();
}

/// 流式事件的正文增量（`content_block_delta` + `text_delta`）
String? anthropicStreamText(Map<String, dynamic> event) {
  if (event['type'] != 'content_block_delta') return null;
  final delta = event['delta'];
  if (delta is! Map || delta['type'] != 'text_delta') return null;
  final text = delta['text']?.toString() ?? '';
  return text.isEmpty ? null : text;
}

/// 流式事件的思考增量（`content_block_delta` + `thinking_delta`）
///
/// 与 OpenAI 兼容端点的 `reasoning_content` 同语义：界面用它滚动「思考中」。
String? anthropicStreamReasoning(Map<String, dynamic> event) {
  if (event['type'] != 'content_block_delta') return null;
  final delta = event['delta'];
  if (delta is! Map || delta['type'] != 'thinking_delta') return null;
  final text = delta['thinking']?.toString() ?? '';
  return text.isEmpty ? null : text;
}

/// 流式事件里的错误对象；非错误事件返回 null
///
/// Messages 的错误是 `event: error` + `data: {"type":"error","error":{...}}`，
/// 与 OpenAI 兼容端点在正常增量里塞 `error` 字段的形态不同。
String? anthropicStreamError(Map<String, dynamic> event) {
  if (event['type'] != 'error') return null;
  final error = event['error'];
  if (error is Map) {
    return (error['message'] ?? error['type'] ?? '未知错误').toString();
  }
  return error?.toString() ?? '未知错误';
}

/// 合并流式 usage：`message_start` 给输入 token，`message_delta` 给输出 token
///
/// 不能直接用 `AiTokenUsage.fromResponse`：它按「一帧里同时有输入与输出」解析，
/// 而 Messages 把两者拆在两帧，逐帧解析会先记下只有输入的一条、再被只有输出的
/// 一条覆盖，最终统计里输入量归零。
AiTokenUsage? mergeAnthropicUsage(Map<String, dynamic> event, AiTokenUsage? current) {
  int? input;
  int? output;
  final message = event['message'];
  if (message is Map) {
    final usage = message['usage'];
    if (usage is Map) {
      input = _intOf(usage['input_tokens']);
      output = _intOf(usage['output_tokens']);
    }
  }
  final usage = event['usage'];
  if (usage is Map) {
    input = _intOf(usage['input_tokens']) ?? input;
    output = _intOf(usage['output_tokens']) ?? output;
  }
  if (input == null && output == null) return current;

  final promptTokens = input ?? current?.promptTokens ?? 0;
  final completionTokens = output ?? current?.completionTokens ?? 0;
  if (promptTokens == 0 && completionTokens == 0) return current;
  return AiTokenUsage(
    promptTokens: promptTokens,
    completionTokens: completionTokens,
    totalTokens: promptTokens + completionTokens,
  );
}

/// `message_stop` 之后没有更多增量，可据此提前收尾
bool anthropicStreamFinished(Map<String, dynamic> event) => event['type'] == 'message_stop';

int? _intOf(Object? raw) {
  if (raw is int) return raw;
  if (raw is num) return raw.toInt();
  return int.tryParse(raw?.toString() ?? '');
}
