import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/widgets/ai/auto_read_toggle_button.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 小Q对话界面右上角的自动朗读开关：图标两态、点击落库、与配置真源双向同步。
///
/// 坑位记录：testWidgets 跑在 FakeAsync 区内，sqflite 的真实 IO 回调不会被
/// pump 冲刷，因此测试里所有触库动作（预置开关、点击写库、查库核对）都必须包在
/// [WidgetTester.runAsync] 内，否则测试直接挂死；开关缓存则由 setUp（真实区）
/// 预热，按钮 initState 的读库才是同步命中。
Icon _toggleIcon(WidgetTester tester) => tester.widget<Icon>(
  find.descendant(
    of: find.byType(AutoReadToggleButton),
    matching: find.byType(Icon),
  ),
);

Future<void> _pumpButton(WidgetTester tester) async {
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: AutoReadToggleButton())),
  );
  await tester.pump();
}

/// 测试内预置开关（写库，须在真实区执行）
Future<void> _preset(WidgetTester tester, bool enabled) =>
    tester.runAsync(() => QVoiceConfig.instance.setAutoRead(enabled));

/// 点击开关并等库写入完成
Future<void> _tap(WidgetTester tester) => tester.runAsync(() async {
  await tester.tap(find.byType(AutoReadToggleButton));
  await Future<void>.delayed(const Duration(milliseconds: 150));
});

/// 绕开内存缓存直接查 app_configs，确认写入真的落库
Future<Object?> _storedAutoRead(WidgetTester tester) =>
    tester.runAsync(() async {
      final db = await DatabaseHelper.instance.database;
      final rows = await db.query(
        'app_configs',
        where: 'key = ?',
        whereArgs: [QVoiceConfig.storageKey],
      );
      expect(rows, isNotEmpty, reason: 'app_configs 里应有 q_voice 记录');
      final map = jsonDecode(rows.first['value'] as String);
      return (map as Map<String, dynamic>)['autoRead'];
    });

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    await DatabaseHelper.instance.database;
  });

  setUp(() async {
    // 预热缓存：按钮 initState 的 get() 由此同步命中，testWidgets 内不再触库
    await QVoiceConfig.instance.setAutoRead(false);
  });

  group('AutoReadToggleButton', () {
    testWidgets('关闭态显示 volume_off 图标', (tester) async {
      await _pumpButton(tester);
      expect(_toggleIcon(tester).icon, Icons.volume_off_rounded);
    });

    testWidgets('配置里已开启时渲染 volume_up 图标', (tester) async {
      await _preset(tester, true);
      await _pumpButton(tester);
      expect(_toggleIcon(tester).icon, Icons.volume_up_rounded);
    });

    testWidgets('点击一次即开启并落库', (tester) async {
      await _pumpButton(tester);
      await _tap(tester);
      await tester.pump();

      expect(_toggleIcon(tester).icon, Icons.volume_up_rounded);
      expect(await _storedAutoRead(tester), isTrue);
      expect(await QVoiceConfig.instance.isAutoReadEnabled(), isTrue);
    });

    testWidgets('再点一次回到关闭态', (tester) async {
      await _preset(tester, true);
      await _pumpButton(tester);
      await _tap(tester);
      await tester.pump();

      expect(_toggleIcon(tester).icon, Icons.volume_off_rounded);
      expect(await _storedAutoRead(tester), isFalse);
    });

    testWidgets('语音设置页等其他入口改动后图标同步刷新', (tester) async {
      await _pumpButton(tester);
      expect(_toggleIcon(tester).icon, Icons.volume_off_rounded);

      // 模拟设置页拨动 Switch：按钮无需重建也应跟着变（同一 ValueNotifier）
      await _preset(tester, true);
      await tester.pump();
      expect(_toggleIcon(tester).icon, Icons.volume_up_rounded);

      await _preset(tester, false);
      await tester.pump();
      expect(_toggleIcon(tester).icon, Icons.volume_off_rounded);
    });
  });

  group('QVoiceConfig 自动朗读开关', () {
    test('toggleAutoRead 翻转并返回翻转后的值', () async {
      await QVoiceConfig.instance.setAutoRead(false);
      expect(await QVoiceConfig.instance.toggleAutoRead(), isTrue);
      expect(await QVoiceConfig.instance.isAutoReadEnabled(), isTrue);
      expect(QVoiceConfig.instance.autoReadState.value, isTrue);

      expect(await QVoiceConfig.instance.toggleAutoRead(), isFalse);
      expect(await QVoiceConfig.instance.isAutoReadEnabled(), isFalse);
      expect(QVoiceConfig.instance.autoReadState.value, isFalse);
    });

    test('保存语速不会串改自动朗读开关', () async {
      await QVoiceConfig.instance.setAutoRead(true);
      await QVoiceConfig.instance.setRate(1.2);
      final settings = await QVoiceConfig.instance.get();
      expect(settings.rate, 1.2);
      expect(settings.autoRead, isTrue);
      expect(QVoiceConfig.instance.autoReadState.value, isTrue);

      // 复原，避免污染其他用例
      await QVoiceConfig.instance.setRate(1.0);
      await QVoiceConfig.instance.setAutoRead(false);
    });
  });
}
