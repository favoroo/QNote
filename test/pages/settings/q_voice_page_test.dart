import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/services/q_voice_config.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/tts/tts_player.dart';
import 'package:qnote_flutter/pages/settings/q_voice_page.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 语速弹窗：选中即试播、弹窗保持打开。
///
/// 坑位记录（同 auto_read_toggle_button_test）：testWidgets 跑在 FakeAsync 区，
/// sqflite 的真实 IO 回调不会被 pump 冲刷，因此所有触库动作都要包 [WidgetTester.runAsync]，
/// 且配置缓存由 setUp（真实区）预热，页面 initState 的读库才能同步命中。
///
/// 另一个坑：flutter test 并发跑多个文件，默认库目录（.dart_tool/sqflite_common_ffi/databases）
/// 下的 qnote.db 是共享的，而本文件与 auto_read_toggle_button_test 都写 app_configs 的
/// q_voice 行——整块 JSON 读-改-写会互相覆盖（表现为对面那项偶发"autoRead 期望 true 实为 false"）。
/// 所以这里把库目录换成本文件独占的临时目录。
class _FakeTtsPlayer extends TtsPlayer {
  /// 依次记录的试听任务（messageId, rateOverride）
  final List<String> previewKeys = [];
  final List<double?> rateOverrides = [];
  int stopCount = 0;

  @override
  TtsPlaybackState build() => TtsPlaybackState.idle;

  @override
  Future<void> speakMessage(
    String messageId,
    String text, {
    String? voiceOverride,
    double? rateOverride,
  }) async {
    previewKeys.add(messageId);
    rateOverrides.add(rateOverride);
    // 真实播放器会先合成再播放；这里直接置为播放中，让"同一条不重复触发"
    // 与"关闭弹窗停止试听"两条逻辑可被观测
    state = TtsPlaybackState(
      messageId: messageId,
      status: TtsPlaybackStatus.playing,
    );
  }

  @override
  Future<void> stop() async {
    stopCount++;
    state = TtsPlaybackState.idle;
  }
}

Finder _sheetTile(WidgetTester tester, String label) => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.widgetWithText(ListTile, label),
);

/// 弹窗里的档位名本身（不含 '0.8 倍速' 那行副标题）
Finder _sheetLabel(WidgetTester tester, String label) => find.descendant(
  of: find.byType(BottomSheet),
  matching: find.text(label),
);

late _FakeTtsPlayer _player;

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ttsPlaybackProvider.overrideWith(() => _player = _FakeTtsPlayer()),
      ],
      child: const MaterialApp(
        home: Scaffold(body: QVoicePage(embedded: true)),
      ),
    ),
  );
  await tester.pump();
}

