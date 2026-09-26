import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/storage/daily_score_service.dart';
import 'package:qnote_flutter/core/utils/daily_score_adjust.dart';
import 'package:qnote_flutter/models/daily_score.dart';
import 'package:qnote_flutter/widgets/statistics/batch_score_adjust_sheet.dart';

/// 总分逐日递减、五维固定 80：保证加减分与设为固定值两种模式都产生真实变更
DailyScore _score({required int day}) => DailyScore(
  id: 'id-$day',
  date: DateTime(2026, 9, day),
  totalScore: 88 - day,
  dimensionScores: const {
    'sleep': 80,
    'diet': 80,
    'activity': 80,
    'health': 80,
    'screen': 80,
  },
  summary: '评语',
  suggestions: '建议',
  recordCount: 5,
  createdAt: DateTime(2026, 9, day),
  updatedAt: DateTime(2026, 9, day),
);

typedef _Call = ({DateTime from, DateTime to, ScoreAdjustSpec spec, bool dryRun});

class _Stub {
  _Stub({this.scoredDays = 3, this.previewFails = false});

  final int scoredDays;

  /// 抽屉默认打开就是近 7 天，缺评分天数按此推出
  static const int _rangeDays = 7;
  final bool previewFails;

  final List<_Call> calls = [];

  ScoreAdjustRunner get runner => _run;

  List<_Call> get applies => calls.where((c) => !c.dryRun).toList();
  List<_Call> get previews => calls.where((c) => c.dryRun).toList();

  Future<ScoreAdjustRangeResult> _run({
    required DateTime from,
    required DateTime to,
    required ScoreAdjustSpec spec,
    required bool dryRun,
  }) async {
    calls.add((from: from, to: to, spec: spec, dryRun: dryRun));
    if (previewFails && dryRun) {
      throw Exception('单次最多调整 92 天，请缩小日期范围分批处理');
    }
    final outcomes = [
      for (var i = 0; i < scoredDays; i++)
        applyScoreAdjust(_score(day: i + 1), spec),
    ].where((o) => o.changed).toList();
    return ScoreAdjustRangeResult(
      outcomes: outcomes,
      scoredDays: scoredDays,
      missingDays: _rangeDays - scoredDays,
      dryRun: dryRun,
    );
  }
}

Future<void> _openSheet(WidgetTester tester, _Stub stub) async {
  // 放大视口，保证作用面 chip 与预览明细都落在抽屉可见区内，
  // 否则 tap 会打在滚动区之外而命中别的 widget
  tester.view.physicalSize = const Size(900, 1800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => BatchScoreAdjustSheet.show(context, adjust: stub.runner),
            child: const Text('open-sheet'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open-sheet'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('打开即按近 7 天与 -5 自动预览', (tester) async {
    final stub = _Stub();
    await _openSheet(tester, stub);

    expect(stub.previews, hasLength(1));
    final preview = stub.previews.single;
    expect(preview.dryRun, isTrue);
    expect(preview.to.difference(preview.from).inDays + 1, 7);
    expect(preview.spec.delta, -5);
    expect(preview.spec.fields, kAllScoreFields);
    expect(find.text('批量调整历史评分'), findsOne);
    expect(find.text('命中 3 天 · 该区间无评分 4 天（不会被改动）'), findsOne);
    expect(find.textContaining('总分不随维度重算'), findsOne);
  });

  testWidgets('预览列出逐日前后分值', (tester) async {
    await _openSheet(tester, _Stub());

    // 三天总分 87/86/85 各减 5，五维统一 80→75
    expect(find.textContaining('总分 87→82'), findsOne);
    expect(find.textContaining('总分 85→80'), findsOne);
    expect(find.textContaining('睡眠 80→75'), findsNWidgets(3));
  });

  testWidgets('预览失败时显示原因、保持打开且禁用应用', (tester) async {
    final stub = _Stub(previewFails: true);
    await _openSheet(tester, stub);

    expect(find.textContaining('单次最多调整 92 天'), findsOne);
    expect(find.text('批量调整历史评分'), findsOne, reason: '失败不应关闭抽屉');
    expect(stub.applies, isEmpty);
    expect(
      tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
      isNull,
    );
  });

  testWidgets('点应用只触发一次落库调用并关闭抽屉', (tester) async {
    final stub = _Stub();
    await _openSheet(tester, stub);

    await tester.tap(find.text('应用到 3 天'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(stub.applies, hasLength(1));
    expect(stub.applies.single.dryRun, isFalse);
    expect(find.text('批量调整历史评分'), findsNothing);
    // 放掉成功 Toast 的 2 秒自动消失定时器，否则测试结束时报 pending Timer
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('快捷范围改变传给回调的起止日期', (tester) async {
    final stub = _Stub();
    await _openSheet(tester, stub);

    await tester.tap(find.text('近30天'));
    await tester.pumpAndSettle();

    expect(stub.previews.last.to.difference(stub.previews.last.from).inDays + 1, 30);
  });

  testWidgets('取消字段勾选后作用面随之收窄', (tester) async {
    final stub = _Stub();
    await _openSheet(tester, stub);

    await tester.tap(find.text('总分'));
    await tester.pumpAndSettle();

    expect(stub.previews.last.spec.fields, isNot(contains(ScoreField.total)));
    expect(stub.previews.last.spec.fields, contains(ScoreField.sleep));
  });

  testWidgets('切到固定值模式改用 setValue', (tester) async {
    final stub = _Stub();
    await _openSheet(tester, stub);

    await tester.tap(find.text('设为固定值'));
    await tester.pumpAndSettle();

    final spec = stub.previews.last.spec;
    expect(spec.setValue, 80);
    expect(spec.delta, isNull);
  });

  testWidgets('无命中天数时按钮提示区间没有可改的评分', (tester) async {
    final stub = _Stub(scoredDays: 0);
    await _openSheet(tester, stub);

    expect(find.text('该区间没有需要改动的评分'), findsOne);
    expect(stub.applies, isEmpty);
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(stub.applies, isEmpty, reason: '禁用状态下点击也不得落库');
  });

  testWidgets('全部字段取消后要求至少选一个字段', (tester) async {
    final stub = _Stub();
    await _openSheet(tester, stub);

    for (final label in ['总分', '睡眠', '饮食', '活动', '健康', '屏幕']) {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    expect(find.text('请至少选择一个字段'), findsOne);
    expect(stub.applies, isEmpty);
  });
}
