/// 批量提取完成后，底部确认栏「上一条 / 下一条」导航的状态。
///
/// 抽成纯函数是因为箭头可用性同时受「当前锚点」和「记录被撤回 / 删除」
/// 两条路径影响，放在页面 State 里容易漏掉边界。
class BatchReviewPosition {
  const BatchReviewPosition({required this.index, required this.canGoPrevious, required this.canGoNext});

  /// 当前锚定的记录下标；没有可回看的记录时为 -1。
  final int index;

  /// 是否可以跳到更早提取的记录。
  final bool canGoPrevious;

  /// 是否可以跳到更晚提取的记录。
  final bool canGoNext;
}

/// 根据记录数量与当前锚点计算箭头状态。
///
/// [currentIndex] 为 -1 表示尚未定位，此时默认锚定最后一条（批量结束时的
/// 视口位置通常就在最后一条附近）。
BatchReviewPosition resolveBatchReviewPosition({required int count, required int currentIndex}) {
  if (count <= 0) {
    return const BatchReviewPosition(index: -1, canGoPrevious: false, canGoNext: false);
  }
  final index = currentIndex < 0 ? count - 1 : currentIndex.clamp(0, count - 1);
  return BatchReviewPosition(index: index, canGoPrevious: index > 0, canGoNext: index < count - 1);
}

/// 撤回 / 删除某条已优化记录后，重新计算箭头锚点。
///
/// 删除当前锚点之前的记录时锚点左移；删除当前记录本身时停留在同一位置，
/// 自然指向后面那条；删到空列表时返回 -1。
int resolveBatchReviewIndexAfterRemoval({
  required int currentIndex,
  required int removedIndex,
  required int remainingCount,
}) {
  if (remainingCount <= 0) {
    return -1;
  }
  if (removedIndex < 0) {
    return resolveBatchReviewPosition(count: remainingCount, currentIndex: currentIndex).index;
  }

  // 未定位时默认指向末尾；删除任意一条后仍应是新的末尾。
  var next = currentIndex < 0 ? remainingCount : currentIndex;
  if (removedIndex < next) {
    next -= 1;
  }
  return next.clamp(0, remainingCount - 1);
}
