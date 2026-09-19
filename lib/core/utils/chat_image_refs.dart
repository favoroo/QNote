import 'dart:convert';

import 'package:qnote_flutter/core/utils/chat_image_dedupe.dart';
import 'package:qnote_flutter/models/chat_session.dart';

/// 聊天会话的图片引用解析工具。
///
/// 小Q 生成的图片落盘在 `<appDocs>/images/ai/<uuid>.png`（见
/// `GenerateImageTool._subfolder` 与 `ImageRepository.saveBase64Image`），文件名是
/// 随机 uuid、**与会话 ID 没有任何关联**，因此删除会话时只能靠「消息里出现过的路径」
/// 反查这条对话到底占用了哪些磁盘文件。
///
/// 归一化统一复用 [imageKeyOf]（取其 basename），本文件不另造第二套 key 口径。

/// 匹配 messages JSON 里指向 `images/ai/` 的生成图片路径，捕获组为文件名。
///
/// 之所以直接对 messages 原始 JSON 文本做正则而不走 `jsonDecode`：
/// - 批量删除与保护集计算要扫描全表，解析数百会话的完整消息 JSON 明显更慢；
/// - 路径经 `jsonEncode` 后反斜杠会被转义成 `\\`，`[\\/]{1,2}` 可一次兼容
///   正斜杠、Windows 反斜杠与 JSON 转义三种形态。
final RegExp kChatAiImagePattern = RegExp(
  r'images[\\/]{1,2}ai[\\/]{1,2}([0-9A-Za-z_.-]+\.(?:png|jpe?g|webp|gif))',
  caseSensitive: false,
);

/// 从 messages 列原始文本中抽取生成图片文件名集合。
///
/// 返回值统一为小写 basename：uuid v4 生成的文件名本就是小写，归一后可安全用于
/// 「文件名集合比对」，且调用方只会拿它去匹配**目录实际列出的文件**，
/// 不会用来拼路径（避免消息内容里的 `../` 之类文本影响文件系统操作）。
Set<String> extractChatAiImageKeys(String? messagesJson) {
  final keys = <String>{};
  if (messagesJson == null || messagesJson.isEmpty) {
    return keys;
  }
  for (final match in kChatAiImagePattern.allMatches(messagesJson)) {
    final name = match.group(1);
    if (name != null && name.isNotEmpty) {
      keys.add(name.toLowerCase());
    }
  }
  return keys;
}

/// 会话内引用了的生成图片文件名（基于已反序列化的消息对象）。
Set<String> sessionAiImageKeys(ChatSession session) {
  return extractChatAiImageKeys(
    jsonEncode(session.messages.map((m) => m.toMap()).toList()),
  );
}

/// markdown 图片语法：`![alt](<路径或 data URI>)`
///
/// `chat_image_dedupe` 里的同名正则为私有，这里按「引用来源识别」的独立关注点保留一份，
/// 归一化结论仍由 [imageKeyOf] 提供，不产生第二套 key 口径。
final RegExp _markdownImagePattern = RegExp(r'!\[[^\]]*\]\(([^)\s]+)\)');

/// 单条消息里所有「可能指向图片」的原始引用。
///
/// 三个来源缺一不可：用户附件在 `images`、生图卡片在 `uiDetails['paths']`、
/// 模型按提示词回显的路径在正文 markdown 里（同 [imageKeyOf] 的归一前提）。
Iterable<String> messageImageSources(ChatMessage message) sync* {
  for (final raw in message.images ?? const <String>[]) {
    yield raw;
  }
  final details = message.uiDetails;
  if (details != null) {
    final paths =
        (details['paths'] as List?)?.whereType<String>() ?? const <String>[];
    for (final path in paths) {
      yield path;
    }
    final members = details['messages'];
    if (members is List) {
      for (final member in members) {
        if (member is ChatMessage) {
          yield* messageImageSources(member);
        } else if (member is Map) {
          // tool_group 成员从库里读出时可能仍是原始 Map，退化为 JSON 文本扫描，
          // 保证生图卡片里的路径不会因为没反序列化而漏计
          final encoded = jsonEncode(member);
          yield* extractChatAiImageKeys(encoded);
        }
      }
    }
  }
  for (final match in _markdownImagePattern.allMatches(message.content)) {
    final src = match.group(1);
    if (src != null && src.isNotEmpty) {
      yield src;
    }
  }
}

/// 会话里用户可见的图片数量（含内联 data URI、网络外链与相册附件）。
///
/// 仅用于删除确认文案的「共 N 张图片」，与「实际可删文件数」口径不同：前者是用户认知里
/// 这张对话有多少图，后者只有落在 `images/ai/` 且无其它引用的文件才算。
int countSessionImageRefs(ChatSession session) {
  return countImageRefsInMessages(session.messages);
}

/// 已反序列化消息列表里的可见图片数量。
int countImageRefsInMessages(List<ChatMessage> messages) {
  final keys = <String>{};
  for (final message in messages) {
    for (final raw in messageImageSources(message)) {
      final key = imageKeyOf(raw);
      if (key.isNotEmpty) {
        keys.add(key);
      }
    }
  }
  return keys.length;
}

/// 直接解析 messages 列原始 JSON，一次得到消息条数与可见图片数。
///
/// repository 层只有列文本、没有 `ChatSession` 对象（补齐时间字段反而更绕），
/// 故在此收敛解析与容错：JSON 损坏时按 0 计，不影响删除主流程。
({int messageCount, int imageRefCount}) summarizeMessageRefs(String? messagesJson) {
  if (messagesJson == null || messagesJson.isEmpty) {
    return (messageCount: 0, imageRefCount: 0);
  }
  try {
    final decoded = jsonDecode(messagesJson);
    if (decoded is! List) {
      return (messageCount: 0, imageRefCount: 0);
    }
    final messages = decoded
        .whereType<Map<String, dynamic>>()
        .map((m) => ChatMessage.fromMap(m))
        .toList();
    return (
      messageCount: messages.length,
      imageRefCount: countImageRefsInMessages(messages),
    );
  } catch (_) {
    return (messageCount: 0, imageRefCount: 0);
  }
}
