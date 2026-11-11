import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

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
    expect(find.text('本地部署'), findsWidgets);
    expect(find.text('DeepSeek'), findsOneWidget);
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
    await tester.tap(find.text('本地部署').first);
    await tester.pumpAndSettle();

    expect(find.text('Ollama（本机）'), findsOneWidget);
    expect(find.text('LM Studio（本机）'), findsOneWidget);
    expect(find.text('DeepSeek'), findsNothing);
  });

  testWidgets('点击厂商回传模板 id 并关闭弹层', (tester) async {
    final harness = await _pumpHarness(tester, selectedId: 'openai');
    await _open(tester);

    await tester.tap(find.text('DeepSeek'));
    await tester.pumpAndSettle();

    expect(find.text('选择厂商'), findsNothing);
    expect(harness.picked, 'deepseek');
  });
}
