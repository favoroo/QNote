import 'package:qnote_flutter/models/chat_session.dart';

/// 聊天图片去重工具。
///
/// 生图结果在会话流里有两条渲染路径：`generate_image` 工具卡片（读 `uiDetails['paths']`）
/// 与 assistant 正文里的 markdown 图片语法（`![image](<路径>)`，模型按系统提示词回显工具
/// 返回的路径）。两者指向同一张图时会重复显示两次，因此在渲染正文前需要判定
/// 「这张图是否已由生图卡片展示过」。
///
/// `ChatMessage` 中只有 `role == 'tool'` 的消息携带 `toolCallId`，assistant 正文无法反查
/// 它引用的是哪一次工具调用，所以只能按「图片来源字符串」归一化后做集合匹配。

/// data URI 指纹取 base64 载荷的前多少个字符。
const int _dataUriFingerprintLength = 24;

/// 允许按前缀判重的最短载荷长度：前缀太短时命中任何同类型图片都可能误判。
const int _minDataUriPrefixLength = 12;

/// 归一化图片键，使「生图卡片里的路径」与「正文 markdown 的 src」产生同一可比结果。
///
/// - 文件路径（含 Windows 反斜杠与相对路径）统一取 basename：生图落盘为
///   `documents/images/ai/<uuid>.png`，文件名由 uuid 生成天然唯一，取 basename 即可
///   容忍绝对/相对路径与不同挂载前缀的差异；
/// - `data:` / `blob:` URI 没有 basename 语义，改用「媒体类型 + 载荷前缀」指纹。
String imageKeyOf(String raw) {
  final source = raw.trim();
  if (source.isEmpty) {
    return '';
  }
  if (source.startsWith('data:') || source.startsWith('blob:')) {
    final commaIndex = source.indexOf(',');
    if (commaIndex == -1) {
      return 'uri::$source';
    }
    final meta = source.substring(0, commaIndex);
    final payload = source.substring(commaIndex + 1);
    final head = payload.length <= _dataUriFingerprintLength
        ? payload
        : payload.substring(0, _dataUriFingerprintLength);
    return 'uri:$meta:$head';
  }
  final normalized = source.replaceAll('\\', '/');
  final baseName = normalized.substring(normalized.lastIndexOf('/') + 1);
  return baseName.isEmpty ? normalized : baseName;
}

/// 收集本会话内「已由生图卡片展示」的图片键集合，作为正文去重的判定依据。
///
/// 只收录 `generate_image` 且未失败的路径，因此正文里引用的其他图片（笔记已有图、
/// 用户上传附件）不会被误判为重复。
Set<String> collectGeneratedImageKeys(List<ChatMessage> messages) {
  final keys = <String>{};
  for (final message in messages) {
    if (message.role == 'tool_group') {
      // 生图工具已被排除出工具链聚合（保证卡片始终直出大图），这里仍兜底扫描成员，
      // 使去重结论不随聚合策略变化而失效
      final members = message.uiDetails?['messages'];
      if (members is List) {
        for (final member in members.whereType<ChatMessage>()) {
          keys.addAll(_generatedKeysOf(member));
        }
      }
      continue;
    }
    keys.addAll(_generatedKeysOf(message));
  }
  return keys;
}

/// 单条工具消息里的生图路径键（非生图或失败时为空）。
Iterable<String> _generatedKeysOf(ChatMessage message) {
  if (message.role != 'tool' || message.toolName != 'generate_image') {
    return const [];
  }
  if (message.isError == true) {
    return const [];
  }
  final paths =
      (message.uiDetails?['paths'] as List?)?.whereType<String>() ??
      const <String>[];
  return paths.map(imageKeyOf).where((key) => key.isNotEmpty);
}

/// 正文 markdown 图片是否已由生图卡片展示过（命中则正文不再重复渲染，只保留文字）。
bool isRedundantGeneratedImage(String src, Set<String> generatedKeys) {
  if (generatedKeys.isEmpty) {
    return false;
  }
  final key = imageKeyOf(src);
  if (key.isEmpty) {
    return false;
  }
  if (generatedKeys.contains(key)) {
    return true;
  }
  if (!key.startsWith('uri:')) {
    return false;
  }
  // 模型可能只回显了 data URI 的前半段：载荷前缀足够长时按前缀命中同一张图
  final payloadHead = key.substring(key.lastIndexOf(':') + 1);
  if (payloadHead.length < _minDataUriPrefixLength) {
    return false;
  }
  return generatedKeys.any((candidate) => candidate.startsWith(key));
}

/// markdown 图片语法：`![alt](<路径或 data URI>)`
final RegExp _imageMarkdownPattern = RegExp(r'!\[[^\]]*\]\(([^)\s]+)\)');

/// 从纯文本展示场景剥离「已由生图卡片展示」的图片语法。
///
/// 小Q 快捷面板的气泡用 `Text` 渲染正文（不解析 markdown），模型回显的
/// `![image](/…/uuid.png)` 会以原始标记文本的形式露出来；这里按与主页面一致的去重
/// 规则把它抹掉，只保留文字说明。
String stripRedundantImageMarkdown(String content, Set<String> generatedKeys) {
  if (generatedKeys.isEmpty || !content.contains('![')) {
    return content;
  }
  final keptLines = <String>[];
  for (final line in content.split('\n')) {
    final stripped = line.replaceAllMapped(_imageMarkdownPattern, (match) {
      final src = match.group(1) ?? '';
      return isRedundantGeneratedImage(src, generatedKeys)
          ? ''
          : match.group(0)!;
    });
    // 整行只有图片语法时剥离后变成空行，直接丢弃；原本的空行保留以维持段落间隔
    if (stripped.trim().isEmpty && line.trim().isNotEmpty) {
      continue;
    }
    keptLines.add(stripped);
  }
  return keptLines.join('\n');
}
