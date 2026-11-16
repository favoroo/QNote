/// CSV 预览的列宽估算、数值列判定与 TSV 编码纯逻辑。
///
/// 不依赖 BuildContext / Theme / 平台 API，便于在 `test/core/utils` 下直接单测。
library;

/// 估算一段文本的自然宽度。
///
/// 以正文字号为基准：CJK、假名、韩文与全角标点按 [cjkWidth] 计，
/// ASCII 与常见半角字符按 [latinWidth] 计。文本包含换行时取最宽的一行，
/// 因为单元格里的换行会真正换行，不能把各行宽度相加。
double estimatedTextWidth(String text, {double cjkWidth = 13, double latinWidth = 7.2}) {
  if (text.isEmpty) {
    return 0;
  }
  var widest = 0.0;
  var current = 0.0;
  for (final rune in text.runes) {
    if (rune == 0x0A) {
      if (current > widest) {
        widest = current;
      }
      current = 0;
      continue;
    }
    if (rune == 0x0D) {
      continue;
    }
    if (rune == 0x09) {
      // 制表符按 4 个半角字符估算，避免含 tab 的单元格被严重低估
      current += latinWidth * 4;
      continue;
    }
    current += _isWideRune(rune) ? cjkWidth : latinWidth;
  }
  return current > widest ? current : widest;
}

/// 估算每一列的初始宽度。
///
/// [rows] 的第一行视为表头，其余行参与采样；[sampleRows] 限制表体采样行数，
/// 避免大文件每次预览都全量扫描。返回长度固定为 [columnCount]，每列宽度
/// 夹在 [minWidth] 与 [maxWidth] 之间；空列回落到 [minWidth]。
///
/// 单个单元格明显宽于同列其余内容时按次宽取值，防止一行超长文本把整列
/// 撑到上限；完整内容由自动换行与单元格详情兜底。
List<double> computeCsvColumnWidths({
  required List<List<String>> rows,
  required int columnCount,
  double minWidth = 72,
  double maxWidth = 320,
  int sampleRows = 80,
}) {
  if (columnCount <= 0) {
    return const [];
  }
  final lower = minWidth < 0 ? 0.0 : minWidth;
  final upper = maxWidth < lower ? lower : maxWidth;
  final header = rows.isEmpty ? const <String>[] : rows.first;
  final bodyRows = rows.length <= 1 ? const <List<String>>[] : rows.skip(1).take(sampleRows < 0 ? 0 : sampleRows);

  // 与表格单元格的左右内边距（各 12）保持一致，并额外留 16px 余量：
  // 字体真实度量下大写字母/数字常比 7.2 的均值估算更宽（再加上 M3 的
  // letterSpacing），留一点余量避免「EMP-10023」这类标识刚好被挤成两行。
  // 表头再给排序箭头留一点位置。
  const horizontalPadding = 40.0;
  const headerExtra = 18.0;

  final widths = <double>[];
  for (var column = 0; column < columnCount; column++) {
    final headerText = column < header.length ? header[column].trim() : '';
    final headerWidth = headerText.isEmpty ? 0.0 : estimatedTextWidth(headerText) + horizontalPadding + headerExtra;

    final bodyWidths = <double>[];
    for (final row in bodyRows) {
      if (column >= row.length) {
        continue;
      }
      final text = row[column].trim();
      if (text.isEmpty) {
        continue;
      }
      bodyWidths.add(estimatedTextWidth(text) + horizontalPadding);
    }

    final bodyWidth = _representativeBodyWidth(bodyWidths);
    final target = headerWidth > bodyWidth ? headerWidth : bodyWidth;
    widths.add(target.clamp(lower, upper).toDouble());
  }
  return widths;
}

/// 判断某一列是否为数值列。
///
/// 忽略空白值；至少要有一个有效值，且所有有效值都能被 `double.tryParse`
/// 解析才算数值列。全空列、越界列都返回 false。
bool isNumericCsvColumn(List<List<String>> rows, int column) {
  if (column < 0) {
    return false;
  }
  var hasValue = false;
  for (final row in rows) {
    if (column >= row.length) {
      continue;
    }
    final value = row[column].trim();
    if (value.isEmpty) {
      continue;
    }
    if (double.tryParse(value) == null) {
      return false;
    }
    hasValue = true;
  }
  return hasValue;
}

/// 把一行单元格编码成 TSV。
///
/// 单元格包含制表符、换行或双引号时用双引号包裹并按 RFC 4180 转义，
/// 否则复制出来的整行会在粘贴到表格软件时错列。
String encodeTsvRow(List<String> cells) {
  String escape(String cell) {
    if (!cell.contains('\t') && !cell.contains('\n') && !cell.contains('\r') && !cell.contains('"')) {
      return cell;
    }
    return '"${cell.replaceAll('"', '""')}"';
  }

  return cells.map(escape).join('\t');
}

/// 从若干候选宽度里取一个有代表性的值。
///
/// 最大宽度明显高于次宽（超过 1.6 倍且差值超过 60）时视为离群值，
/// 改用次宽，避免单个超长单元格独占整列；正常数据仍取最大值。
double _representativeBodyWidth(List<double> widths) {
  if (widths.isEmpty) {
    return 0;
  }
  if (widths.length == 1) {
    return widths.single;
  }
  widths.sort();
  final largest = widths.last;
  final second = widths[widths.length - 2];
  if (largest > second * 1.6 && largest - second > 60) {
    return second;
  }
  return largest;
}

/// 按 Unicode 东亚宽度近似判断字符是否占两个半角位。
///
/// 只覆盖常见 CJK、假名、韩文、全角标点与 emoji 区段；未覆盖的字符按
/// 半角估算，宁可估窄一点，让自动换行兜底，也不要把列宽估得过大。
bool _isWideRune(int rune) {
  if (rune < 0x1100) {
    return false;
  }
  return (rune >= 0x1100 && rune <= 0x115F) ||
      (rune >= 0x2E80 && rune <= 0xA4CF) ||
      (rune >= 0xA960 && rune <= 0xA97F) ||
      (rune >= 0xAC00 && rune <= 0xD7A3) ||
      (rune >= 0xF900 && rune <= 0xFAFF) ||
      (rune >= 0xFE10 && rune <= 0xFE19) ||
      (rune >= 0xFE30 && rune <= 0xFE6F) ||
      (rune >= 0xFF00 && rune <= 0xFF60) ||
      (rune >= 0xFFE0 && rune <= 0xFFE6) ||
      (rune >= 0x1B000 && rune <= 0x1B2FF) ||
      (rune >= 0x1F300 && rune <= 0x1FAFF) ||
      (rune >= 0x20000 && rune <= 0x3FFFD);
}
