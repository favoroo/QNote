import 'dart:convert';

class TagEntry {
  final String id;
  final String name;
  final Map<String, dynamic> fields;
  final String? time;
  final int? startHour;
  final int? startMinute;
  final int? endHour;
  final int? endMinute;
  final int? startOffset;
  final int? endOffset;

  const TagEntry._raw({
    required this.id,
    required this.name,
    this.fields = const {},
    this.time,
    this.startHour,
    this.startMinute,
    this.endHour,
    this.endMinute,
    this.startOffset,
    this.endOffset,
  });

  factory TagEntry({
    required String id,
    required String name,
    Map<String, dynamic> fields = const {},
    String? time,
    int? startHour,
    int? startMinute,
    int? endHour,
    int? endMinute,
    int? startOffset,
    int? endOffset,
  }) {
    int? sH = startHour;
    int? sM = startMinute;
    int? sO = startOffset;
    int? eH = endHour;
    int? eM = endMinute;
    int? eO = endOffset;

    if (time != null && time.isNotEmpty && sH == null) {
      final parsed = _parseTimeString(time);
      sH = parsed['startHour'];
      sM = parsed['startMinute'];
      sO = parsed['startOffset'];
      eH = parsed['endHour'];
      eM = parsed['endMinute'];
      eO = parsed['endOffset'];
    }

    return TagEntry._raw(
      id: id,
      name: name,
      fields: fields,
      time: time,
      startHour: sH,
      startMinute: sM,
      startOffset: sO,
      endHour: eH,
      endMinute: eM,
      endOffset: eO,
    );
  }

  bool get hasTime => (startHour != null && startMinute != null) || (time != null && time!.isNotEmpty);

  String? get formattedTime {
    if (startHour == null || startMinute == null) {
      return time;
    }
    final buffer = StringBuffer();
    if (startOffset == -1) {
      buffer.write('-');
    } else if (startOffset == 1) {
      buffer.write('+');
    }
    buffer.write('${startHour!.toString().padLeft(2, '0')}:${startMinute!.toString().padLeft(2, '0')}');

    if (endHour != null && endMinute != null) {
      buffer.write('~');
      if (endOffset == -1) {
        buffer.write('-');
      } else if (endOffset == 1) {
        buffer.write('+');
      }
      buffer.write('${endHour!.toString().padLeft(2, '0')}:${endMinute!.toString().padLeft(2, '0')}');
    }
    return buffer.toString();
  }

  String? get displayTime {
    if (startHour == null || startMinute == null) {
      return time;
    }
    final buffer = StringBuffer();
    if (startOffset != null && startOffset != 0) {
      if (startOffset == -1) {
        buffer.write('昨天 ');
      } else if (startOffset == -2) {
        buffer.write('前天 ');
      } else if (startOffset == 1) {
        buffer.write('明天 ');
      } else if (startOffset == 2) {
        buffer.write('后天 ');
      } else {
        buffer.write('${startOffset! > 0 ? "+" : ""}${startOffset}天 ');
      }
    }
    buffer.write('${startHour!.toString().padLeft(2, '0')}:${startMinute!.toString().padLeft(2, '0')}');

    if (endHour != null && endMinute != null) {
      buffer.write('~');
      if (endOffset != null && endOffset != 0) {
        if (endOffset == -1) {
          buffer.write('昨天 ');
        } else if (endOffset == -2) {
          buffer.write('前天 ');
        } else if (endOffset == 1) {
          buffer.write('次日 ');
        } else if (endOffset == 2) {
          buffer.write('后天 ');
        } else {
          buffer.write('${endOffset! > 0 ? "+" : ""}${endOffset}天 ');
        }
      }
      buffer.write('${endHour!.toString().padLeft(2, '0')}:${endMinute!.toString().padLeft(2, '0')}');
    }
    return buffer.toString();
  }

