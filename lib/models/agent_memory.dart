import 'dart:convert';

/// 小Q长期记忆的分类常量与容量上限
///
/// 设计对齐 Hermes 记忆系统：记忆按"有界、经整理"的双文档组织，
/// 条目一行一条、紧凑高密度，超限时引导小Q整合而非无限膨胀。
class AgentMemoryCategory {
  /// 用户画像与习惯（偏好、作息、沟通风格、目标等），对应虚拟文件 /memory/user.md
  static const String user = 'user';

  /// 小Q手记（环境事实、分类约定、经验教训、任务备忘等），对应虚拟文件 /memory/agent.md
  static const String agent = 'agent';

  /// 全部分类
  static const List<String> all = [user, agent];

  /// 分类对应的 VFS 虚拟文件路径
  static String pathOf(String category) => '/memory/$category.md';

  /// 从 VFS 路径解析分类；非法路径返回 null
  static String? fromPath(String path) {
    final match = RegExp(r'^/memory/(user|agent)\.md$').firstMatch(path.trim());
    return match?.group(1);
  }

  /// 分类的中文展示名
  static String displayName(String category) =>
      category == user ? '用户画像' : '小Q手记';

  /// 分类容量上限（字符数，含条目前的 "- " 前缀）
  static int maxChars(String category) => category == user ? 1500 : 2400;
}

/// 小Q长期记忆文档：一个分类对应一份有界的 Markdown 条目集
class AgentMemoryDocument {
  final String category; // 取值见 [AgentMemoryCategory]
  final String content; // 文档正文，约定每行一条记忆（以 "- " 开头）
  final DateTime updatedAt;

  AgentMemoryDocument({
    required this.category,
    this.content = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// 容量占用百分比（0~100，向上取整）
  int get usagePercent {
    final max = AgentMemoryCategory.maxChars(category);
    if (max <= 0) return 0;
    return (content.length * 100 / max).ceil().clamp(0, 100);
  }

  /// 解析条目列表：每个非空行视为一条记忆，展示时剥除 "- " 前缀
  List<String> get entries => content
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .map((line) => line.startsWith('- ') ? line.substring(2) : line)
      .toList();

  Map<String, dynamic> toMap() {
    return {
      'category': category,
      'content': content,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AgentMemoryDocument.fromMap(Map<String, dynamic> map) {
    return AgentMemoryDocument(
      category: map['category'] as String,
      content: map['content'] as String? ?? '',
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  factory AgentMemoryDocument.fromJson(String json) =>
      AgentMemoryDocument.fromMap(jsonDecode(json) as Map<String, dynamic>);

  String toJson() => jsonEncode(toMap());

  AgentMemoryDocument copyWith({
    String? category,
    String? content,
    DateTime? updatedAt,
  }) {
    return AgentMemoryDocument(
      category: category ?? this.category,
      content: content ?? this.content,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
