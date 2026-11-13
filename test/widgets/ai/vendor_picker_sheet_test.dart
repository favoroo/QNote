import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/config/ai_vendors.dart';
import 'package:qnote_flutter/widgets/ai/vendor_picker_sheet.dart';

/// 厂商选择器测试：锁「分组浏览 + 搜索直达」两条路径，以及选中回传。
///
/// 弹层里每个 tile 都有 SVG 图标，但这里只断言文本与回调，不校验图标渲染
/// （图标本身由 vendor_logo_test.dart 负责），避免把资产解码拉进 widget 测试。
class _Harness {
  /// 弹层关闭时回传的厂商模板 id
  String? picked;
}

Future<_Harness> _pumpHarness(WidgetTester tester, {String? selectedId}) async {
  final harness = _Harness();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                harness.picked = await VendorPickerSheet.show(context, selectedId: selectedId);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  return harness;
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开后展示搜索框、分组 chips 与全部厂商', (tester) async {
    await _pumpHarness(tester);
    await _open(tester);

    expect(find.text('选择厂商'), findsOneWidget);
    expect(find.text('搜索厂商或模型名'), findsOneWidget);
    // chips 与分区标题共用分组名，因此这里按「至少出现」断言
    expect(find.text('国内厂商'), findsWidgets);
    expect(find.text('聚合中转'), findsWidgets);
    expect(find.text('DeepSeek'), findsOneWidget);
  });

  testWidgets('卡片只显示名称，不再显示一行简介', (tester) async {
    await _pumpHarness(tester);
    await _open(tester);

    // 手机 2 列窄卡放不下「名称 + 简介」，简介已从卡片移除；
    // 但它仍参与搜索匹配（见 vendor_filter_test），需要时搜得到
    expect(find.text('DeepSeek'), findsOneWidget);
    expect(find.text('官方接口'), findsNothing);
  });

  testWidgets('窄屏下所有厂商卡片都能渲染且不溢出', (tester) async {
    // 高视口让 SliverGrid 一次性构建全部卡片，长名称 + 徽标的最坏组合也会被渲染；
    // 任何 RenderFlex 溢出都会让本测试直接抛异常
    tester.view.physicalSize = const Size(390, 6000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpHarness(tester);
    await _open(tester);

    for (final spec in aiProviders) {
      expect(find.text(spec.name), findsOneWidget, reason: '${spec.id} 未渲染');
    }
  });

  testWidgets('搜索按名称过滤，未命中的厂商消失', (tester) async {
    await _pumpHarness(tester);
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'qwen');
    await tester.pumpAndSettle();

    expect(find.text('Qwen（通义千问）'), findsOneWidget);
    expect(find.text('DeepSeek'), findsNothing);
  });

  testWidgets('搜索能命中中文别名与说明', (tester) async {
    await _pumpHarness(tester);
    await _open(tester);
    await tester.enterText(find.byType(TextField), '通义');
    await tester.pumpAndSettle();

    expect(find.text('Qwen（通义千问）'), findsOneWidget);
  });

  testWidgets('无匹配时给出空态与自定义入口提示', (tester) async {
    await _pumpHarness(tester);
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'zzz-not-exist');
    await tester.pumpAndSettle();

    expect(find.text('没有匹配的厂商'), findsOneWidget);
    expect(find.textContaining('自定义'), findsWidgets);
  });

  testWidgets('清空按钮恢复全部列表', (tester) async {
    await _pumpHarness(tester);
    await _open(tester);
    await tester.enterText(find.byType(TextField), 'zzz-not-exist');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的厂商'), findsOneWidget);

    await tester.tap(find.byTooltip('清空'));
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的厂商'), findsNothing);
    expect(find.text('DeepSeek'), findsOneWidget);
  });

  testWidgets('分类 chip 只展示该分组的厂商', (tester) async {
    await _pumpHarness(tester);
    await _open(tester);
    await tester.tap(find.text('聚合中转').first);
    await tester.pumpAndSettle();

    expect(find.text('OpenRouter'), findsOneWidget);
    expect(find.text('DeepSeek'), findsNothing);
  });

  testWidgets('点击厂商回传模板 id 并关闭弹层', (tester) async {
    final harness = await _pumpHarness(tester, selectedId: 'openai');
    await _open(tester);

    // 用置顶的「自定义」条目：它在首屏即可见，不必滚动（弹层里同时存在 chips
    // 与主列表两个 Scrollable，scrollUntilVisible 无法自动定位到后者）
    await tester.tap(find.text('自定义 (Custom)'));
    await tester.pumpAndSettle();

    expect(find.text('选择厂商'), findsNothing);
    expect(harness.picked, 'custom');
  });
}
