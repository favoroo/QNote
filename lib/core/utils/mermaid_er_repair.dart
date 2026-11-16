/// Mermaid `erDiagram` 的预览期标识符修复。
///
/// Mermaid 的 ER 语法里，实体名、字段类型、字段名都只接受 ASCII 标识符；
/// 中文只能出现在**引号包裹的关系标签**与**字段注释**中。模型经常写成
/// `string 昵称 "谦"`，整张图会直接语法报错。
///
/// 这里在**不改动用户源码**的前提下做一次保守修复：
/// - 中文字段名 → `field_N`，中文原名放进字段注释列；
/// - 中文字段类型 → `string`，原类型一并放进注释；
/// - 未加引号的中文关系标签 → 自动补引号。
///
/// 实体名中的中文不做替换（替换后图中只剩 `ENTITY_1`，反而看不懂），
/// 由预览的错误卡片给出明确提示。
library;

/// 修复结果
class MermaidErRepairResult {
  /// 修复后的源码；未命中 ER 或无需修复时与输入完全一致
  final String source;

  /// 被替换的中文字段名/类型数量
  final int renamedFields;

  /// 自动补引号的中文关系标签数量
  final int quotedLabels;

  const MermaidErRepairResult({required this.source, required this.renamedFields, required this.quotedLabels});

  bool get changed => renamedFields > 0 || quotedLabels > 0;

  /// 给预览顶部提示条用的说明；无需修复时为 null
  String? get notice {
    if (!changed) return null;
    final parts = <String>[];
    if (renamedFields > 0) {
      parts.add('中文字段名/类型改为英文标识，中文保留在注释列');
    }
    if (quotedLabels > 0) {
      parts.add('中文关系标签已补引号');
    }
    parts.add('源码本身未修改，建议让小Q 修正');
    return '预览已临时处理：${parts.join('；')}。';
  }
}

/// 修复 ER 源码中的中文字段名、字段类型与未加引号的关系标签。
MermaidErRepairResult repairMermaidErSource(String source) {
  final newline = source.contains('\r\n') ? '\r\n' : '\n';
  final lines = source.split(RegExp(r'\r?\n'));
  var started = false;
  var inBlock = false;
  var fieldIndex = 0;
  var renamedFields = 0;
  var quotedLabels = 0;

  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final trimmed = line.trim();
    if (!started) {
      if (trimmed.toLowerCase().startsWith('erdiagram')) {
        started = true;
      }
      continue;
    }

    // 实体块开始：`USER {`；关系线里的 `o{` 不会以 `{` 结尾，也不会命中
    final blockStart = RegExp(r'^(\s*)([^{}]+?)\s*\{\s*$').firstMatch(line);
    if (!inBlock && blockStart != null && !_looksLikeRelationship(blockStart.group(2)!)) {
      inBlock = true;
      fieldIndex = 0;
      continue;
    }

    if (inBlock) {
      if (trimmed.isEmpty || trimmed.startsWith('%%')) {
        continue;
      }
      if (trimmed.startsWith('}')) {
        inBlock = false;
        continue;
      }
      final repaired = _repairAttributeLine(line, fieldIndex: fieldIndex);
      if (repaired != null) {
        lines[i] = repaired.line;
        fieldIndex = repaired.nextIndex;
        if (repaired.changed) renamedFields++;
      }
      continue;
    }

    // 关系线：`USER ||--o{ ORDER : 下单` → 中文标签补引号
    if (trimmed.contains(':') && _looksLikeRelationship(trimmed)) {
      final repaired = _quoteRelationshipLabel(line);
      if (repaired != null) {
        lines[i] = repaired;
        quotedLabels++;
      }
    }
  }

  return MermaidErRepairResult(source: lines.join(newline), renamedFields: renamedFields, quotedLabels: quotedLabels);
}

class _RepairedAttribute {
  final String line;
  final int nextIndex;
  final bool changed;

  const _RepairedAttribute({required this.line, required this.nextIndex, required this.changed});
}

/// 修复一行字段声明，返回 null 表示保持原样。
_RepairedAttribute? _repairAttributeLine(String line, {required int fieldIndex}) {
  final trimmed = line.trim();
  final indent = line.substring(0, line.length - line.trimLeft().length);
  final commentMatch = RegExp(r'"([^"]*)"').firstMatch(trimmed);
  final existingComment = commentMatch?.group(1);
  final body = commentMatch == null
      ? trimmed
      : '${trimmed.substring(0, commentMatch.start)} ${trimmed.substring(commentMatch.end)}'.trim();
  final parts = body.split(RegExp(r'\s+')).where((part) => part.isNotEmpty).toList();
  if (parts.length < 2) return null;

  final type = parts[0];
  final name = parts[1];
  final constraints = [
    for (final part in parts.skip(2))
      if (RegExp(r'^(PK|FK|UK)$', caseSensitive: false).hasMatch(part)) part.toUpperCase(),
  ];

  final typeValid = _isAsciiIdentifier(type);
  final nameValid = _isAsciiIdentifier(name);
  if (typeValid && nameValid) return null;

  var nextIndex = fieldIndex;
  final newName = nameValid ? name : 'field_${++nextIndex}';
  final newType = typeValid ? type : 'string';

  final commentParts = <String>[
    if (!typeValid) '原类型：$type',
    if (!nameValid) name,
    if (existingComment != null && existingComment.trim().isNotEmpty) existingComment.trim(),
  ];
  final comment = commentParts.join(' · ').replaceAll('"', "'");
  final buffer = StringBuffer()
    ..write(indent)
    ..write(newType)
    ..write(' ')
    ..write(newName);
  for (final constraint in constraints) {
    buffer
      ..write(' ')
      ..write(constraint);
  }
  if (comment.isNotEmpty) {
    buffer
      ..write(' "')
      ..write(comment)
      ..write('"');
  }
  return _RepairedAttribute(line: buffer.toString(), nextIndex: nextIndex, changed: true);
}

/// 关系标签补引号；已经带引号或没有中文时返回 null。
String? _quoteRelationshipLabel(String line) {
  final colon = line.indexOf(':');
  if (colon < 0) return null;
  final label = line.substring(colon + 1).trim();
  if (label.isEmpty) return null;
  final isQuoted = (label.startsWith('"') && label.endsWith('"')) || (label.startsWith("'") && label.endsWith("'"));
  if (isQuoted || !_containsNonAscii(label)) return null;
  final safe = label.replaceAll('"', "'");
  return '${line.substring(0, colon + 1)} "$safe"';
}

bool _looksLikeRelationship(String text) => text.contains('--') || text.contains('..');

bool _isAsciiIdentifier(String value) => RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(value);

bool _containsNonAscii(String value) => value.runes.any((rune) => rune > 0x7F);
