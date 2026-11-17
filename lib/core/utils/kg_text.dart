import 'dart:convert';

import 'package:crypto/crypto.dart';

/// 知识图谱文本工具：归一化、分词、摘要、相似度。
///
/// 这些函数不依赖 Flutter/Riverpod，便于单测；图谱建库、实体消歧和查询打分
/// 共用同一套规则，避免「建库时归一化、查询时不归一化」导致匹配不上。

/// 图谱实体名归一化：全角转半角、Latin 小写、去标点与空白。
///
/// 中文本身不做分词或繁简转换——过度归一化会把「苹果（食物）」和「苹果（公司）」
/// 这类同名不同义的实体合并；类型维度由调用方另行校验。
String normalizeKgName(String input) {
  final buffer = StringBuffer();
  for (final rune in input.trim().runes) {
    final char = String.fromCharCode(rune);
    final code = rune;
    // 全角 ASCII（！-～）转半角；只保留字母/数字，全角标点直接丢弃。
    // 注意先转半角再小写：全角大写字母（Ａ）转出来仍是 A。
    if (code >= 0xFF01 && code <= 0xFF5E) {
      final half = String.fromCharCode(code - 0xFEE0).toLowerCase();
      if (RegExp(r'[a-z0-9]').hasMatch(half)) buffer.write(half);
      continue;
    }
    if (code == 0x3000) continue; // 全角空格
    final lower = char.toLowerCase();
    // 保留中日韩、字母、数字；其余（标点/空白/emoji）折叠掉
    if (RegExp(r'[\u4e00-\u9fff\u3400-\u4dbf\u3040-\u30ff\uac00-\ud7afA-Za-z0-9]').hasMatch(lower)) {
      buffer.write(lower);
    }
  }
  return buffer.toString();
}

/// 稳定的日期键（YYYY-MM-DD），使用本地时区
String kgDateKey(DateTime date) {
  final local = date.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${local.month.toString().padLeft(2, '0')}-'
      '${local.day.toString().padLeft(2, '0')}';
}

/// 解析 YYYY-MM-DD，失败返回 null
DateTime? kgParseDateKey(String? raw) {
  if (raw == null || raw.trim().isEmpty) return null;
  return DateTime.tryParse(raw.trim());
}

/// 内容 hash：增量索引判断源文档是否变化。
///
/// 只对参与抽取的字段做规范 JSON 后 hash，不含 `updated_at` 等元数据，
/// 避免同步/重新保存产生的无意义时间戳变化触发全量重跑。
String kgContentHash(Object? payload) {
  final text = payload is String ? payload : jsonEncode(payload);
  return sha256.convert(utf8.encode(text)).toString();
}

/// 把多行文本压成适合回显/证据的单行摘要。
String kgSnippet(String text, {int maxLength = 80, String? query}) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.isEmpty) return '';
  final keyword = (query ?? '').trim();
  if (keyword.isNotEmpty) {
    final index = flat.toLowerCase().indexOf(keyword.toLowerCase());
    if (index >= 0) {
      final start = (index - maxLength ~/ 3).clamp(0, flat.length);
      final end = (start + maxLength).clamp(0, flat.length);
      final prefix = start > 0 ? '…' : '';
      final suffix = end < flat.length ? '…' : '';
      return '$prefix${flat.substring(start, end)}$suffix';
    }
  }
  return flat.length > maxLength ? '${flat.substring(0, maxLength)}…' : flat;
}

/// 查询分词：Latin 单词 + 中文二元组/整段。
///
/// 不引入 jieba 等词典依赖；个人图谱的实体名通常较短，二元组 + 整段
/// 已足够命中「睡眠不足」「头痛」「珍珠奶茶」这类词。
List<String> kgTokenize(String query) {
  final text = query.trim().toLowerCase();
  if (text.isEmpty) return const [];

  final terms = <String>{};
  final latin = RegExp(r'[a-z0-9][a-z0-9._+-]*');
  for (final match in latin.allMatches(text)) {
    final token = match.group(0)!;
    if (token.length >= 2 && !_kgStopwords.contains(token)) {
      terms.add(token);
    }
  }

  final cjkRuns = RegExp(r'[\u4e00-\u9fff\u3400-\u4dbf]+').allMatches(text);
  for (final run in cjkRuns) {
    final runText = run.group(0)!;
    if (runText.length <= 6 && !_kgStopwords.contains(runText)) {
      terms.add(runText);
    }
    for (var i = 0; i + 1 < runText.length; i++) {
      final bigram = runText.substring(i, i + 2);
      if (!_kgStopwords.contains(bigram)) {
        terms.add(bigram);
      }
    }
    // 三字词也补一份，避免「睡眠不足」被拆成两个二元组后丢失整体语义
    for (var i = 0; i + 2 < runText.length; i++) {
      terms.add(runText.substring(i, i + 3));
    }
  }

  // 按长度降序，长词优先匹配
  final result = terms.where((t) => t.trim().isNotEmpty).toList()
    ..sort((a, b) {
      final byLength = b.length.compareTo(a.length);
      return byLength != 0 ? byLength : a.compareTo(b);
    });
  return result;
}

