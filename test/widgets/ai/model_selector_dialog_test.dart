import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';

AiProvider _provider({
  required String id,
  required String name,
  required List<String> models,
  bool isDefault = false,
}) =>
    AiProvider(
      id: id,
      vendorId: 'custom',
      name: name,
      providerType: 'openai',
      baseUrl: 'https://example.com/v1',
      apiKeys: const ['sk-test'],
      models: models.map((m) => AiProviderModel.of(m)).toList(),
      isDefault: isDefault,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 打开共享模型选择器并点击指定文本，返回弹出结果
Future<ModelPickerResult?> _openAndTap(
  WidgetTester tester, {
  required List<AiProvider> providers,
  required AiModelRef? selected,
  String? tapText,
  bool allowUnbind = false,
}) async {
  ModelPickerResult? popped;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                popped = await showModelPickerSheet(
                  context,
                  providers: providers,
                  selected: selected,
                  allowUnbind: allowUnbind,
                );
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
  if (tapText != null) {
    await tester.tap(find.text(tapText).last);
    await tester.pumpAndSettle();
  }
  return popped;
}

void main() {
  testWidgets('按厂商分组展示已启用模型，点击返回厂商+模型引用', (tester) async {
    final providers = [
      _provider(id: 'p1', name: '我的中转', models: ['model-a', 'model-b']),
      _provider(id: 'p2', name: '官方 OpenRouter', models: ['model-c']),
    ];

    final result = await _openAndTap(
      tester,
      providers: providers,
      selected: null,
      tapText: 'model-b',
    );

    expect(result, isNotNull);
    expect(result!.ref, const AiModelRef(providerId: 'p1', modelName: 'model-b'));
    // 分组标题只显示厂商名，不重复「内置」语义
    expect(find.text('我的中转'), findsNothing);
    expect(find.text('官方 OpenRouter'), findsNothing);
  });

  testWidgets('没有任何已启用模型时显示空态引导', (tester) async {
    await _openAndTap(tester, providers: const [], selected: null);

    expect(find.text('还没有可用的 AI 模型'), findsOneWidget);
    expect(find.text('去添加模型'), findsOneWidget);
  });

  testWidgets('允许 unbind 时展示「跟随默认模型」选项', (tester) async {
    final providers = [
      _provider(id: 'p1', name: '默认厂商', models: ['model-a'], isDefault: true),
    ];

    final result = await _openAndTap(
      tester,
      providers: providers,
      selected: const AiModelRef(providerId: 'p1', modelName: 'model-a'),
      tapText: '跟随默认模型',
      allowUnbind: true,
    );

    expect(result, isNotNull);
    expect(result!.ref, isNull, reason: '选择「跟随默认」应返回 null 引用');
  });

  test('aiModelDisplayName 按厂商名 + 模型名展示，缺失时回落裸模型名', () {
    final providers = [
      _provider(id: 'p1', name: '我的中转', models: ['model-a']),
    ];
    expect(
      aiModelDisplayName(
        const AiModelRef(providerId: 'p1', modelName: 'model-a'),
        providers,
      ),
      '我的中转 · model-a',
    );
    expect(
      aiModelDisplayName(
        const AiModelRef(providerId: 'gone', modelName: 'model-x'),
        providers,
      ),
      'model-x',
    );
    expect(aiModelDisplayName(null, providers), '未配置模型');
  });
}