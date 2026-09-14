import 'dart:convert';

/// 工作区单条变更的撤销快照。
///
/// 录制时机：一轮对话中 Agent 首次写/改/删某虚拟路径前，捕获该路径的旧状态；
/// 撤回时依据 `existedBefore` 反向恢复（ existedBefore → 写回旧内容，否则删除新建文件）。
class WorkspaceUndoEntry {
  /// 归一化后的虚拟路径（timeline 单条路径会归一化到天文件）
  final String path;

  /// 本轮首次修改前该路径是否存在
  final bool existedBefore;

  /// 修改前的旧内容（已剥离行号前缀，可直接作为 writeFile 输入完成恢复）
  final String? beforeContent;

  const WorkspaceUndoEntry({
    required this.path,
    required this.existedBefore,
    this.beforeContent,
  });

  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'existed_before': existedBefore,
      if (beforeContent != null) 'before_content': beforeContent,
    };
  }

  factory WorkspaceUndoEntry.fromMap(Map<String, dynamic> map) {
    return WorkspaceUndoEntry(
      path: map['path'] as String? ?? '',
      existedBefore: map['existed_before'] as bool? ?? false,
      beforeContent: map['before_content'] as String?,
    );
  }

  String toJson() => jsonEncode(toMap());

  /// 将整轮变更条目列表序列化为 JSON 字符串（存入 ChatMessage.undoLog）
  static String encodeList(List<WorkspaceUndoEntry> entries) {
    return jsonEncode(entries.map((e) => e.toMap()).toList());
  }

  /// 从 ChatMessage.undoLog 反序列化；解析失败返回空列表（自然降级为仅回退上下文）
  static List<WorkspaceUndoEntry> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(WorkspaceUndoEntry.fromMap)
          .toList();
    } catch (_) {
      return [];
    }
  }
}
