class Todo {
  final String id;
  String title;
  String description;
  bool isCompleted;
  String priority;
  DateTime? dueDate;
  String tags;
  String? folderId;
  bool isLongTerm;
  String? reminderTime;
  DateTime? deadline;
  DateTime createdAt;
  DateTime updatedAt;
  bool isDeleted;

  Todo({
    required this.id,
    required this.title,
    this.description = '',
    this.isCompleted = false,
    this.priority = 'normal',
    this.dueDate,
    this.tags = '',
    this.folderId,
    this.isLongTerm = false,
    this.reminderTime,
    this.deadline,
    required this.createdAt,
    required this.updatedAt,
    this.isDeleted = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'description': description,
      'is_completed': isCompleted ? 1 : 0,
      'priority': priority,
      'due_date': dueDate?.toIso8601String(),
      'tags': tags,
      'folder_id': folderId,
      'is_long_term': isLongTerm ? 1 : 0,
      'reminder_time': reminderTime,
      'deadline': deadline?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
      'is_deleted': isDeleted ? 1 : 0,
    };
  }

  factory Todo.fromMap(Map<String, dynamic> map) {
    return Todo(
      id: map['id'] as String,
      title: map['title'] as String,
      description: map['description'] as String? ?? '',
      isCompleted: (map['is_completed'] as int? ?? 0) == 1,
      priority: map['priority'] as String? ?? 'normal',
      dueDate: map['due_date'] != null
          ? DateTime.parse(map['due_date'] as String)
          : null,
      tags: map['tags'] as String? ?? '',
      folderId: map['folder_id'] as String?,
      isLongTerm: (map['is_long_term'] as int? ?? 0) == 1,
      reminderTime: map['reminder_time'] as String?,
      deadline: map['deadline'] != null
          ? DateTime.parse(map['deadline'] as String)
          : null,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
      isDeleted: (map['is_deleted'] as int? ?? 0) == 1,
    );
  }

  Todo copyWith({
    String? id,
    String? title,
    String? description,
    bool? isCompleted,
    String? priority,
    DateTime? dueDate,
    String? tags,
    String? folderId,
    bool? isLongTerm,
    String? reminderTime,
    DateTime? deadline,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isDeleted,
  }) {
    return Todo(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      isCompleted: isCompleted ?? this.isCompleted,
      priority: priority ?? this.priority,
      dueDate: dueDate ?? this.dueDate,
      tags: tags ?? this.tags,
      folderId: folderId ?? this.folderId,
      isLongTerm: isLongTerm ?? this.isLongTerm,
      reminderTime: reminderTime ?? this.reminderTime,
      deadline: deadline ?? this.deadline,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isDeleted: isDeleted ?? this.isDeleted,
    );
  }
}
