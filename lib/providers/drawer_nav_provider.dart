import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 抽屉重开后仍停留在原页面的时间窗口。
///
/// 用户点右侧空白关掉抽屉，多半只是想「瞄一眼主界面」，紧接着重开应当回到原处；
/// 隔久了再打开抽屉则是一次新的「找设置」动作，应该看到一级菜单。
/// 调这里就能改变记忆的松紧，无需动 UI。
const Duration kDrawerResumeWindow = Duration(minutes: 1);

/// 侧边抽屉内嵌导航的记忆：用户最后停在哪个入口，以及抽屉是什么时候关掉的。
///
/// 抽屉关闭时 [DrawerController] 会把整棵子树卸载（含内嵌 Navigator），页面栈
/// 天然保不住；这份记忆活在抽屉之外，重开时据此把页面栈重建回来。
///
/// 刻意做成普通对象而非 Riverpod 状态：它只在抽屉的 initState / dispose 里被读改写，
/// 没有任何 widget 监听；用 Notifier 反而会在 dispose 写状态时撞上
/// 「构建期修改 provider」的断言。
class DrawerNavMemory {
  /// 最后停留的入口 id；null 表示停在一级菜单
  String? entryId;

  /// 抽屉最后一次关闭的时间；用于判断记忆是否已经过期
  DateTime? closedAt;

  /// 抽屉关闭时写入当前停留的入口（停在一级菜单传 null）。
  ///
  /// 关闭是唯一的写入时机：这样「过期后重开只看到菜单、再关掉」也会把旧入口
  /// 覆盖掉，不会留下一条永远新鲜的幽灵记录。
  void recordClosed({String? entryId, DateTime? now}) {
    this.entryId = entryId;
    closedAt = now ?? DateTime.now();
  }

  /// 抽屉重新打开时可恢复的入口 id；超过 [kDrawerResumeWindow] 视为过期，返回 null。
  String? resumableEntryId({DateTime? now}) {
    if (entryId == null || closedAt == null) return entryId;
    final elapsed = (now ?? DateTime.now()).difference(closedAt!);
    return elapsed > kDrawerResumeWindow ? null : entryId;
  }
}

final drawerNavMemoryProvider = Provider<DrawerNavMemory>((ref) => DrawerNavMemory());
