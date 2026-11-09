import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/models/ai_model_ref.dart';
import 'package:qnote_flutter/models/ai_provider.dart';
import 'package:qnote_flutter/models/ai_route_group.dart';
import 'package:qnote_flutter/widgets/ai/model_picker_sheet.dart';

AiProvider _provider({
  required String id,
  required String name,
  required List<String> models,
  bool isDefault = false,
  bool enabled = true,
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
      enabled: enabled,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 直接用带元数据的模型构造厂商条目（生图标识等）
AiProvider _providerOfModels({
  required String id,
  required String name,
  required List<AiProviderModel> models,
  bool isDefault = false,
  bool enabled = true,
}) =>
    AiProvider(
      id: id,
      vendorId: 'custom',
      name: name,
      providerType: 'openai',
      baseUrl: 'https://example.com/v1',
      apiKeys: const ['sk-test'],
      models: models,
      isDefault: isDefault,
      enabled: enabled,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

/// 打开共享模型选择器并点击指定文本，返回弹出结果
Future<ModelPickerResult?> _openAndTap(
  WidgetTester tester, {
  required List<AiProvider> providers,
  required AiModelRef? selected,
  List<AiRouteGroup> groups = const [],
  String? tapText,
  bool imageGeneration = false,
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
                  groups: groups,
                  selected: selected,
                  imageGeneration: imageGeneration,
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

  testWidgets('停用厂商的模型不出现在选择器里，全部停用时走空态引导', (tester) async {
    final providers = [
      _provider(id: 'p1', name: '已停用厂商', models: ['model-a'], enabled: false),
      _provider(id: 'p2', name: '在用厂商', models: ['model-b']),
    ];

    expect(enabledModelEntries(providers).map((e) => e.model.id), ['model-b']);

    await _openAndTap(
      tester,
      providers: providers,
      selected: null,
      tapText: 'model-b',
    );
    expect(find.text('已停用厂商'), findsNothing);
    expect(find.text('model-a'), findsNothing);

    // 只剩停用厂商时等同于「一个可用模型都没有」
    await _openAndTap(
      tester,
      providers: [_provider(id: 'p1', name: '已停用厂商', models: ['model-a'], enabled: false)],
      selected: null,
    );
    expect(find.text('还没有可用的 AI 模型'), findsOneWidget);
  });

  testWidgets('不再展示「跟随默认模型」选项，直接选择具体模型', (tester) async {
    final providers = [
      _provider(id: 'p1', name: '默认厂商', models: ['model-a'], isDefault: true),
    ];

    await _openAndTap(
      tester,
      providers: providers,
      selected: const AiModelRef(providerId: 'p1', modelName: 'model-a'),
    );

    // 确认已彻底移除「跟随默认模型」选项
    expect(find.text('跟随默认模型'), findsNothing);
    expect(find.text('使用默认厂商的首个已启用模型'), findsNothing);
  });

  testWidgets('路由组渲染在厂商分组之上，点击返回组引用', (tester) async {
    final providers = [
      _provider(id: 'p1', name: '我的中转', models: ['model-a', 'model-b']),
    ];
    final groups = [
      AiRouteGroup(
        id: 'g1',
        name: '主模型池',
        strategy: RouteStrategy.rotate,
        members: const [
          RouteGroupMember(providerId: 'p1', modelName: 'model-a'),
          RouteGroupMember(providerId: 'p1', modelName: 'model-b'),
        ],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    ];

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
                    groups: groups,
                    selected: null,
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

    expect(find.text('路由组'), findsOneWidget);
    expect(find.text('2 个模型 · 轮流'), findsOneWidget);

    await tester.tap(find.text('主模型池'));
    await tester.pumpAndSettle();

    expect(popped, isNotNull);
    expect(popped!.ref.isRouteGroup, isTrue);
    expect(popped!.ref, AiModelRef.routeGroup('g1'));
  });

  testWidgets('成员模型被停用的路由组仍可见但标出失效', (tester) async {
    final providers = [
      _provider(id: 'p1', name: '我的中转', models: ['model-a']),
    ];
    final groups = [
      AiRouteGroup(
        id: 'g1',
        name: '失效组',
        members: const [
          RouteGroupMember(providerId: 'gone', modelName: 'x'),
        ],
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    ];

    await _openAndTap(tester, providers: providers, groups: groups, selected: null);

    expect(find.text('轮流 · 模型均已停用'), findsOneWidget);
  });

  test('aiBindingDisplayName 区分路由组与具体模型', () {
    final providers = [
      _provider(id: 'p1', name: '我的中转', models: ['model-a']),
    ];
    final groups = [
      AiRouteGroup(
        id: 'g1',
        name: '主模型池',
        createdAt: DateTime(2026),
        updatedAt: DateTime(2026),
      ),
    ];

    expect(
      aiBindingDisplayName(AiModelRef.routeGroup('g1'), providers, groups),
      '主模型池',
    );
    expect(
      aiBindingDisplayName(
        const AiModelRef(providerId: 'p1', modelName: 'model-a'),
        providers,
        groups,
      ),
      '我的中转 · model-a',
    );
    expect(
      aiBindingDisplayName(AiModelRef.routeGroup('missing'), providers, groups),
      '未配置模型',
    );
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

  testWidgets('生图模式默认只列生图模型，对话模型不出现', (tester) async {
    final providers = [
      _providerOfModels(
        id: 'pLoomy',
        name: 'Loomy',
        models: [
          AiProviderModel.of(
            'deepseek-v4.1-flash',
            name: 'DeepSeek V4.1 Flash',
            supportsImageGeneration: false,
          ),
          AiProviderModel.of(
            'qwen-image-3.0-pro',
            name: 'qwen image 3.0 pro',
            supportsImageGeneration: true,
          ),
          AiProviderModel.of('auto', name: '自动 · 均衡'),
        ],
      ),
    ];

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
                    selected: null,
                    imageGeneration: true,
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

    expect(find.text('deepseek-v4.1-flash'), findsNothing);
    expect(find.text('自动 · 均衡'), findsNothing);
    // 筛选条给出切换入口与识别数量
    expect(find.text('仅看生图模型（1）'), findsOneWidget);

    await tester.tap(find.text('qwen image 3.0 pro'));
    await tester.pumpAndSettle();

    expect(popped!.ref.modelName, 'qwen-image-3.0-pro');
  });

  testWidgets('生图模式没有识别到模型时可一键显示全部模型', (tester) async {
    final providers = [
      _provider(id: 'p1', name: '我的中转', models: ['my-custom-model']),
    ];

    await _openAndTap(
      tester,
      providers: providers,
      selected: null,
      imageGeneration: true,
    );

    expect(find.text('未识别到生图模型'), findsOneWidget);
    expect(find.text('my-custom-model'), findsNothing);

    await tester.tap(find.text('显示全部模型'));
    await tester.pumpAndSettle();

    expect(find.text('未识别到生图模型'), findsNothing);
    expect(find.text('my-custom-model'), findsOneWidget);
  });

  testWidgets('已绑定但未识别为生图的模型仍显示，避免用户看不到当前选择', (tester) async {
    final providers = [
      _providerOfModels(
        id: 'p1',
        name: '我的中转',
        models: [
          AiProviderModel.of('custom-drawer', name: '自定义生图'),
          AiProviderModel.of('chat-model', name: '对话模型'),
        ],
      ),
    ];

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
                    selected: const AiModelRef(
                      providerId: 'p1',
                      modelName: 'custom-drawer',
                    ),
                    imageGeneration: true,
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

    expect(find.text('custom-drawer'), findsOneWidget);
    expect(find.text('chat-model'), findsNothing);
    expect(popped, isNull);
  });
}