  static Map<String, dynamic> _parseTimeString(String timeStr) {
    final parts = timeStr.split('~');
    if (parts.isEmpty) return {};

    int? startHour;
    int? startMinute;
    int? startOffset;
    int? endHour;
    int? endMinute;
    int? endOffset;

    Map<String, int>? parsePart(String part) {
      part = part.trim();
      if (part.isEmpty) return null;

      int offset = 0;
      String cleanTime = part;
      if (part.startsWith('-')) {
        offset = -1;
        cleanTime = part.substring(1);
      } else if (part.startsWith('+')) {
        offset = 1;
        cleanTime = part.substring(1);
      }

      final tParts = cleanTime.split(':');
      if (tParts.length == 2) {
        final hour = int.tryParse(tParts[0]);
        final minute = int.tryParse(tParts[1]);
        if (hour != null && minute != null) {
          return {'hour': hour, 'minute': minute, 'offset': offset};
        }
      }
      return null;
    }

    final startResult = parsePart(parts[0]);
    if (startResult != null) {
      startHour = startResult['hour'];
      startMinute = startResult['minute'];
      startOffset = startResult['offset'];
    }

    if (parts.length > 1) {
      final endResult = parsePart(parts[1]);
      if (endResult != null) {
        endHour = endResult['hour'];
        endMinute = endResult['minute'];
        endOffset = endResult['offset'];
      }
    }

    return {
      'startHour': startHour,
      'startMinute': startMinute,
      'startOffset': startOffset,
      'endHour': endHour,
      'endMinute': endMinute,
      'endOffset': endOffset,
    };
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'fields': fields.isNotEmpty ? jsonEncode(fields) : null,
      'time': time,
      'startHour': startHour,
      'startMinute': startMinute,
      'startOffset': startOffset,
      'endHour': endHour,
      'endMinute': endMinute,
      'endOffset': endOffset,
    };
  }

  factory TagEntry.fromMap(Map<String, dynamic> map) {
    return TagEntry(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      fields: map['fields'] != null
          ? (map['fields'] is String
              ? jsonDecode(map['fields'] as String) as Map<String, dynamic>
              : Map<String, dynamic>.from(map['fields'] as Map))
          : {},
      time: map['time'] as String?,
      startHour: map['startHour'] as int?,
      startMinute: map['startMinute'] as int?,
      startOffset: map['startOffset'] as int?,
      endHour: map['endHour'] as int?,
      endMinute: map['endMinute'] as int?,
      endOffset: map['endOffset'] as int?,
    );
  }

  TagEntry copyWith({
    String? id,
    String? name,
    Map<String, dynamic>? fields,
    String? time,
    int? startHour,
    int? startMinute,
    int? endHour,
    int? endMinute,
    int? startOffset,
    int? endOffset,
    bool clearEndTime = false,
    bool clearStartTime = false,
  }) {
    final sH = clearStartTime ? null : (startHour ?? this.startHour);
    final sM = clearStartTime ? null : (startMinute ?? this.startMinute);
    final sO = clearStartTime ? null : (startOffset ?? this.startOffset);
    final eH = (clearStartTime || clearEndTime) ? null : (endHour ?? this.endHour);
    final eM = (clearStartTime || clearEndTime) ? null : (endMinute ?? this.endMinute);
    final eO = (clearStartTime || clearEndTime) ? null : (endOffset ?? this.endOffset);

    String? newTime;
    if (clearStartTime) {
      newTime = null;
    } else if (time != null) {
      newTime = time;
    } else {
      if (sH != null && sM != null) {
        final buffer = StringBuffer();
        if (sO == -1) {
          buffer.write('-');
        } else if (sO == 1) {
          buffer.write('+');
        }
        buffer.write('${sH.toString().padLeft(2, '0')}:${sM.toString().padLeft(2, '0')}');
        if (eH != null && eM != null) {
          buffer.write('~');
          if (eO == -1) {
            buffer.write('-');
          } else if (eO == 1) {
            buffer.write('+');
          }
          buffer.write('${eH.toString().padLeft(2, '0')}:${eM.toString().padLeft(2, '0')}');
        }
        newTime = buffer.toString();
      } else {
        newTime = this.time;
      }
    }

    int? finalSH = sH;
    int? finalSM = sM;
    int? finalSO = sO;
    int? finalEH = eH;
    int? finalEM = eM;
    int? finalEO = eO;

    if (time != null && time != this.time && startHour == null && startMinute == null && !clearStartTime) {
      final parsed = _parseTimeString(time);
      finalSH = parsed['startHour'];
      finalSM = parsed['startMinute'];
      finalSO = parsed['startOffset'];
      if (!clearEndTime) {
        finalEH = parsed['endHour'];
        finalEM = parsed['endMinute'];
        finalEO = parsed['endOffset'];
      }
    }

    return TagEntry._raw(
      id: id ?? this.id,
      name: name ?? this.name,
      fields: fields ?? this.fields,
      time: newTime,
      startHour: finalSH,
      startMinute: finalSM,
      startOffset: finalSO,
      endHour: finalEH,
      endMinute: finalEM,
      endOffset: finalEO,
    );
  }

  static List<TagEntry> listFromJson(String jsonStr) {
    if (jsonStr.isEmpty) return [];
    final list = jsonDecode(jsonStr) as List;
    return list.map((e) => TagEntry.fromMap(e as Map<String, dynamic>)).toList();
  }

  static String listToJson(List<TagEntry> entries) {
    return jsonEncode(entries.map((e) => e.toMap()).toList());
  }
}
