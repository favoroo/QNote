import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/utils/diary_progress.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';

/// 每日完整度目标条数，默认 5。
///
/// 用 StateProvider 暴露，后续可接到设置页或 app_configs 做成可配置；
/// 当前版本先硬编码默认值，保持改动最小。
final dailyTargetProvider = StateProvider<int>((ref) => 5);

/// 今日完整度派生状态：监听日记列表与目标值，增删改后自动重算。
///
/// 数据源复用 [diaryListProvider] 的内存列表，不额外查库；
/// 计算本身是同步分组计数，量级小，无需 isolate。
final diaryProgressProvider = Provider<DiaryProgress>((ref) {
  final target = ref.watch(dailyTargetProvider);
  final records = ref.watch(diaryListProvider).valueOrNull ?? const [];
  return computeDiaryProgress(records, DateTime.now(), target: target);
});
