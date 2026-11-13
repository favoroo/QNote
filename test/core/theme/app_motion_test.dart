import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';

void main() {
  Widget wrap(Widget child, {bool disableAnimations = false}) {
    return MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: MaterialApp(home: Scaffold(body: child)),
    );
  }

  group('AppMotion.duration 与 reduce', () {
    testWidgets('减弱动态效果开启时返回 zero，关闭时返回基准时长', (tester) async {
      late BuildContext normalCtx;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              normalCtx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(AppMotion.reduce(normalCtx), isFalse);
      expect(AppMotion.duration(normalCtx, AppDurations.medium), AppDurations.medium);

      late BuildContext reducedCtx;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              reducedCtx = context;
              return const SizedBox.shrink();
            },
          ),
          disableAnimations: true,
        ),
      );
      expect(AppMotion.reduce(reducedCtx), isTrue);
      expect(AppMotion.duration(reducedCtx, AppDurations.medium), Duration.zero);
    });
  });

  group('AppMotion 程序化滚动与翻页', () {
    testWidgets('animateScrollTo 在减弱动态效果下直接瞬跳且不触发零时长断言', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      late BuildContext capturedCtx;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              capturedCtx = context;
              return ListView.builder(
                controller: controller,
                itemCount: 30,
                itemBuilder: (_, index) => SizedBox(height: 60, child: Text('item_$index')),
              );
            },
          ),
          disableAnimations: true,
        ),
      );

      await AppMotion.animateScrollTo(controller, 180.0, context: capturedCtx);
      expect(controller.offset, 180.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets('animateScrollTo 正常模式下平滑滚动到目标偏移', (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      late BuildContext capturedCtx;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              capturedCtx = context;
              return ListView.builder(
                controller: controller,
                itemCount: 30,
                itemBuilder: (_, index) => SizedBox(height: 60, child: Text('item_$index')),
              );
            },
          ),
        ),
      );

      final future = AppMotion.animateScrollTo(controller, 240.0, context: capturedCtx);
      await tester.pump();
      expect(controller.offset, lessThan(240.0));

      await tester.pumpAndSettle();
      await future;
      expect(controller.offset, 240.0);
    });

    testWidgets('animateToPage 在减弱动态效果下直接切页且不触发零时长断言', (tester) async {
      final controller = PageController();
      addTearDown(controller.dispose);
      late BuildContext capturedCtx;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              capturedCtx = context;
              return PageView(
                controller: controller,
                children: const [
                  Center(child: Text('page_0')),
                  Center(child: Text('page_1')),
                ],
              );
            },
          ),
          disableAnimations: true,
        ),
      );

      await AppMotion.animateToPage(controller, 1, context: capturedCtx);
      await tester.pump();
      expect(controller.page, 1.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('AppMotion.showDialog 与路由过渡', () {
    testWidgets('showDialog 使用 PopupRoute 且支持正常开启与关闭回传值', (tester) async {
      late BuildContext capturedCtx;
      ModalRoute<dynamic>? dialogRoute;
      String? result;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              capturedCtx = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final future = AppMotion.showDialog<String>(
        context: capturedCtx,
        builder: (dialogCtx) {
          dialogRoute = ModalRoute.of(dialogCtx);
          return AlertDialog(
            title: const Text('测试弹窗'),
            actions: [TextButton(onPressed: () => Navigator.pop(dialogCtx, 'ok'), child: const Text('确定'))],
          );
        },
      );
      future.then((value) => result = value);

      await tester.pumpAndSettle();
      expect(find.text('测试弹窗'), findsOneWidget);
      expect(dialogRoute, isA<PopupRoute<dynamic>>());
      expect(dialogRoute?.reverseTransitionDuration, AppDurations.fast);

      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, 'ok');
      expect(find.text('测试弹窗'), findsNothing);
    });

    testWidgets('showDialog 在减弱动态效果下过渡时长为 zero', (tester) async {
      late BuildContext capturedCtx;
      ModalRoute<dynamic>? dialogRoute;

      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              capturedCtx = context;
              return const SizedBox.shrink();
            },
          ),
          disableAnimations: true,
        ),
      );

      AppMotion.showDialog<void>(
        context: capturedCtx,
        builder: (dialogCtx) {
          dialogRoute = ModalRoute.of(dialogCtx);
          return const AlertDialog(title: Text('零动效弹窗'));
        },
      );

      await tester.pump();
      expect(find.text('零动效弹窗'), findsOneWidget);
      expect(dialogRoute?.transitionDuration, Duration.zero);
      expect(dialogRoute?.reverseTransitionDuration, Duration.zero);
    });

    testWidgets('fadeRoute 与 galleryRoute 支持推进、设置 routeSettings 与退出', (tester) async {
      late BuildContext capturedCtx;
      await tester.pumpWidget(
        wrap(
          Builder(
            builder: (context) {
              capturedCtx = context;
              return const Text('home_page');
            },
          ),
        ),
      );

      Navigator.of(capturedCtx).push(
        AppMotion.fadeRoute(
          const Scaffold(body: Text('fade_subpage')),
          settings: const RouteSettings(name: 'sub'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('fade_subpage'), findsOneWidget);

      Navigator.of(capturedCtx).pop();
      await tester.pumpAndSettle();
      expect(find.text('home_page'), findsOneWidget);

      Navigator.of(capturedCtx).push(AppMotion.galleryRoute(const Scaffold(body: Text('gallery_page'))));
      await tester.pumpAndSettle();
      expect(find.text('gallery_page'), findsOneWidget);
    });
  });
}
