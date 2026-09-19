import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/utils/chat_image_dedupe.dart';
import 'package:qnote_flutter/widgets/chat/chat_image_view.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

/// 把正文包进一层 MarkdownBody，并按小Q 主页的方式注入图片构建器。
Widget _bodyWithImages(String markdown, Set<String> generatedKeys) {
  return MaterialApp(
    home: Scaffold(
      body: MarkdownBody(
        data: markdown,
        selectable: false,
        sizedImageBuilder: (config) => ChatBodyImage(
          src: config.uri.toString(),
          generatedImageKeys: generatedKeys,
        ),
      ),
    ),
  );
}

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// 挂载图片视图并推进掉首帧的异步文件检查。
Future<void> _mount(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_wrap(child));
  await tester.pump();
}

/// 推进到浮层菜单动画结束。
///
/// 这里刻意不用 `pumpAndSettle`：`UnifiedImage` 用真实 `dart:io` 异步检查文件是否存在，
/// 加载态的 `CircularProgressIndicator` 在 fake-async 下永远不会停转；
/// 同样也不能包在 `runAsync` 里——真实时钟会让长按识别退化成点击。
Future<void> _settleMenu(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump();
}

void main() {
  group('ChatBodyImage 正文内联图去重', () {
    testWidgets('生图卡片已展示过的图片不再重复渲染，其他图片保留', (tester) async {
      const cardPath = '/documents/images/ai/gen-1.png';
      final keys = {imageKeyOf(cardPath)};
      await tester.pumpWidget(
        _bodyWithImages(
          '看图：\n\n![image]($cardPath)\n\n'
          '这是另一张已有笔记图：\n\n![note](/documents/images/other.png)',
          keys,
        ),
      );

      // 只剩未被卡片展示过的那张图
      expect(find.byType(ChatImageView), findsOneWidget);
      expect(find.textContaining('看图'), findsOneWidget);
    });

    testWidgets('去重集合为空时所有内联图都正常渲染', (tester) async {
      await tester.pumpWidget(
        _bodyWithImages(
          '![a](/x/a.png)\n\n![b](/x/b.png)',
          const <String>{},
        ),
      );
      expect(find.byType(ChatImageView), findsNWidgets(2));
    });
  });

  group('ChatImageView 交互', () {
    testWidgets('点击缩略图进入可翻页大图页', (tester) async {
      await _mount(
        tester,
        const ChatImageView(
          imagePath: '/x/b.png',
          galleryImages: ['/x/a.png', '/x/b.png'],
          galleryIndex: 1,
          width: 60,
          height: 60,
        ),
      );

      await tester.tap(find.byType(ChatImageView));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();

      expect(find.byType(FullScreenImageGallery), findsOneWidget);
      // 定位到被点击的那张图，且支持多图翻页计数
      expect(find.text('2 / 2'), findsOneWidget);
    });

    testWidgets('长按弹出菜单，未提供「给小Q」回调时不显示该项', (tester) async {
      await _mount(
        tester,
        const ChatImageView(imagePath: '/x/a.png', width: 60, height: 60),
      );

      await tester.longPress(find.byType(ChatImageView));
      await _settleMenu(tester);

      expect(find.text('查看大图'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('复制路径'), findsOneWidget);
      expect(find.text('给小Q'), findsNothing);
    });

    testWidgets('提供「给小Q」回调时菜单出现该项', (tester) async {
      await _mount(
        tester,
        ChatImageView(
          imagePath: '/x/a.png',
          width: 60,
          height: 60,
          onSendToQ: (_) {},
        ),
      );

      await tester.longPress(find.byType(ChatImageView));
      await _settleMenu(tester);

      expect(find.text('给小Q'), findsOneWidget);
    });

    testWidgets('Web 端 data URI 形态不显示「复制路径」', (tester) async {
      await _mount(
        tester,
        const ChatImageView(
          imagePath: 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg',
          width: 60,
          height: 60,
        ),
      );

      await tester.longPress(find.byType(ChatImageView));
      await _settleMenu(tester);

      expect(find.text('下载'), findsOneWidget);
      expect(find.text('复制路径'), findsNothing);
    });
  });
}
