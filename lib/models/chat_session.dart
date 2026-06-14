import 'dart:convert';

class ChatMessage {
  final String role;
  final String content;
  final DateTime? timestamp;

  ChatMessage({
    required this.role,
    required this.content,
    this.timestamp,
  });

  Map<String, dynamic> toMap() {
    return {
      'role': role,
      'content': content,
      'timestamp': timestamp?.toIso8601String(),
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    return ChatMessage(
      role: map['role'] as String,
      content: map['content'] as String,
      timestamp: map['timestamp'] != null
          ? DateTime.parse(map['timestamp'] as String)
          : null,
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
        final decoded = jsonDecode(messagesRaw) as List;
        messages = decoded.map((m) => ChatMessage.fromMap(m as Map<String, dynamic>)).toList();
      } else if (messagesRaw is List) {
        messages = messagesRaw.map((m) => ChatMessage.fromMap(m as Map<String, dynamic>)).toList();
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