/// Levenshtein 编辑距离，供保守消歧使用。
int kgEditDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;

  var previous = List<int>.generate(b.length + 1, (i) => i);
  var current = List<int>.filled(b.length + 1, 0);
  for (var i = 1; i <= a.length; i++) {
    current[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      final insertion = current[j - 1] + 1;
      final deletion = previous[j] + 1;
      final substitution = previous[j - 1] + cost;
      var min = insertion < deletion ? insertion : deletion;
      if (substitution < min) min = substitution;
      current[j] = min;
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[b.length];
}

/// 归一化后的相似度（0~1），用于实体消歧阈值判断。
double kgSimilarity(String a, String b) {
  if (a == b) return 1;
  if (a.isEmpty || b.isEmpty) return 0;
  final maxLength = a.length > b.length ? a.length : b.length;
  return 1 - kgEditDistance(a, b) / maxLength;
}

/// 提取文本中的数字串（去前导零），消歧时数字不同绝不合并。
List<String> kgNumberTokens(String text) {
  final numbers = <String>{};
  for (final match in RegExp(r'\d+').allMatches(text)) {
    final raw = match.group(0)!;
    final normalized = raw.replaceFirst(RegExp(r'^0+(?=\d)'), '');
    if (normalized.isNotEmpty) numbers.add(normalized);
  }
  final sorted = numbers.toList()..sort();
  return sorted;
}

/// 去掉 markdown 标题/列表/引用前缀，便于实体名与摘要输出
String kgStripMarkdownPrefix(String line) {
  return line
      .replaceFirst(RegExp(r'^\s{0,3}#{1,6}\s*'), '')
      .replaceFirst(RegExp(r'^\s*[-*+]\s+'), '')
      .replaceFirst(RegExp(r'^\s*>\s?'), '')
      .trim();
}

const Set<String> _kgStopwords = {
  '的',
  '了',
  '是',
  '在',
  '和',
  '与',
  '及',
  '我',
  '你',
  '他',
  '她',
  '它',
  '我们',
  '你们',
  '他们',
  '这',
  '那',
  '这个',
  '那个',
  '这些',
  '那些',
  '有',
  '没有',
  '就',
  '都',
  '也',
  '很',
  '太',
  '更',
  '最',
  '吗',
  '呢',
  '吧',
  '啊',
  '呀',
  '哦',
  '嗯',
  '什么',
  '怎么',
  '为什么',
  '如何',
  '哪些',
  '哪个',
  '最近',
  '一下',
  '感觉',
  '今天',
  '昨天',
  '明天',
  '现在',
  '然后',
  '还是',
  '可以',
  '可能',
  '应该',
  '需要',
  '一个',
  '一些',
  '有点',
  '比较',
  '非常',
  '已经',
  '正在',
  '因为',
  '所以',
  '但是',
  '而且',
  '如果',
  '时候',
  '东西',
  '事情',
  '问题',
  '方面',
  '情况',
  'the',
  'a',
  'an',
  'and',
  'or',
  'of',
  'to',
  'in',
  'on',
  'for',
  'with',
  'is',
  'are',
  'was',
  'were',
  'be',
  'been',
  'this',
  'that',
  'these',
  'those',
  'what',
  'why',
  'how',
  'when',
  'where',
  'which',
  'who',
  'i',
  'you',
  'he',
  'she',
  'it',
  'we',
  'they',
  'my',
  'your',
  'our',
  'their',
  'me',
  'us',
  'them',
};
