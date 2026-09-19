import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/widgets/ai/model_selector_dialog.dart';

AiConfig _config(String id, String name) => AiConfig(
      id: id,
      name: name,
      provider: 'openai',
      modelName: 'test-model',
      apiKey: 'key',
      baseUrl: 'https://example.com',
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 弹出 ModelSelectorDialog 并点击指定选项，返回 pop 传出的模型 id
Future<String?> _openAndTap(
  WidgetTester tester, {
  required List<AiConfig> configs,
  required String? activeModelId,
  required String tapText,
}) async {
  String? popped;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () async {
              popped = await showDialog<String>(
                context: context,
                builder: (_) => ModelSelectorDialog(
                  configs: configs,
                  activeModelId: activeModelId,
                ),
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(tapText).last);
  await tester.pumpAndSettle();
  return popped;
}

void main() {
  final customConfig = _config('cfg-1', '我的自定义模型');

  testWidgets('渲染内置模型与自定义配置项，自定义项带 provider/模型名副标题',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ModelSelectorDialog(
        configs: [customConfig],
        activeModelId: 'free:glm-5.2',
      ),
    ));

    expect(find.text('内置免费模型'), findsOneWidget);
    expect(find.text('Claude Sonnet 4.6'), findsOneWidget);
    expect(find.text('Gemini 3.8 Flash Medium Mix'), findsOneWidget);
    expect(find.text('Gemini 3.8 Flash High Mix'), findsOneWidget);
    expect(find.text('DeepSeek V4 Flash'), findsOneWidget);
    expect(find.text('自定义模型'), findsOneWidget);
    expect(find.text('我的自定义模型'), findsOneWidget);
    expect(find.text('openai / test-model'), findsOneWidget);
  });

  testWidgets('当前选中的内置模型高亮且仅一项 checked', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: ModelSelectorDialog(
        configs: const [],
        activeModelId: 'free:glm-5.2',
      ),
    ));

    final row = find.ancestor(
      of: find.text('GLM 5.2'),
      matching: find.byType(Row),
    ).first;
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
  });

  testWidgets('未绑定任何模型时哨兵值高亮默认免费模型', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: const ModelSelectorDialog(
        configs: [],
        activeModelId: '__free_model__',
      ),
    ));

    final row = find.ancestor(
      of: find.text('Gemini 3.5 Flash Lite Mix'),
      matching: find.byType(Row),
    ).first;
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.radio_button_checked),
      ),
      findsOneWidget,
    );
  });

  testWidgets('点击内置模型与自定义配置均返回对应 id', (tester) async {
    final builtinId = await _openAndTap(
      tester,
      configs: [customConfig],
      activeModelId: null,
      tapText: 'GLM 5.2',
    );
    expect(builtinId, 'free:glm-5.2');

    final customId = await _openAndTap(
      tester,
      configs: [customConfig],
      activeModelId: null,
      tapText: '我的自定义模型',
    );
    expect(customId, 'cfg-1');
  });

  test('内置候选按 3.5 Lite → 3.8 Low → Medium → High 顺序排列', () {
    final ids = kAssistantBuiltinModels.map((m) => m['id']).toList();
    final from = ids.indexOf('free:gemini-3.5-flash-lite-mix');
    final to = ids.indexOf('free:sensenova-flash-lite');
    expect(
      ids.sublist(from, to),
      const [
        'free:gemini-3.5-flash-lite-mix',
        'free:gemini-3.8-flash-low-mix',
        'free:gemini-3.8-flash-medium-mix',
        'free:gemini-3.8-flash-high-mix',
      ],
    );
  });

  test('assistantModelDisplayName：内置映射/裸 id 回退/自定义配置/哨兵/空值', () {
    expect(assistantModelDisplayName('free:glm-5.2', const []), 'GLM 5.2');
    expect(
      assistantModelDisplayName('free:unknown-model', const []),
      'unknown-model',
    );
    expect(
      assistantModelDisplayName('cfg-1', [customConfig]),
      '我的自定义模型',
    );
    expect(
      assistantModelDisplayName('__free_model__', const []),
      'Gemini 3.5 Flash Lite Mix',
    );
    expect(assistantModelDisplayName('missing', const []), 'missing');
    expect(assistantModelDisplayName(null, const []), isNull);
  });
}
