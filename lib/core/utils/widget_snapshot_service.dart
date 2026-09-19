import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/storage/widget_snapshot_repository.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/models/widget_snapshot.dart';

/// 桌面小组件快照写入器
///
/// 由 [WidgetUtils.updateHomeWidgets] 在通知原生刷新之前调用，原生组件只读结果，
/// 不再各自复现统计口径。
class WidgetSnapshotService {
  WidgetSnapshotService._();

  static final WidgetSnapshotRepository _repo = WidgetSnapshotRepository();

  /// 「今日」在待办里是文件夹而非日期，默认文件夹 id 见 todo_folder_provider
  static const String _todayFolderId = 'todo_default_today';

  static bool _running = false;

  /// 写入今日待办计数快照。
  ///
  /// 单条 SELECT + 内存过滤（待办量级为百），原生侧一次 COUNT 也能算，但「今日」
  /// 的判定规则必须在 Dart 保持唯一出处，否则两端口径会随文件夹逻辑演进而漂移。
  static Future<void> writeTodoSnapshot() async {
    if (_running) {
      // 一次批量操作会连续触发多处刷新，重复跑没有意义
      return;
    }
    _running = true;
    try {
      final pending = await TodoRepository().getPending();
      final count = pending.where(_inTodayFolder).length;
      await _repo.put(
        WidgetSnapshot(
          key: WidgetSnapshotKeys.todoPendingToday,
          valueNum: count,
          updatedAt: DateTime.now(),
        ),
      );
    } catch (e, s) {
      LoggerService.instance.error(
        'WidgetSnapshotService.writeTodoSnapshot failed: $e',
        stackTrace: s,
      );
    } finally {
      _running = false;
    }
  }

  /// 「今日」文件夹归属判定。
  ///
  /// 与 lib/pages/todo_page.dart 里 currentFolderTodoIds 的同名分支保持一致：
  /// 显式挂在今日文件夹下的，或未分配文件夹且非长期待办的。
  static bool _inTodayFolder(Todo todo) {
    if (todo.title.trim().isEmpty) {
      return false;
    }
    if (todo.folderId == _todayFolderId) {
      return true;
    }
    final unassigned = todo.folderId == null || todo.folderId!.isEmpty;
    return unassigned && !todo.isLongTerm;
  }
}
