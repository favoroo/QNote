/// 笔记编辑器的分段数据模型与 Markdown 互转纯函数。
///
/// 编辑器中的 Segment 实例持有 `TextEditingController` / `FocusNode`，
/// 与 Widget 生命周期强绑定，不能直接搬出 State；这里只保留可单测的
/// 纯数据形态，由 State 负责把数据实例化成自己的 Segment。
library;

/// 分段类型。
enum NoteSegmentType { text, image, link }

/// 一段笔记内容的值对象，只承载解析结果，不持有任何 UI 资源。
class NoteSegmentData {
  const NoteSegmentData._({required this.type, this.text = '', this.path = '', this.url, this.title});

  /// 纯文本段。
  const NoteSegmentData.text(String text) : this._(type: NoteSegmentType.text, text: text);

  /// 图片段；[path] 为图片本地路径或网络地址。
  const NoteSegmentData.image(String path) : this._(type: NoteSegmentType.image, path: path);

  /// 链接段；[title] 为空时按裸 URL 输出。
  const NoteSegmentData.link({required String url, String? title})
    : this._(type: NoteSegmentType.link, url: url, title: title);

  final NoteSegmentType type;

  /// 文本段内容，非文本段为空字符串。
  final String text;

  /// 图片段路径，非图片段为空字符串。
  final String path;

  /// 链接段 URL，非链接段为 null。
  final String? url;

  /// 链接段标题（Markdown 链接的方括号内容），裸 URL 为 null。
  final String? title;

  @override
  bool operator ==(Object other) {
    return other is NoteSegmentData &&
        other.type == type &&
        other.text == text &&
        other.path == path &&
        other.url == url &&
        other.title == title;
  }

  @override
  int get hashCode => Object.hash(type, text, path, url, title);

  @override
  String toString() =>
      'NoteSegmentData(type: $type, text: $text, path: $path, '
      'url: $url, title: $title)';
}

/// 行内链接切分结果。
class NoteInlineSplitResult {
  const NoteInlineSplitResult({required this.segments, required this.lastMatchIndex});

  /// 切分后的分段；可能以链接段结尾，调用方按需补一个空文本段。
  final List<NoteSegmentData> segments;

  /// 最后一个链接/URL 匹配所生成的分段下标；没有命中时为 -1。
  ///
  /// 历史行为：裸 URL 末尾若切出标点文本段，该下标指向标点文本段
  /// （而不是链接段），编辑器据此恢复焦点。
  final int lastMatchIndex;
}

/// 图片独占一行的匹配规则，与编辑器历史实现逐字一致。
final RegExp _imageLinePattern = RegExp(r'^!\[.*?\]\((.*?)\)$', multiLine: true);

/// 行内链接匹配规则：Markdown 链接优先，其次裸 URL。
///
/// 裸 URL 遇到空白、`()[]{}<>"` 或中文字符即截断。
final RegExp _linkPattern = RegExp(
  r'\[([^\]]+)\]\((https?:\/\/[^\s\)]+)\)|'
  r'(https?:\/\/[^\s\(\)\[\]\{\}<>"\u4e00-\u9fa5]+)',
);

/// 裸 URL 末尾需要剥离的 ASCII 标点。
final RegExp _trailingPunctuationPattern = RegExp(r'[\.\,\?\!\:\;]+$');

/// 把整篇 Markdown 文本解析为文本 / 图片 / 链接分段。
///
/// 支持的语法（与编辑器历史行为逐字一致）：
/// - 图片：独占一行的 `![任意说明](路径)`，整行匹配 `^!\[.*?\]\((.*?)\)$`；
///   说明文字被忽略，路径原样保留（可以含中文与 `)`，以行尾 `)` 为界）。
/// - 链接：`[标题](http(s)://...)`，URL 不能含空白与 `)`；
///   以及裸 `http(s)://` URL，遇到空白、`()[]{}<>"` 或中文即截断。
/// - 裸 URL 末尾的 ASCII 标点 `.,?!:;` 会被切成独立文本段。
///
/// 不支持：反斜杠转义、引用式链接、图片与文字同行、HTML 内联语法等。
///
/// 换行处理：图片前的文本去掉尾部空白，图片后的文本去掉开头空白，
/// 并吞掉图片行后的一个换行。结果保证至少一个文本段，且最后一段
/// 一定是文本段（便于编辑器继续输入）。
///
/// [plainCode] 为 true 时（html/svg/json/code 笔记）整篇作为单个文本段，
/// 不解析任何图片/链接语法。
List<NoteSegmentData> parseNoteSegments(String content, {bool plainCode = false}) {
  if (plainCode) {
    return <NoteSegmentData>[NoteSegmentData.text(content)];
  }

  final segments = <NoteSegmentData>[];
  var lastEnd = 0;

  for (final match in _imageLinePattern.allMatches(content)) {
    // 图片前的文本
    final textBefore = content.substring(lastEnd, match.start);
    final cleanText = textBefore.trimRight();
    if (cleanText.isEmpty) {
      segments.add(const NoteSegmentData.text(''));
    } else {
      segments.addAll(splitNoteTextByLinks(cleanText).segments);
    }

    // 图片段
    segments.add(NoteSegmentData.image(match.group(1) ?? ''));
    lastEnd = match.end;
    // 吞掉图片行后的一个换行
    if (lastEnd < content.length && content[lastEnd] == '\n') {
      lastEnd++;
    }
  }

  // 剩余的文本
  final remaining = content.substring(lastEnd).trimLeft();
  if (remaining.isEmpty) {
    segments.add(const NoteSegmentData.text(''));
  } else {
    segments.addAll(splitNoteTextByLinks(remaining).segments);
  }

  // 保证至少一个文本段，且最后一段是文本段
  if (segments.isEmpty) {
    segments.add(const NoteSegmentData.text(''));
  }
  if (segments.last.type != NoteSegmentType.text) {
    segments.add(const NoteSegmentData.text(''));
  }
  return segments;
}

