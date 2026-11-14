import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/widgets/diary/diary_item.dart';

DiaryRecord _healthRecord({
  required List<Map<String, dynamic>> topApps,
  int steps = 0,
  int screenTimeMs = 131 * 60000,
  int? yesterdayTimeMs = 512 * 60000,
}) {
  return DiaryRecord(
    id: 'health_1',
    title: '运动健康',
    time: DateTime(2026, 11, 13, 23, 0),
    content: '步数 $steps',
    createdAt: DateTime(2026, 11, 13, 23, 0),
    updatedAt: DateTime(2026, 11, 13, 23, 0),
    bodyState: {
      'source': 'mi_fitness',
      'type': 'daily_summary',
      'date': '2026-11-13',
      'steps': steps,
      'step_target': 8000,
      'distance_meters': 1340.0,
      'calories': 121.0,
      'active_minutes': 40,
      'standing_count': 5,
      'screen_time_ms': screenTimeMs,
      'screen_yesterday_time_ms': ?yesterdayTimeMs,
      'screen_top_apps': topApps,
    },
  );
}

Widget _wrap(DiaryRecord record, {double width = 412, Brightness brightness = Brightness.dark}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness, useMaterial3: true),
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: ListView(children: [DiaryItem(record: record)]),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('屏幕使用 4 个 Top 应用以两列等宽网格整齐对齐', (tester) async {
    final record = _healthRecord(
      topApps: [
        {'name': 'QNote', 'package': 'com.qnote', 'duration_ms': 38 * 60000, 'formatted': '38分钟'},
        {'name': '微信', 'package': 'com.tencent.mm', 'duration_ms': 26 * 60000, 'formatted': '26分钟'},
        {'name': 'bili', 'package': 'tv.danmaku.bili', 'duration_ms': 24 * 60000, 'formatted': '24分钟'},
        {'name': '抖音精选', 'package': 'com.ss.android.ugc', 'duration_ms': 20 * 60000, 'formatted': '20分钟'},
      ],
    );

    await tester.pumpWidget(_wrap(record));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('屏幕使用'), findsOneWidget);
    expect(find.text('2小时11分'), findsOneWidget);
    expect(find.text('较昨日 -6小时21分'), findsOneWidget);

    // 验证两行左列起点对齐、右列起点对齐（不会出现以前 Wrap 参差不齐的问题）
    final qnoteBox = tester.getRect(find.text('QNote'));
    final biliBox = tester.getRect(find.text('bili'));
    final wechatBox = tester.getRect(find.text('微信'));
    final douyinBox = tester.getRect(find.text('抖音精选'));

    expect(qnoteBox.left, closeTo(biliBox.left, 0.1));
    expect(wechatBox.left, closeTo(douyinBox.left, 0.1));
    expect(qnoteBox.top, closeTo(wechatBox.top, 0.1));
    expect(biliBox.top, closeTo(douyinBox.top, 0.1));

    // 验证时长也各自在列内右对齐
    final min38Box = tester.getRect(find.text('38分钟'));
    final min24Box = tester.getRect(find.text('24分钟'));
    final min26Box = tester.getRect(find.text('26分钟'));
    final min20Box = tester.getRect(find.text('20分钟'));

    expect(min38Box.right, closeTo(min24Box.right, 0.1));
    expect(min26Box.right, closeTo(min20Box.right, 0.1));
  });

  testWidgets('窄屏与奇数应用（3个）且无 duration_ms 时不溢出、仍保持两列对齐', (tester) async {
    final record = _healthRecord(
      steps: 0,
      yesterdayTimeMs: null,
      topApps: [
        {'name': '一个超级超级长名字的应用程序', 'formatted': '38分钟'},
        {'name': '微信', 'formatted': '26分钟'},
        {'name': 'Bilibili', 'formatted': '24分钟'},
      ],
    );

    await tester.pumpWidget(_wrap(record, width: 340, brightness: Brightness.light));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('屏幕使用'), findsOneWidget);
    expect(find.text('Bilibili'), findsOneWidget);

    // 第三个应用严格留在左列，与第一行左列对齐
    final firstLeft = tester.getRect(find.text('一个超级超级长名字的应用程序')).left;
    final thirdLeft = tester.getRect(find.text('Bilibili')).left;
    expect(firstLeft, closeTo(thirdLeft, 0.1));
  });
}
