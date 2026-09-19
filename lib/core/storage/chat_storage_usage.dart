/// 会话删除结果（供 UI 组织 Toast 与日志）。
class ChatSessionDeleteReport {
  /// 实际被物理删除的 `chat_sessions` 行数（行本就不存在时为 0，但删除事件仍会写墓碑）。
  final int deletedSessions;

  /// 被删消息条数。
  final int messageCount;

  /// 会话内用户可见的图片引用数（含内联 data URI / 外链 / 相册附件），仅用于展示。
  final int imageRefCount;

  /// 真正从磁盘删掉的生成图片文件数。
  final int deletedImageFiles;

  /// 其中图片文件实际释放的磁盘字节数（Toast 只报这个口径：消息字节删掉了但库文件
  /// 要等 VACUUM 整理才变小，把两者合并报「已释放」会失真）。
  final int imageFreedBytes;

  /// 因仍被其它数据引用、文件不存在或删除失败而保留的图片数。
  final int keptImageFiles;

  /// 释放的字节数（消息 JSON + 图片文件）。
  final int freedBytes;

  /// 删除失败的文件路径，仅写日志，不弹 UI。
  final List<String> failedPaths;

  const ChatSessionDeleteReport({
    this.deletedSessions = 0,
    this.messageCount = 0,
    this.imageRefCount = 0,
    this.deletedImageFiles = 0,
    this.imageFreedBytes = 0,
    this.keptImageFiles = 0,
    this.freedBytes = 0,
    this.failedPaths = const [],
  });

  static const ChatSessionDeleteReport empty = ChatSessionDeleteReport();
}

/// 对话历史占用估算（全部为只读统计口径，不触发任何删除）。
class ChatStorageUsage {
  /// 未删除会话数与其消息 JSON 字节数。
  final int activeSessions;
  final int activeMessagesBytes;

  /// 旧版本软删除留下的墓碑行数与其字节数（可回收）。
  final int tombstonedSessions;
  final int tombstonedBytes;

  /// `images/ai/` 目录里的生成图片总数与字节数。
  final int aiImageFiles;
  final int aiImageBytes;

  /// 其中已无任何引用、可回收的图片数与字节数。
  final int orphanImageFiles;
  final int orphanImageBytes;

  /// 数据库文件体积（`page_size * page_count`）；平台不支持该 PRAGMA 时为 null。
  final int? databaseFileBytes;

  const ChatStorageUsage({
    this.activeSessions = 0,
    this.activeMessagesBytes = 0,
    this.tombstonedSessions = 0,
    this.tombstonedBytes = 0,
    this.aiImageFiles = 0,
    this.aiImageBytes = 0,
    this.orphanImageFiles = 0,
    this.orphanImageBytes = 0,
    this.databaseFileBytes,
  });

  static const ChatStorageUsage empty = ChatStorageUsage();

  /// 点「立即回收」理论上能清掉的量：墓碑行 + 孤儿生成图。
  int get reclaimableBytes => tombstonedBytes + orphanImageBytes;
}

/// 体积格式化：对话占用与释放量的统一展示口径。
///
/// 项目里 `update_service` / `update_dialog` 各自有一份下载进度用的格式化，语义是
/// 「传输大小恒显示 MB」；对话占用里大量值是几十 KB 级，所以按量级切 B/KB/MB。
String formatChatStorageBytes(int bytes) {
  if (bytes <= 0) {
    return '0 B';
  }
  if (bytes < 1024) {
    return '$bytes B';
  }
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(bytes < 10 * 1024 ? 1 : 0)} KB';
  }
  return '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
}
