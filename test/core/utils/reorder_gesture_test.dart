import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/reorder_gesture.dart';

void main() {
  group('useDragHandleFor', () {
    test('桌面与 Web 平台沿用行尾手柄（鼠标按下即拖）', () {
      expect(useDragHandleFor(TargetPlatform.macOS), isTrue);
      expect(useDragHandleFor(TargetPlatform.windows), isTrue);
      expect(useDragHandleFor(TargetPlatform.linux), isTrue);
    });

    test('移动端走整行长按拾起', () {
      expect(useDragHandleFor(TargetPlatform.iOS), isFalse);
      expect(useDragHandleFor(TargetPlatform.android), isFalse);
      expect(useDragHandleFor(TargetPlatform.fuchsia), isFalse);
    });
  });

  group('isLongPressRelease', () {
    test('原地抬手才算长按：没移动、也没落到别的行', () {
      expect(isLongPressRelease(pointerMoved: false, landedElsewhere: false), isTrue);
    });

    test('手指移动过就不算长按，松手不应弹菜单', () {
      expect(isLongPressRelease(pointerMoved: true, landedElsewhere: false), isFalse);
    });

    test('落到别的行上说明发生了排序，不算长按', () {
      expect(isLongPressRelease(pointerMoved: false, landedElsewhere: true), isFalse);
      expect(isLongPressRelease(pointerMoved: true, landedElsewhere: true), isFalse);
    });
  });

  group('resolveReorderDropPosition', () {
    test('笔记行按上下各半判定前后插入', () {
      expect(resolveReorderDropPosition(localY: 19, rowHeight: 40, allowsInside: false), ReorderDropPosition.before);
      expect(resolveReorderDropPosition(localY: 20, rowHeight: 40, allowsInside: false), ReorderDropPosition.after);
      expect(resolveReorderDropPosition(localY: 39, rowHeight: 40, allowsInside: false), ReorderDropPosition.after);
    });

    test('文件夹行中间 56% 判定为移入文件夹', () {
      // 行高 44：上下各 9.68px 为插入带，中间为 inside
      expect(resolveReorderDropPosition(localY: 5, rowHeight: 44, allowsInside: true), ReorderDropPosition.before);
      expect(resolveReorderDropPosition(localY: 22, rowHeight: 44, allowsInside: true), ReorderDropPosition.inside);
      expect(resolveReorderDropPosition(localY: 40, rowHeight: 44, allowsInside: true), ReorderDropPosition.after);
    });

    test('越界坐标先裁剪，行高为 0 时按插到后面兜底', () {
      expect(resolveReorderDropPosition(localY: -100, rowHeight: 44, allowsInside: true), ReorderDropPosition.before);
      expect(resolveReorderDropPosition(localY: 1000, rowHeight: 44, allowsInside: true), ReorderDropPosition.after);
      expect(resolveReorderDropPosition(localY: 10, rowHeight: 0, allowsInside: true), ReorderDropPosition.after);
    });
  });
}
