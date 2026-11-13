import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/ai/builtin_provider.dart';
import 'package:qnote_flutter/core/ai/builtin_service_config_service.dart';
import 'package:qnote_flutter/models/builtin_service_config.dart';
import 'package:qnote_flutter/widgets/ai/builtin_service_card.dart';

BuiltinServiceConfig _config({bool maintenance = false}) {
  return BuiltinServiceConfig(
    version: 1,
    updatedAtRaw: '2026-11-13T03:18:16Z',
    minAppVersion: '0.1.0',
    enabled: !maintenance,
    chat: const BuiltinCapability(
      enabled: true,
      model: BuiltinProvider.chatModelId,
      displayName: '小Q 免费模型',
      baseUrl: 'https://demo.trycloudflare.com/v1',
      contextWindow: 1048576,
      vision: true,
    ),
    image: const BuiltinCapability(enabled: false, model: BuiltinProvider.imageModelId, displayName: '小Q 免费生图'),
    maintenance: maintenance,
    maintenanceMessage: maintenance ? '维护中，请稍后' : '',
    signature: 'test',
  );
}

Future<void> _pumpCard(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(
      home: Scaffold(body: SingleChildScrollView(child: BuiltinServiceCard())),
    ),
  );
  await tester.pump();
}

void main() {
  final service = BuiltinServiceConfigService.instance;

  setUp(() {
    service.configNotifier.value = null;
    service.lastError.value = null;
    service.refreshing.value = false;
  });

  tearDown(() {
    service.configNotifier.value = null;
    service.lastError.value = null;
    service.refreshing.value = false;
  });

  testWidgets('可用状态显示标题、免费徽标与测试按钮', (tester) async {
    service.configNotifier.value = _config();
    await _pumpCard(tester);

    expect(find.text('小Q 内置服务'), findsOneWidget);
    expect(find.text('免费'), findsOneWidget);
    expect(find.text('可用'), findsOneWidget);
    expect(find.text('测试'), findsOneWidget);
    // 只读卡片：没有进入二级页面的箭头
    expect(find.byIcon(Icons.chevron_right_rounded), findsNothing);
  });

  testWidgets('无配置且无错误时显示获取中与重试', (tester) async {
    await _pumpCard(tester);

    expect(find.text('获取中'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
  });

  testWidgets('配置拉取失败时显示连接失败', (tester) async {
    service.lastError.value = '内置服务暂不可用';
    await _pumpCard(tester);

    expect(find.text('连接失败'), findsOneWidget);
    expect(find.text('内置服务暂不可用'), findsOneWidget);
  });

  testWidgets('维护中显示维护文案，测试按钮给出维护提示', (tester) async {
    service.configNotifier.value = _config(maintenance: true);
    await _pumpCard(tester);

    expect(find.text('维护中'), findsOneWidget);
    expect(find.text('维护中，请稍后'), findsOneWidget);

    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();
    expect(find.text('维护中，请稍后'), findsWidgets);
  });
}
