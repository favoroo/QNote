import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/reasoning_effort.dart';
import 'package:qnote_flutter/widgets/ai/model_effort_levels_sheet.dart';

/// 打开档位配置面板；结果通过回调带出（弹层关闭后才知道用户选了「完成」还是取消）
Future<void> _openSheet(
  WidgetTester tester, {
  required String modelName,
  String providerType = 'openai',
  String? vendorId,
  List<ReasoningEffort>? customLevels,
  required void Function(ModelEffortLevelsSelection?) onResult,
}) async {
  // 7 个档位 + 头部/底部，默认 800x600 视口装不下
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                final result = await showModelEffortLevelsSheet(
                  context,
                  modelName: modelName,
                  providerType: providerType,
                  vendorId: vendorId,
                  customLevels: customLevels,
                );
                onResult(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// 某个档位行的勾选状态
bool? _checked(WidgetTester tester, String label) =>
    tester.widget<CheckboxListTile>(find.widgetWithText(CheckboxListTile, label)).value;

void main() {
  testWidgets('默认勾选自动识别档位，minimal/xhigh/max 默认不勾', (tester) async {
    await _openSheet(tester, modelName: 'gpt-5.4-mini', onResult: (_) {});

    expect(find.text('自动识别'), findsOneWidget);
    expect(_checked(tester, '关闭'), isTrue);
    expect(_checked(tester, '低'), isTrue);
    expect(_checked(tester, '中'), isTrue);
    expect(_checked(tester, '高'), isTrue);
    expect(_checked(tester, '最少'), isFalse);
    expect(_checked(tester, '极高'), isFalse);
    expect(_checked(tester, '最高'), isFalse);
  });

  testWidgets('勾选额外档位后完成，返回按由弱到强排序的集合', (tester) async {
    ModelEffortLevelsSelection? result;
    await _openSheet(tester, modelName: 'gpt-5.4-mini', onResult: (value) => result = value);

    await tester.tap(find.text('最少'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('极高'));
    await tester.pumpAndSettle();
    // 标题徽标切成「自定义」
    expect(find.text('自定义'), findsOneWidget);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(result?.customLevels, [
      ReasoningEffort.none,
      ReasoningEffort.minimal,
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
      ReasoningEffort.xhigh,
    ]);
  });

  testWidgets('取消勾选当前自动识别里的档位，保存为自定义集合', (tester) async {
    ModelEffortLevelsSelection? result;
    await _openSheet(tester, modelName: 'gpt-5.4-mini', onResult: (value) => result = value);

    await tester.tap(find.text('低'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(result?.customLevels, [ReasoningEffort.none, ReasoningEffort.medium, ReasoningEffort.high]);
  });

  testWidgets('已有自定义集合时可直接恢复自动识别', (tester) async {
    ModelEffortLevelsSelection? result;
    await _openSheet(
      tester,
      modelName: 'gpt-5.4-mini',
      customLevels: [ReasoningEffort.minimal, ReasoningEffort.xhigh],
      onResult: (value) => result = value,
    );

    expect(find.text('自定义'), findsOneWidget);
    expect(_checked(tester, '最少'), isTrue);
    expect(_checked(tester, '极高'), isTrue);

    await tester.tap(find.text('恢复自动识别'));
    await tester.pumpAndSettle();
    expect(find.text('自动识别'), findsOneWidget);
    expect(_checked(tester, '低'), isTrue);

    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    expect(result, isNotNull);
    expect(result!.customLevels, isNull);
  });

  testWidgets('至少保留一个档位：清空后完成不可点', (tester) async {
    await _openSheet(tester, modelName: 'gpt-5.4-mini', onResult: (_) {});

    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();

    expect(find.text('至少保留一个档位，或恢复自动识别'), findsOneWidget);
    final done = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '完成'));
    expect(done.onPressed, isNull);

    // 恢复自动识别后又能保存
    await tester.tap(find.text('恢复自动识别'));
    await tester.pumpAndSettle();
    final restored = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '完成'));
    expect(restored.onPressed, isNotNull);
  });

  testWidgets('全选可一键勾满全部档位', (tester) async {
    await _openSheet(tester, modelName: 'gpt-5.4-mini', onResult: (_) {});

    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();

    for (final effort in ReasoningEffort.values) {
      expect(_checked(tester, effort.label), isTrue, reason: effort.label);
    }
    // 当前已是全选，快捷按钮置灰
    final all = tester.widget<TextButton>(find.widgetWithText(TextButton, '全选'));
    expect(all.onPressed, isNull);
  });

  testWidgets('GLM 也能勾选低/中/高，默认四档', (tester) async {
    await _openSheet(tester, modelName: 'glm-4.6', vendorId: 'zhipu', onResult: (_) {});

    for (final label in ['关闭', '低', '中', '高', '最少', '极高', '最高']) {
      expect(find.widgetWithText(CheckboxListTile, label), findsOneWidget, reason: '$label 应可勾选');
    }
    expect(_checked(tester, '关闭'), isTrue);
    expect(_checked(tester, '低'), isTrue);
    expect(_checked(tester, '中'), isTrue);
    expect(_checked(tester, '高'), isTrue);
    expect(_checked(tester, '最少'), isFalse);
    expect(_checked(tester, '极高'), isFalse);
    expect(_checked(tester, '最高'), isFalse);
    // 每个档位都展示真实发送值，二值模型会附带 reasoning_effort
    expect(find.textContaining('thinking.type: enabled'), findsWidgets);
    expect(find.textContaining('reasoning_effort: medium'), findsOneWidget);
  });

  testWidgets('Gemini 3 默认低/高，其余档位也能自行勾选', (tester) async {
    await _openSheet(tester, modelName: 'gemini-3-flash-preview', providerType: 'gemini', onResult: (_) {});

    for (final label in ['关闭', '最少', '低', '中', '高', '极高', '最高']) {
      expect(find.widgetWithText(CheckboxListTile, label), findsOneWidget, reason: '$label 应可勾选');
    }
    expect(_checked(tester, '低'), isTrue);
    expect(_checked(tester, '高'), isTrue);
    expect(_checked(tester, '关闭'), isFalse);
    expect(_checked(tester, '中'), isFalse);
  });
}