/// 打开语速弹窗
Future<void> _openRateSheet(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(ListTile, '语速'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

/// 点弹窗里的某个语速档位，并轮询到该次点击的异步后果落定
///
/// 落库要过真实 IO，固定等待在多文件并发跑时会偶发不够（试播还没被触发就断言），
/// 因此按条件轮询；命中后再多等一小段，让迟到的额外触发也暴露出来。
Future<void> _tapRate(
  WidgetTester tester,
  String label,
  Future<bool> Function() settled,
) => tester.runAsync(() async {
  await tester.tap(_sheetTile(tester, label));
  for (var i = 0; i < 80; i++) {
    if (await settled()) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  fail('等待语速档位「$label」生效超时');
});

void main() {
  late Directory dbDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    dbDir = Directory.systemTemp.createTempSync('qnote_q_voice_page_test');
    await databaseFactoryFfi.setDatabasesPath(dbDir.path);
    await DatabaseHelper.instance.database;
  });

  tearDownAll(() {
    // DatabaseHelper 没有关库入口， unlink 后连接仍指向该 inode，进程退出即回收
    try {
      dbDir.deleteSync(recursive: true);
    } catch (_) {
      // 临时目录清理失败不影响测试结论
    }
  });

  setUp(() async {
    // 预热缓存并固定起点：快速档，与截图里的初始状态一致
    await QVoiceConfig.instance.setRate(1.2);
  });

  tearDown(() async {
    await QVoiceConfig.instance.setRate(1.0);
  });

  group('语速选择弹窗', () {
    testWidgets('选中档位后弹窗不关闭，并以新语速试播', (tester) async {
      await _pumpPage(tester);
      await _openRateSheet(tester);
      expect(find.text('选择语速'), findsOneWidget);

      await _tapRate(tester, '慢速', () async => _player.previewKeys.length == 1);
      await tester.pump();

      expect(
        find.text('选择语速'),
        findsOneWidget,
        reason: '选中后弹窗应保持打开，供连续试听对比',
      );
      expect(_player.previewKeys, ['preview_rate_0.8']);
      expect(_player.rateOverrides, [0.8]);
      expect((await QVoiceConfig.instance.get()).rate, 0.8);

      // 勾选移到慢速行
      expect(
        find.descendant(
          of: _sheetTile(tester, '慢速'),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _sheetTile(tester, '快速'),
          matching: find.byIcon(Icons.check_circle),
        ),
        findsNothing,
      );
    });

    testWidgets('重复点击正在试播的档位改为停播，不另起一次播放', (tester) async {
      await _pumpPage(tester);
      await _openRateSheet(tester);

      await _tapRate(tester, '慢速', () async => _player.previewKeys.length == 1);
      await tester.pump();
      expect(_player.stopCount, 0);

      await _tapRate(tester, '慢速', () async => _player.stopCount == 1);
      await tester.pump();

      expect(_player.previewKeys, ['preview_rate_0.8']);
      expect(_player.stopCount, 1);
    });

    testWidgets('档位名居中，选中前后不左右挪位', (tester) async {
      await _pumpPage(tester);
      await _openRateSheet(tester);

      double labelCenterX(String label) =>
          tester.getCenter(_sheetLabel(tester, label)).dx;
      final panelCenterX = tester.getRect(find.byType(BottomSheet)).center.dx;

      // 三档横向中心一致，且落在面板正中。ListTile 在标题与行尾控件之间还留了一道
      // 8px 间隙，正中会偏左几像素，因此这里只按"明显居中"卡，不逐像素对齐；
      // 逐像素要卡的是下面那条"选中前后不挪位"。
      double? firstCenter;
      for (final label in ['慢速', '正常', '快速']) {
        final center = labelCenterX(label);
        expect(
          center,
          closeTo(panelCenterX, 8),
          reason: '$label 应居中，而不是被行首控件挤到左边',
        );
        firstCenter ??= center;
        expect(center, closeTo(firstCenter, 0.5), reason: '$label 与其他档位不同心');
      }

      final before = labelCenterX('慢速');
      await _tapRate(tester, '慢速', () async => _player.previewKeys.length == 1);
      await tester.pump();

      // 勾选图标是常驻占位槽里的内容，不该把档位名挤走（旧版正是这里会跳位）
      expect(labelCenterX('慢速'), closeTo(before, 0.5));
      expect(labelCenterX('快速'), closeTo(firstCenter!, 0.5));
    });

    testWidgets('切换到另一档位时改播新语速', (tester) async {
      await _pumpPage(tester);
      await _openRateSheet(tester);

      await _tapRate(tester, '慢速', () async => _player.previewKeys.length == 1);
      await tester.pump();
      await _tapRate(
        tester,
        '正常',
        () async => _player.previewKeys.length == 2,
      );
      await tester.pump();

      expect(_player.previewKeys, ['preview_rate_0.8', 'preview_rate_1.0']);
      expect(_player.rateOverrides, [0.8, 1.0]);
    });

    testWidgets('关闭弹窗时停掉在播的试听', (tester) async {
      await _pumpPage(tester);
      await _openRateSheet(tester);
      await _tapRate(tester, '慢速', () async => _player.previewKeys.length == 1);
      await tester.pump();
      expect(_player.stopCount, 0);

      await tester.tapAt(const Offset(400, 20));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(_player.stopCount, 1);
    });
  });
}
