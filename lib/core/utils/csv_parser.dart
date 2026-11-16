/// 轻量分隔符文本（CSV/TSV）解析。
///
/// 按 RFC 4180 语义处理：引号包裹的字段可包含分隔符、换行与转义的双引号；
/// CRLF 与 LF 均按行分隔；不做类型推断（全部返回字符串，由展示层决定对齐方式）。
///
/// 抽成顶层纯函数便于单测（不依赖 BuildContext / Controller）。
List<List<String>> parseDelimited(String input, {String delimiter = ','}) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var inQuotes = false;
  // 是否已经出现过一个字段内容（含空字段被分隔的场景），用于区分「空行」与「行末换行」
  var hasField = false;
  var i = 0;

  while (i < input.length) {
    final ch = input[i];
    if (inQuotes) {
      if (ch == '"') {
        // 连续两个引号是转义后的字面引号
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i += 2;
          continue;
        }
        inQuotes = false;
        i++;
        continue;
      }
      field.write(ch);
      i++;
      continue;
    }

    if (ch == '"') {
      inQuotes = true;
      hasField = true;
      i++;
      continue;
    }
    if (ch == delimiter) {
      row.add(field.toString());
      field.clear();
      hasField = false;
      i++;
      continue;
    }
    if (ch == '\r') {
      // CRLF 统一交给 '\n' 处理，单独出现的 '\r' 直接忽略
      i++;
      continue;
    }
    if (ch == '\n') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = <String>[];
      hasField = false;
      i++;
      continue;
    }
    field.write(ch);
    hasField = true;
    i++;
  }

  // 收尾：末行没有换行结尾，或末字段有内容时才补一行，避免尾随换行多出一行空数据
  if (hasField || field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

/// 去掉「所有字段均为空白」的行（小Q 或手工编辑常留下尾部空行）
List<List<String>> dropBlankRows(List<List<String>> rows) =>
    rows.where((r) => r.any((c) => c.trim().isNotEmpty)).toList();

/// 把二维行序列化回分隔符文本（RFC 4180），与 [parseDelimited] 互为逆操作。
///
/// 字段含分隔符、双引号或换行时用引号包裹，内部双引号写成两个；
/// [lineEnding] 保持原文件的换行风格（CRLF/LF），编辑写回时不污染源码。
String serializeDelimited(List<List<String>> rows, {String delimiter = ',', String lineEnding = '\n'}) {
  final buffer = StringBuffer();
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    for (var c = 0; c < row.length; c++) {
      if (c > 0) {
        buffer.write(delimiter);
      }
      buffer.write(_escapeDelimitedField(row[c], delimiter));
    }
    if (r < rows.length - 1) {
      buffer.write(lineEnding);
    }
  }
  return buffer.toString();
}

/// 单字段转义：含分隔符/引号/换行才加引号，保持未受影响字段原样输出
String _escapeDelimitedField(String value, String delimiter) {
  final needsQuote = value.contains(delimiter) || value.contains('"') || value.contains('\n') || value.contains('\r');
  if (!needsQuote) {
    return value;
  }
  return '"${value.replaceAll('"', '""')}"';
}

/// 按扩展名选择分隔符：tsv 用制表符，其余按逗号
String delimiterForExtension(String? ext) => (ext ?? '').toLowerCase() == 'tsv' ? '\t' : ',';
