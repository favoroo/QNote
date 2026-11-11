import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/ai/vendor_logo.dart';

void main() {
  group('图标资源解析', () {
    test('有图标的厂商解析到 assets 路径，无图标的返回 null', () {
      expect(vendorIconAsset('deepseek'), 'assets/images/vendors/deepseek-color.svg');
      expect(vendorIconAsset('anthropic'), 'assets/images/vendors/claude-color.svg');
      // 蚂蚁百灵、小浣熊、Agnes 没有官方图标，界面走首字母兜底
      expect(vendorIconAsset('ant-ling'), isNull);
      expect(vendorIconAsset('raccoon'), isNull);
      expect(vendorIconAsset('custom'), isNull);
      expect(vendorIconAsset(null), isNull);
    });

    test('单色图标名单与资源文件内容一致（漏配会让深色模式下图标变黑看不见）', () {
      final dir = Directory('assets/images/vendors');
      expect(dir.existsSync(), isTrue);

      final actualMonochrome = <String>{};
      final allIcons = <String>{};
      for (final entity in dir.listSync()) {
        if (entity is! File || !entity.path.endsWith('.svg')) continue;
        final name = entity.uri.pathSegments.last.replaceAll('.svg', '');
        allIcons.add(name);
        // 单色图的判定口径：根节点用 fill="currentColor"，必须按主题色重着色
        if (entity.readAsStringSync().contains('currentColor')) {
          actualMonochrome.add(name);
        }
      }

      expect(allIcons, isNotEmpty);
      expect(monochromeVendorIcons.difference(actualMonochrome), isEmpty, reason: '名单里有文件其实不是单色图，会给彩色 logo 加错滤镜');
      expect(actualMonochrome.difference(monochromeVendorIcons), isEmpty, reason: '有单色图没登记，深色模式下会渲染成不可见的黑色');
    });
  });

  group('VendorLogo 渲染', () {
    Future<void> pump(WidgetTester tester, Widget child) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: child)),
        ),
      );
    }

    testWidgets('有图标的厂商用 SVG 渲染', (tester) async {
      await pump(tester, const VendorLogo(vendorId: 'deepseek'));
      expect(find.byType(SvgPicture), findsOneWidget);
    });

    testWidgets('无图标的厂商回落到名称首字母', (tester) async {
      await pump(tester, const VendorLogo(vendorId: 'ant-ling', fallbackLabel: '蚂蚁百灵 (AntLing)'));
      expect(find.byType(SvgPicture), findsNothing);
      expect(find.text('蚂'), findsOneWidget);
    });

    testWidgets('未知厂商 id 也能渲染，不留空白方块', (tester) async {
      await pump(tester, const VendorLogo(vendorId: 'not-exist', fallbackLabel: 'Xyz'));
      expect(find.text('X'), findsOneWidget);
    });

    testWidgets('停用态叠加灰度滤镜', (tester) async {
      await pump(tester, const VendorLogo(vendorId: 'deepseek', disabled: true));
      expect(find.byType(ColorFiltered), findsOneWidget);
    });
  });
}
