import 'dart:ui' show Offset, Size;

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/utils/q_bubble_layout.dart';

/// 悬浮小Q气泡的版式不变量。
///
/// 锁的是「气泡不能压住页面右下角功能按钮」这条只能靠真机才看得出的约束：
/// 时间线右下角是「智能提取」与「每日日记」两个 44 圆钮，气泡同样贴右边缘，
/// 底部间距一旦只按导航栏计算就会直接叠上去。
void main() {
  const phone = Size(390, 844);

  group('默认落点', () {
    test('底部间距必须越过导航栏 + 悬浮按钮行', () {
      const minimum = kQNavBarContentHeight + kQFloatingActionRowHeight;
      expect(kQBubbleDefaultBottomGap, greaterThan(minimum), reason: '气泡底边至少要高过按钮行顶部，否则会叠在智能提取按钮上');
    });

    test('气泡与智能提取按钮不重叠（同为右下角、同一 44 高度带）', () {
      const bottomInset = 34.0; // iPhone home indicator
      final position = defaultQBubblePosition(phone, bottomInset: bottomInset);
      final bubble = qBubbleRect(position);

      // 智能提取按钮：right 16、bottom = 安全区 + 12，直径 44
      final buttonBottom = phone.height - bottomInset - 12;
      final buttonTop = buttonBottom - kQFloatingActionRowHeight;

      expect(bubble.bottom, lessThan(buttonTop), reason: '气泡底边 ${bubble.bottom} 必须高于按钮顶边 $buttonTop');
      // 两个控件都贴右边缘，横向一定重叠，所以纵向必须让开
      expect(bubble.right, greaterThan(phone.width - 40));
    });

    test('气泡完整落在屏幕内', () {
      final position = defaultQBubblePosition(phone, bottomInset: 34);
      expect(position.dx, greaterThanOrEqualTo(0));
      expect(position.dy, greaterThanOrEqualTo(0));
      expect(position.dx + kQBubbleSize, lessThanOrEqualTo(phone.width));
      expect(position.dy + kQBubbleSize, lessThanOrEqualTo(phone.height));
    });

    test('触控尺寸不小于 44', () {
      expect(kQBubbleSize, greaterThanOrEqualTo(44));
      // 但要比原来的 56 更小，避免视觉上压过页面内容
      expect(kQBubbleSize, lessThan(56));
    });
  });

  group('可视区约束', () {
    test('拖到屏幕外会被拉回边界内', () {
      final clamped = clampQBubblePosition(const Offset(-100, -100), phone, topInset: 47, bottomInset: 34);
      expect(clamped.dx, kQBubbleEdgeMargin);
      expect(clamped.dy, 47 + kQBubbleEdgeMargin);

      final far = clampQBubblePosition(const Offset(9999, 9999), phone, topInset: 47, bottomInset: 34);
      expect(far.dx, phone.width - kQBubbleSize - kQBubbleEdgeMargin);
      expect(far.dy, phone.height - 34 - kQBubbleSize - kQBubbleEdgeMargin);
    });

    test('键盘弹起时上限抬到键盘之上', () {
      final clamped = clampQBubblePosition(const Offset(300, 700), phone, topInset: 0, bottomInset: 300);
      expect(clamped.dy + kQBubbleSize, lessThanOrEqualTo(phone.height - 300));
    });
  });

  group('贴边吸附', () {
    test('左半边吸左边缘、右半边吸右边缘，纵向不动', () {
      expect(snapQBubbleX(const Offset(40, 500), phone).dx, kQBubbleEdgeMargin);
      final right = snapQBubbleX(const Offset(300, 500), phone);
      expect(right.dx, phone.width - kQBubbleSize - kQBubbleEdgeMargin);
      expect(right.dy, 500);
    });
  });
}
