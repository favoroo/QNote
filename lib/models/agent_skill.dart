import 'dart:convert';

/// 小Q技能来源常量：内置技能与用户技能
class AgentSkillOrigin {
  /// 内置技能：随 App 发行版本更新，对用户与小Q均只读
  static const String builtin = 'builtin';

  /// 用户技能：存于 app_configs，可由用户或小Q增删改，不会被 App 更新覆盖
  static const String user = 'user';
}

/// 小Q用户自定义技能：一份带名称与描述的 Markdown 手册
///
/// 持久化于 app_configs 键值表（键 `agent_skill_<name>`），经 [AgentSkill.name]
/// 映射为 VFS 虚拟文件 `/skills/<name>.md`；内置技能（SkillRegistry 中的
/// Dart 常量）不使用本模型。
class AgentSkill {
  /// 技能标识（即虚拟文件名，不含 `.md` 后缀）；创建后不可变
  final String name;

  /// 一句话描述，注入技能索引供小Q按需选用
  final String description;

  /// 手册正文（Markdown，不含 frontmatter）
  final String content;

  final DateTime updatedAt;

  AgentSkill({
    required this.name,
    this.description = '',
    this.content = '',
    DateTime? updatedAt,
  }) : updatedAt = updatedAt ?? DateTime.now();

  /// 技能对应的 VFS 虚拟文件路径
  static String pathOf(String name) => '/skills/$name.md';

  /// 校验技能名合法性：非空、不含路径分隔符与空白、不以 `.` 开头
  static bool isValidName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed.length > 40) return false;
    if (trimmed.startsWith('.')) return false;
    return !RegExp(r'[\s/\\]').hasMatch(trimmed);
  }

  /// 合成整篇手册文本（YAML frontmatter + 正文），与内置技能格式一致，
  /// 供 VFS readFile 与 skill 工具输出
  String toMarkdown() {
    return '---\nname: $name\ndescription: $description\n---\n\n$content';
  }

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'description': description,
      'content': content,
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory AgentSkill.fromMap(Map<String, dynamic> map) {
    return AgentSkill(
      name: map['name'] as String,
      description: map['description'] as String? ?? '',
      content: map['content'] as String? ?? '',
      updatedAt: map['updated_at'] != null
          ? DateTime.tryParse(map['updated_at'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }

  factory AgentSkill.fromJson(String json) =>
      AgentSkill.fromMap(jsonDecode(json) as Map<String, dynamic>);

  String toJson() => jsonEncode(toMap());

  AgentSkill copyWith({
    String? name,
    String? description,
    String? content,
    DateTime? updatedAt,
  }) {
    return AgentSkill(
      name: name ?? this.name,
      description: description ?? this.description,
      content: content ?? this.content,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
