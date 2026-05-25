class WebdavConfig {
  final String id;
  String serverUrl;
  String username;
  String password;
  String remotePath;
  bool autoSync;
  int syncInterval;
  DateTime? lastSyncTime;
  DateTime createdAt;
  DateTime updatedAt;

  WebdavConfig({
    required this.id,
    required this.serverUrl,
    required this.username,
    required this.password,
    this.remotePath = 'QNote',
    this.autoSync = false,
    this.syncInterval = 30,
    this.lastSyncTime,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'server_url': serverUrl,
      'username': username,
      'password': password,
      'remote_path': remotePath,
      'auto_sync': autoSync ? 1 : 0,
      'sync_interval': syncInterval,
      'last_sync_time': lastSyncTime?.toIso8601String(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory WebdavConfig.fromMap(Map<String, dynamic> map) {
    return WebdavConfig(
      id: map['id'] as String,
      serverUrl: map['server_url'] as String,
      username: map['username'] as String,
      password: map['password'] as String,
      remotePath: map['remote_path'] as String? ?? 'QNote',
      autoSync: (map['auto_sync'] as int? ?? 0) == 1,
      syncInterval: map['sync_interval'] as int? ?? 30,
      lastSyncTime: map['last_sync_time'] != null
          ? DateTime.parse(map['last_sync_time'] as String)
          : null,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  WebdavConfig copyWith({
    String? id,
    String? serverUrl,
    String? username,
    String? password,
    String? remotePath,
    bool? autoSync,
    int? syncInterval,
    DateTime? lastSyncTime,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return WebdavConfig(
      id: id ?? this.id,
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      password: password ?? this.password,
      remotePath: remotePath ?? this.remotePath,
      autoSync: autoSync ?? this.autoSync,
      syncInterval: syncInterval ?? this.syncInterval,
      lastSyncTime: lastSyncTime ?? this.lastSyncTime,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}