/// 把一段纯文本按行内链接语法切分为文本 / 链接分段。
///
/// 规则与 [parseNoteSegments] 的链接部分一致，但不会解析图片语法；
/// 调用方通常传入图片切分后的纯文本块。返回结果的
/// [NoteInlineSplitResult.lastMatchIndex] 供编辑器拆分后恢复焦点。
NoteInlineSplitResult splitNoteTextByLinks(String text) {
  final segments = <NoteSegmentData>[];
  var lastMatchIndex = -1;
  var lastEnd = 0;

  for (final match in _linkPattern.allMatches(text)) {
    final textBefore = text.substring(lastEnd, match.start);
    if (textBefore.isNotEmpty) {
      segments.add(NoteSegmentData.text(textBefore));
    }

    final markdownTitle = match.group(1);
    if (markdownTitle != null) {
      segments.add(NoteSegmentData.link(url: match.group(2)!, title: markdownTitle));
    } else {
      var url = match.group(3)!;
      final punctuationMatch = _trailingPunctuationPattern.firstMatch(url);
      var punctuation = '';
      if (punctuationMatch != null) {
        punctuation = punctuationMatch.group(0)!;
        url = url.substring(0, url.length - punctuation.length);
      }

      segments.add(NoteSegmentData.link(url: url));
      if (punctuation.isNotEmpty) {
        segments.add(NoteSegmentData.text(punctuation));
      }
    }

    lastMatchIndex = segments.length - 1;
    lastEnd = match.end;
  }

  final remaining = text.substring(lastEnd);
  if (remaining.isNotEmpty) {
    segments.add(NoteSegmentData.text(remaining));
  }

  return NoteInlineSplitResult(segments: segments, lastMatchIndex: lastMatchIndex);
}

/// 文本中是否存在可识别的行内链接（Markdown 链接或裸 URL）。
///
/// 编辑器在失焦/换行时先做一次廉价判断，未命中就不重建分段。
bool hasNoteLinks(String text) => _linkPattern.hasMatch(text);

/// 把分段列表还原为 Markdown 文本。
///
/// 输出规则（与编辑器历史实现逐字一致）：
/// - 文本段原样输出，非最后一段补一个 `\n`；空文本段不输出。
/// - 图片段输出 `![image](path)\n`（统一用 `image` 作说明文字）。
/// - 链接段有标题时输出 `[title](url)\n`，否则输出 `url\n`。
///
/// 注意：该格式不保证与任意原文逐字节往返——图片/链接总带尾换行，
/// 图片两侧的空行会被折叠；编辑器只依赖同一批分段序列化结果稳定。
String serializeNoteSegments(List<NoteSegmentData> segments) {
  final buffer = StringBuffer();
  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    switch (segment.type) {
      case NoteSegmentType.text:
        if (segment.text.isNotEmpty) {
          buffer.write(segment.text);
          if (i < segments.length - 1) {
            buffer.write('\n');
          }
        }
        break;
      case NoteSegmentType.image:
        buffer.write('![image](${segment.path})\n');
        break;
      case NoteSegmentType.link:
        final title = segment.title;
        if (title != null && title.isNotEmpty) {
          buffer.write('[$title](${segment.url})\n');
        } else {
          buffer.write('${segment.url}\n');
        }
        break;
    }
  }
  return buffer.toString();
}

/// 按分段顺序提取图片路径。
///
/// 与编辑器写入 `note.images` 的历史行为一致：不做去重，重复图片按出现顺序保留。
List<String> extractImagePaths(List<NoteSegmentData> segments) {
  final paths = <String>[];
  for (final segment in segments) {
    if (segment.type == NoteSegmentType.image) {
      paths.add(segment.path);
    }
  }
  return paths;
}

/// 标题入库口径：空标题统一存成「无标题」，比较与写入必须走同一个函数。
String normalizeNoteTitle(String raw) => raw.isEmpty ? '无标题' : raw;

/// 合并相邻文本段时的拼接规则：前一段以换行结尾则直接相接，否则补一个换行。
String mergeNoteText(String previous, String current) =>
    previous.endsWith('\n') ? '$previous$current' : '$previous\n$current';

/// 按顺序比较两个分段列表的值是否完全一致。
bool noteSegmentsEqual(List<NoteSegmentData> a, List<NoteSegmentData> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}

/// 简单的 `List<String>` 相等比较（顺序敏感），避免引入新依赖。
bool stringListsEqual(List<String> a, List<String> b) {
  if (identical(a, b)) {
    return true;
  }
  if (a.length != b.length) {
    return false;
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      return false;
    }
  }
  return true;
}
