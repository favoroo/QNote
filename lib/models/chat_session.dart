import 'dart:convert';

/// 工具调用定义（与 OpenAI / 兼容模型格式一致）
class ToolCall {
  final String id;
  final String type;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    this.type = 'function',
    required this.name,
    required this.arguments,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'type': type,
      'function': {
        'name': name,
        'arguments': jsonEncode(arguments),
      },
    };
  }

  factory ToolCall.fromMap(Map<String, dynamic> map) {
    final func = map['function'] as Map<String, dynamic>? ?? {};
    final name = func['name'] as String? ?? map['name'] as String? ?? '';
    final rawArgs = func['arguments'] ?? map['arguments'];
    Map<String, dynamic> args = {};
    if (rawArgs is Map<String, dynamic>) {
      args = rawArgs;
    } else if (rawArgs is String && rawArgs.trim().isNotEmpty) {
      try {
        args = jsonDecode(rawArgs) as Map<String, dynamic>;
      } catch (_) {}
    }
    return ToolCall(
      id: map['id'] as String? ?? '',
      type: map['type'] as String? ?? 'function',
      name: name,
      arguments: args,
    );
  }
}

class ChatMessage {
  final String role; // 'user' | 'assistant' | 'system' | 'tool'
  final String content;
  final DateTime? timestamp;
  final List<String>? images;
  final String? thought; // 模型思考推理过程
  final List<ToolCall>? toolCalls; // 模型生成的工具调用
  final String? toolCallId; // 当 role == 'tool' 时对应的 toolCallId
  final String? toolName; // 当 role == 'tool' 时的工具名称
  final bool? isError; // 当 role == 'tool' 时表示执行是否出错
  final Map<String, dynamic>? uiDetails; // 供客户端 UI 渲染的结构化卡片数据
  final String? undoLog; // 仅用户消息：本轮对话 VFS 变更快照（WorkspaceUndoEntry 列表 JSON），支撑撤回/再次编辑

  ChatMessage({
    required this.role,
    required this.content,
    this.timestamp,
    this.images,
    this.thought,
    this.toolCalls,
    this.toolCallId,
    this.toolName,
    this.isError,
    this.uiDetails,
    this.undoLog,
  });

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'content': content,
      'timestamp': timestamp?.toIso8601String(),
      if (images != null && images!.isNotEmpty) 'images': images,
      if (thought != null && thought!.isNotEmpty) 'thought': thought,
      if (toolCalls != null && toolCalls!.isNotEmpty)
        'tool_calls': toolCalls!.map((t) => t.toMap()).toList(),
      if (toolCallId != null) 'tool_call_id': toolCallId,
      if (toolName != null) 'tool_name': toolName,
      if (isError != null) 'is_error': isError,
      if (uiDetails != null) 'ui_details': uiDetails,
      if (undoLog != null && undoLog!.isNotEmpty) 'undo_log': undoLog,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    List<String>? images;
    if (map['images'] != null) {
      if (map['images'] is List) {
        images = (map['images'] as List).map((e) => e.toString()).toList();
      }
    }

    List<ToolCall>? toolCalls;
    if (map['tool_calls'] != null && map['tool_calls'] is List) {
      toolCalls = (map['tool_calls'] as List)
          .whereType<Map<String, dynamic>>()
          .map((m) => ToolCall.fromMap(m))
          .toList();
    }

    Map<String, dynamic>? uiDetails;
    if (map['ui_details'] != null && map['ui_details'] is Map<String, dynamic>) {
      uiDetails = map['ui_details'] as Map<String, dynamic>;
    }

    return ChatMessage(
      role: map['role'] as String,
      content: map['content'] as String? ?? '',
      timestamp: map['timestamp'] != null
          ? DateTime.parse(map['timestamp'] as String)
          : null,
      images: images,
      thought: map['thought'] as String?,
      toolCalls: toolCalls,
      toolCallId: map['tool_call_id'] as String?,
      toolName: map['tool_name'] as String?,
      isError: map['is_error'] as bool?,
      uiDetails: uiDetails,
      undoLog: map['undo_log'] as String?,
    );
  }

  ChatMessage copyWith({
    String? role,
    String? content,
    DateTime? timestamp,
    List<String>? images,
    String? thought,
    List<ToolCall>? toolCalls,
    String? toolCallId,
    String? toolName,
    bool? isError,
    Map<String, dynamic>? uiDetails,
    String? undoLog,
  }) {
    return ChatMessage(
      role: role ?? this.role,
      content: content ?? this.content,
      timestamp: timestamp ?? this.timestamp,
      images: images ?? this.images,
      thought: thought ?? this.thought,
      toolCalls: toolCalls ?? this.toolCalls,
      toolCallId: toolCallId ?? this.toolCallId,
      toolName: toolName ?? this.toolName,
      isError: isError ?? this.isError,
      uiDetails: uiDetails ?? this.uiDetails,
      undoLog: undoLog ?? this.undoLog,
    );
  }
}

class ChatSession {
  final String id;
  final String title;
  final List<ChatMessage> messages;
  final String? aiConfigId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool isDeleted;

  ChatSession({
    required this.id,
    required this.title,
    this.messages = const [],
    this.aiConfigId,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'messages': jsonEncode(messages.map((m) => m.toMap()).toList()),
      'ai_config_id': aiConfigId,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  factory ChatSession.fromMap(Map<String, dynamic> map) {
    List<ChatMessage> messages = [];
    if (map['messages'] != null) {
      final messagesRaw = map['messages'];
      if (messagesRaw is String) {
        try {
          final decoded = jsonDecode(messagesRaw) as List;
          messages = decoded
              .map((m) => ChatMessage.fromMap(m as Map<String, dynamic>))
              .toList();
        } catch (_) {}
      } else if (messagesRaw is List) {
        messages = messagesRaw
            .map((m) => ChatMessage.fromMap(m as Map<String, dynamic>))
            .toList();
      }
    }

    return ChatSession(
      id: map['id'] as String,
      title: map['title'] as String,
      messages: messages,
      aiConfigId: map['ai_config_id'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
    );
  }

  ChatSession copyWith({
    String? id,
    String? title,
    List<ChatMessage>? messages,
    String? aiConfigId,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
  }) {
    return ChatSession(
      id: id ?? this.id,
      title: title ?? this.title,
      messages: messages ?? this.messages,
      aiConfigId: aiConfigId ?? this.aiConfigId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
