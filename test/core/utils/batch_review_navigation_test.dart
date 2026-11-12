import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/batch_review_navigation.dart';

void main() {
  group('resolveBatchReviewPosition', () {
    test('空列表没有可导航项', () {
      final position = resolveBatchReviewPosition(count: 0, currentIndex: 0);
      expect(position.index, -1);
      expect(position.canGoPrevious, isFalse);
      expect(position.canGoNext, isFalse);
    });

    test('唯一一条时两个方向都禁用', () {
      final position = resolveBatchReviewPosition(count: 1, currentIndex: 0);
      expect(position.index, 0);
      expect(position.canGoPrevious, isFalse);
      expect(position.canGoNext, isFalse);
    });

    test('未定位时默认落在最后一条，只能向前回看', () {
      final position = resolveBatchReviewPosition(count: 3, currentIndex: -1);
      expect(position.index, 2);
      expect(position.canGoPrevious, isTrue);
      expect(position.canGoNext, isFalse);
    });

    test('首尾位置的箭头状态', () {
      final first = resolveBatchReviewPosition(count: 3, currentIndex: 0);
      expect(first.canGoPrevious, isFalse);
      expect(first.canGoNext, isTrue);

      final last = resolveBatchReviewPosition(count: 3, currentIndex: 2);
      expect(last.canGoPrevious, isTrue);
      expect(last.canGoNext, isFalse);
    });

    test('越界下标自动收敛到有效范围', () {
      expect(resolveBatchReviewPosition(count: 3, currentIndex: 99).index, 2);
      expect(resolveBatchReviewPosition(count: 3, currentIndex: -5).index, 2);
    });
  });

  group('resolveBatchReviewIndexAfterRemoval', () {
    test('删除锚点之前的记录时锚点左移，仍指向同一条', () {
      expect(resolveBatchReviewIndexAfterRemoval(currentIndex: 2, removedIndex: 0, remainingCount: 2), 1);
    });

    test('删除当前记录时停留原下标，自然指向后一条', () {
      expect(resolveBatchReviewIndexAfterRemoval(currentIndex: 1, removedIndex: 1, remainingCount: 2), 1);
    });

    test('删除最后一条时回退到新的末尾', () {
      expect(resolveBatchReviewIndexAfterRemoval(currentIndex: 2, removedIndex: 2, remainingCount: 2), 1);
    });

    test('删空后返回 -1', () {
      expect(resolveBatchReviewIndexAfterRemoval(currentIndex: 0, removedIndex: 0, remainingCount: 0), -1);
    });

    test('未定位时删除记录仍指向新的末尾', () {
      expect(resolveBatchReviewIndexAfterRemoval(currentIndex: -1, removedIndex: 1, remainingCount: 2), 1);
    });

    test('移除不存在的记录时仅收敛当前下标', () {
      expect(resolveBatchReviewIndexAfterRemoval(currentIndex: 4, removedIndex: -1, remainingCount: 2), 1);
    });
  });
}
