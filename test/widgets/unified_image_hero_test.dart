import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/chat/chat_image_view.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

void main() {
  // 1x1 透明 PNG（base64 数据 URI），可在测试里脱离本地文件系统稳定解码
  const tinyPngDataUri =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==';

  group('FullScreenImageGallery Hero 过渡', () {
    testWidgets('同一张图片出现多次时各自持有唯一 Hero tag 且点击查看大图无冲突', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                ChatImageView(
                  imagePath: tinyPngDataUri,
                  galleryImages: [tinyPngDataUri, tinyPngDataUri],
                  galleryIndex: 0,
                  width: 60,
                  height: 60,
                ),
                ChatImageView(
                  imagePath: tinyPngDataUri,
                  galleryImages: [tinyPngDataUri, tinyPngDataUri],
                  galleryIndex: 1,
                  width: 60,
                  height: 60,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      final heroes = tester.widgetList<Hero>(find.byType(Hero)).toList();
      expect(heroes, hasLength(2));
      expect(identical(heroes[0].tag, heroes[1].tag), isFalse);

      // 点击第一张缩略图弹出 FullScreenImageGallery，不应触发重复 Hero tag 异常；
      // 图片在测试环境解码期间可能有加载指示器常驻帧，用显式时长推进路由与 Hero 动画。
      await tester.tap(find.byType(ChatImageView).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.byType(FullScreenImageGallery), findsOneWidget);
      expect(find.text('1 / 2'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // 返回原页时反向 Hero 过渡也应平稳完成且无异常
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(FullScreenImageGallery), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('减弱动态效果开启时禁用 HeroMode', (tester) async {
      final tag = Object();

      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: MaterialApp(
            home: FullScreenImageGallery(images: const [tinyPngDataUri], heroTags: [tag]),
          ),
        ),
      );
      await tester.pump();

      final heroMode = tester.widget<HeroMode>(find.byType(HeroMode));
      expect(heroMode.enabled, isFalse);
      expect(tester.takeException(), isNull);
    });
  });
}
