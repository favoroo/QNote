/// 「给小Q」引用的内容来源类型
enum QQuoteSource {
  /// 笔记（编辑器选中文本或列表整篇引用）
  note,

  /// 时间线流水记录
  diary,

  /// 每日日记
  journal,

  /// 待办
  todo,

  /// 外部内容（第三方应用分享/划词传入的文字，无应用内 VFS 来源实体）
  external,

  /// 对话内容（从小Q对话面板消息中引用的文本片段）
  chat,
}

/// 用户通过「给小Q」引用给小Q的内容片段（含来源实体与位置描述）。
///
/// 挂起在 FloatingQState.pendingQuote 中随面板展示为引用卡片，
/// 用户发送指令时一次性消费：作为动态上下文注入（不污染消息原文），
/// 小Q据此用 VFS 文件工具精确定位并操作来源内容。
///
/// 编辑页还可通过 QTargetBridge 的 quoteSelection 钩子实时捕获框选内容，
/// 实现"框选状态下点悬浮球即引用"的入口。
class QTextQuote {
  /// 内容来源类型
  final QQuoteSource source;

  /// 来源实体 id：笔记 id / 时间线记录 id / 日期字符串（YYYY-MM-DD）/ 待办 id
  final String sourceId;

  /// 来源标题（面板卡片展示）
  final String sourceTitle;

  /// 引用的文本内容（编辑器选中文本，或实体内容摘录）
  final String quotedText;

  /// 位置描述（如「第 3 行附近」「09-12 17:52」），列表级引用可为 null
  final String? locationDesc;

  /// 网页预览中选中元素/文字的 DOM 信息（仅 HTML 笔记预览来源有值）。
  /// 注入上下文时附带给小Q，便于按选择器与 outerHTML 精确定位源码片段
  final QWebElementRef? webElement;

  const QTextQuote({
    required this.source,
    required this.sourceId,
    required this.sourceTitle,
    required this.quotedText,
    this.locationDesc,
    this.webElement,
  });
}

/// 引用来源的展示文案：悬浮面板与 /ai 页面的引用卡片共用同一套口径，
/// 避免两处各写一份 switch 后文案走样。
extension QTextQuoteDisplay on QTextQuote {
  /// 来源标签（UI 文案，与提示词里的「时间线记录」等措辞区分）
  String get sourceLabel => switch (source) {
    QQuoteSource.note => '笔记',
    QQuoteSource.diary => '流水记录',
    QQuoteSource.journal => '每日日记',
    QQuoteSource.todo => '待办',
    QQuoteSource.external => '外部分享',
    QQuoteSource.chat => '对话内容',
  };

  /// 卡片标题行：日记来源为日期字符串不加书名号，其余《标题》+ 位置；
  /// 外部分享与对话内容无实体标题，只展示来源标签
  String get cardTitleLine {
    final label = sourceLabel;
    if (source == QQuoteSource.external || source == QQuoteSource.chat) {
      return label;
    }
    final title = source == QQuoteSource.journal ? '$label $sourceTitle' : '$label《$sourceTitle》';
    final location = locationDesc;
    return location == null ? title : '$title · $location';
  }

  /// 引用正文的兜底文案：空文本时区分「光标处」与「整篇引用」
  String get cardBodyText {
    final text = quotedText.trim();
    if (text.isNotEmpty) return text;
    return locationDesc?.contains('光标') == true ? '（光标处，可让小Q续写或编辑）' : '（引用完整内容）';
  }
}

/// 网页预览中被选中的元素/文字在渲染后的 DOM 信息。
///
/// 由预览内注入的选择探针采集：CSS 选择器、标签/id/class、outerHTML、
/// 渲染文本、视口位置与父级路径。小Q 据此结合源码行号候选定位到
/// HTML 笔记中的具体片段，而不是重写整页。
class QWebElementRef {
  /// 元素在渲染后 DOM 中的 CSS 路径（如 `main > section.card:nth-of-type(2)`）
  final String selector;

  /// 标签名（小写，如 `section`）
  final String tagName;

  /// 元素 id（无则为 null）
  final String? elementId;

  /// 元素 class 列表（最多截断若干项）
  final List<String> classNames;

  /// 渲染后 DOM 序列化的 outerHTML（可能被截断；与源码格式存在差异）
  final String? outerHtml;

  /// 选中文字（文字选区时为选区内容；元素选择时为元素 innerText 摘录）
  final String? renderedText;

  /// 父级路径（如 `body > main > section.card`）
  final String? ancestors;

  /// 元素/选区在视口中的位置（CSS 像素，滚动前的 viewport 坐标）
  final QWebRect? rect;

  /// 采集时的视口尺寸
  final QWebRect? viewport;

  /// 采集时页面地址（如 `https://note-12.qnote.local/`）
  final String? url;

  /// 按标签/id/class 在 HTML 源码中匹配到的候选行号（1 基，最多若干条）
  final List<int> sourceLines;

  /// 选中文字在源码中出现的候选行号（1 基，最多若干条）
  final List<int> textLines;

  const QWebElementRef({
    required this.selector,
    required this.tagName,
    this.elementId,
    this.classNames = const [],
    this.outerHtml,
    this.renderedText,
    this.ancestors,
    this.rect,
    this.viewport,
    this.url,
    this.sourceLines = const [],
    this.textLines = const [],
  });
}

/// 网页元素/选区的矩形信息（CSS 像素）
class QWebRect {
  final double x;
  final double y;
  final double width;
  final double height;

  const QWebRect({required this.x, required this.y, required this.width, required this.height});
}
