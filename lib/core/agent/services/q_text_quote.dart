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

  const QTextQuote({
    required this.source,
    required this.sourceId,
    required this.sourceTitle,
    required this.quotedText,
    this.locationDesc,
  });
}
