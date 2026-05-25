import 'dart:convert';
import 'package:flutter_quill/quill_delta.dart';

String extractPlainTextFromDelta(String deltaJsonStr, {int maxLength = 100}) {
  try {
    final List<dynamic> ops = jsonDecode(deltaJsonStr);
    final buffer = StringBuffer();
    for (final op in ops) {
      if (op is Map && op['insert'] is String) {
        buffer.write(op['insert'] as String);
      }
    }
    var text = buffer.toString().replaceAll('\n', ' ').trim();
    while (text.contains('  ')) {
      text = text.replaceAll('  ', ' ');
    }
    if (text.length > maxLength) {
      return '${text.substring(0, maxLength)}...';
    }
    return text;
  } catch (_) {
    return deltaJsonStr;
  }
}

String deltaToMarkdown(Delta delta) {
  final buffer = StringBuffer();
  final lines = _splitDeltaIntoLines(delta);

  for (int i = 0; i < lines.length; i++) {
    final line = lines[i];
    buffer.write(_lineToMarkdown(line));
    if (i < lines.length - 1) {
      buffer.write('\n');
    }
  }

  return buffer.toString();
}

List<_DeltaLine> _splitDeltaIntoLines(Delta delta) {
  final lines = <_DeltaLine>[];
  var currentLine = _DeltaLine();

  for (final op in delta.toList()) {
    if (op.data is String) {
      final text = op.data as String;
      final attributes = op.attributes;
      var start = 0;

      for (var i = 0; i < text.length; i++) {
        if (text[i] == '\n') {
          if (i > start) {
            currentLine.segments.add(_DeltaSegment(
              text.substring(start, i),
              attributes != null ? Map<String, dynamic>.from(attributes) : null,
            ));
          }
          currentLine.lineAttributes =
              attributes != null ? Map<String, dynamic>.from(attributes) : null;
          lines.add(currentLine);
          currentLine = _DeltaLine();
          start = i + 1;
        }
      }

      if (start < text.length) {
        currentLine.segments.add(_DeltaSegment(
          text.substring(start),
          attributes != null ? Map<String, dynamic>.from(attributes) : null,
        ));
      }
    } else {
      currentLine.segments.add(_DeltaSegment(
        op.data ?? '',
        op.attributes != null
            ? Map<String, dynamic>.from(op.attributes!)
            : null,
      ));
    }
  }

  if (currentLine.segments.isNotEmpty || currentLine.lineAttributes != null) {
    lines.add(currentLine);
  }

  return lines;
}

String _lineToMarkdown(_DeltaLine line) {
  final lineAttr = line.lineAttributes;

  if (lineAttr != null) {
    if (lineAttr.containsKey('code-block')) {
      final text = line.segments.map((s) => s.text is String ? s.text as String : '').join();
      return '    $text';
    }

    var prefix = '';
    if (lineAttr.containsKey('header')) {
      final level = lineAttr['header'] as int;
      prefix = '${'#' * level} ';
    } else if (lineAttr.containsKey('blockquote')) {
      prefix = '> ';
    } else if (lineAttr.containsKey('list')) {
      final listType = lineAttr['list'] as String;
      if (listType == 'ordered') {
        prefix = '1. ';
      } else {
        prefix = '- ';
      }
    }

    return '$prefix${_segmentsToMarkdown(line.segments)}';
  }

  return _segmentsToMarkdown(line.segments);
}

String _segmentsToMarkdown(List<_DeltaSegment> segments) {
  final buffer = StringBuffer();

  for (final seg in segments) {
    if (seg.text is! String) {
      final data = seg.text;
      if (data is Map && data.containsKey('image')) {
        buffer.write('![image](${data['image']})');
      } else if (data is Map && data.containsKey('hr')) {
        buffer.write('\n---\n');
      } else {
        buffer.write(data.toString());
      }
      continue;
    }

    var text = seg.text as String;
    final attr = seg.attributes;

    if (attr != null) {
      if (attr.containsKey('bold')) {
        text = '**$text**';
      }
      if (attr.containsKey('italic')) {
        text = '*$text*';
      }
      if (attr.containsKey('strike')) {
        text = '~~$text~~';
      }
      if (attr.containsKey('code')) {
        text = '`$text`';
      }
      if (attr.containsKey('link')) {
        text = '[$text](${attr['link']})';
      }
    }

    buffer.write(text);
  }

  return buffer.toString();
}

class _DeltaLine {
  final List<_DeltaSegment> segments = [];
  Map<String, dynamic>? lineAttributes;
}

class _DeltaSegment {
  final Object text;
  final Map<String, dynamic>? attributes;

  _DeltaSegment(this.text, this.attributes);
}
