import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart' show ValueNotifier;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/diary_progress.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';

/// 每日完整度目标条数，默认 3。
///
/// 用 StateProvider 暴露，后续可接到设置页或 app_configs 做成可配置；
/// 当前版本先硬编码默认值，保持改动最小。
final dailyTargetProvider = StateProvider<int>((ref) => 3);

/// 今日完整度派生状态：监听日记列表与目标值，增删改后自动重算。
///
/// 数据源复用 [diaryListProvider] 的内存列表，不额外查库；
/// 计算本身是同步分组计数，量级小，无需 isolate。
///
/// 返回可空：列表尚未加载完时是 `null`（「还不知道今天记了几条」），
/// 而不是按空列表算出的 0 条。否则进 App 首帧的 0→真实条数跳变会被
/// 日记页的庆祝逻辑当成「用户刚刚记了一条」，每次冷启动都误弹一次横幅。
final diaryProgressProvider = Provider<DiaryProgress?>((ref) {
  final records = ref.watch(diaryListProvider).valueOrNull;
  if (records == null) {
    return null;
  }
  return computeDiaryProgress(records, DateTime.now(), target: ref.watch(dailyTargetProvider));
});

/// 记录坚持度汇总（统计页用）。
///
/// 依赖 [diaryListProvider] 的**全量**列表才能算出历史最长连续；
/// 注意 `diary_provider.dart` 的 `loadByDate()` 会把该列表换成单日子集，
/// 一旦被重新启用，这里的「最长连续 / 近30天」会静默缩水。
final streakSummaryProvider = Provider<StreakSummary>((ref) {
  final target = ref.watch(dailyTargetProvider);
  final records = ref.watch(diaryListProvider).valueOrNull ?? const [];
  return computeStreakSummary(records, DateTime.now(), target: target);
});

/// 「去统计页看连续记录」的一次性意图。
///
/// 日记页圆环与庆祝胶囊的「看看统计」置值，统计页消费后置回 null，
/// 口径同 [diaryScrollToTimeProvider]。
final streakFocusProvider = StateProvider<DateTime?>((ref) => null);

/// 今日完整度圆环的圆心（全局坐标），作为达标庆祝粒子的爆点。
///
/// 用 [ValueNotifier] 而不是 StateProvider：圆环在每次布局后都可能重算，
/// 换成 provider 状态会把整个日记页牵进重建链；粒子层只在自己动画的每帧
/// 读一次，互不打扰。
///
/// 初值为 null（圆环还没上过屏），粒子层此时回退到左下角的常规位置。
/// 圆环收起态/展开态各挂一份，由可见的那份写值。
final cheerAnchorProvider = Provider<ValueNotifier<Offset?>>((ref) {
  final anchor = ValueNotifier<Offset?>(null);
  ref.onDispose(anchor.dispose);
  return anchor;
});
