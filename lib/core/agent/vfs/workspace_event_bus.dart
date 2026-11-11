import 'package:qnote_flutter/core/logger/logger_service.dart';

/// 工作区文件变更类型
enum WorkspaceChangeType { created, updated, deleted }

/// 工作区文件变更事件
class WorkspaceChangeEvent {
  final String path;
  final WorkspaceChangeType changeType;
  final dynamic payload;

  const WorkspaceChangeEvent({required this.path, required this.changeType, this.payload});

  @override
  String toString() => 'WorkspaceChangeEvent($changeType, $path)';
}

/// 工作区全局事件总线，负责在虚拟文件变更时向 UI/Riverpod 派发实时通知
class WorkspaceEventBus {
  static final WorkspaceEventBus instance = WorkspaceEventBus._();
  WorkspaceEventBus._();

  final List<void Function(WorkspaceChangeEvent)> _listeners = [];

  /// 注册监听器
  void addListener(void Function(WorkspaceChangeEvent) listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// 移除监听器
  void removeListener(void Function(WorkspaceChangeEvent) listener) {
    _listeners.remove(listener);
  }

  /// 派发变更事件
  void emit(String path, WorkspaceChangeType type, [dynamic payload]) {
    final event = WorkspaceChangeEvent(path: path, changeType: type, payload: payload);
    for (final listener in List.from(_listeners)) {
      try {
        listener(event);
      } catch (e) {
        // 单个监听器抛错不能中断其余监听器，但需记录以便排查 UI 状态未刷新问题
        LoggerService.instance.warning('工作区变更事件监听器执行失败: path=$path, type=${type.name}, $e', category: LogCategory.ui);
      }
    }
  }
}
