/// 时间线「小Q分析」的纯文本处理。
///
/// 小Q 智能提取会补充图片解读、营养/健康评估等「原文之外」的信息。这些内容
/// 统一存进 `DiaryRecord.aiAnalysis`，由时间线卡片的折叠区展示；旧数据则把
/// 图片解读以「图：」开头混在正文里，这里负责在展示时识别并剥离出来。
library;

/// 旧数据里 AI 图片解读的行首标记。
const _imageAnalysisPrefixes = ['图：', '图:'];

/// 模型偶尔仍会自带的小节标题。
const _analysisLabelPrefixes = ['小Q分析：', '小Q分析:'];

/// 判断一行正文是否是旧版 AI 分析（图片解读或自带「小Q分析：」标题）。
///
/// 只认行首标记：用户在正文中间写「图：」不应被误折叠。
bool isLegacyQAnalysisLine(String line) {
  final trimmed = line.trimLeft();
  for (final prefix in _imageAnalysisPrefixes) {
    if (trimmed.startsWith(prefix)) return true;
  }
  for (final prefix in _analysisLabelPrefixes) {
    if (trimmed.startsWith(prefix)) return true;
  }
  return false;
}

/// 从旧版正文行中取出分析文本；不是分析行返回 null。
///
/// 「图：」是展示语义的一部分，保留前缀；模型自带的「小Q分析：」标题则剥离，
/// 避免卡片上出现「小Q分析：小Q分析：」的重复标题。
String? extractLegacyQAnalysisLine(String line) {
  final trimmed = line.trim();
  if (trimmed.isEmpty || !isLegacyQAnalysisLine(trimmed)) return null;
  for (final prefix in _imageAnalysisPrefixes) {
    if (trimmed.startsWith(prefix)) return trimmed;
  }
  return _stripAnalysisLabel(trimmed);
}

/// 把一段分析文本按行拆开：去首尾空白、去空行、去重，并剥离小节标题。
List<String> splitQAnalysisLines(String? analysis) {
  final raw = analysis?.trim() ?? '';
  if (raw.isEmpty) return const [];

  final result = <String>[];
  final seen = <String>{};
  for (final line in raw.split(RegExp(r'[\r\n]+'))) {
    final normalized = _stripAnalysisLabel(line.trim());
    if (normalized.isEmpty) continue;
    final key = _dedupeKey(normalized);
    if (seen.add(key)) {
      result.add(normalized);
    }
  }
  return result;
}

/// 合并显式分析字段与旧版正文中识别出的分析行，按出现顺序去重。
List<String> mergeQAnalysisLines({String? analysis, Iterable<String> legacyLines = const []}) {
  final result = <String>[];
  final seen = <String>{};

  void add(String line) {
    final normalized = _stripAnalysisLabel(line.trim());
    if (normalized.isEmpty) return;
    if (seen.add(_dedupeKey(normalized))) {
      result.add(normalized);
    }
  }

  for (final line in splitQAnalysisLines(analysis)) {
    add(line);
  }
  for (final line in legacyLines) {
    add(line);
  }
  return result;
}

/// 统一分析文本的存储形态：去掉标题、空行与重复行。
String normalizeQAnalysisText(String? analysis) => splitQAnalysisLines(analysis).join('\n');

String _stripAnalysisLabel(String line) {
  var current = line.trim();
  // 模型可能重复输出标题（「小Q分析：小Q分析：…」），循环剥干净
  var changed = true;
  while (changed && current.isNotEmpty) {
    changed = false;
    for (final prefix in _analysisLabelPrefixes) {
      if (current.startsWith(prefix)) {
        current = current.substring(prefix.length).trim();
        changed = true;
        break;
      }
    }
    if (current == '小Q分析' || current == '分析') {
      current = '';
    }
  }
  return current;
}

/// 去重键：忽略空白与常见标点，避免「图：…，合计 620kcal」和
/// 「图：…, 合计 620kcal」被当成两条。
String _dedupeKey(String line) {
  return line.replaceAll(RegExp(r'[\s，,。.;；、:：!！?？]+'), '').toLowerCase();
}
