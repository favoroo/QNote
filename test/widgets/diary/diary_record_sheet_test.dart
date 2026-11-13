import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/fixed_event_template.dart';
import 'package:qnote_flutter/models/shortcut_config.dart';
import 'package:qnote_flutter/models/shortcut_field.dart';
import 'package:qnote_flutter/models/tag_entry.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/fixed_event_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/widgets/diary/diary_record_sheet.dart';

/// 时间线列表用空实现顶掉，避免面板测试拉起 sqflite
/// （真 sqflite Future 落在 FakeAsync 区块里会无声挂死，见 AGENTS.md）。
class _EmptyDiaryList extends DiaryListNotifier {
  @override
  Future<List<DiaryRecord>> build() async => const [];
}

/// 发送落位测试用的假 notifier：不碰 sqflite，返回一个固定的落库 id。
class _MorphDiaryList extends DiaryListNotifier {
  @override
  Future<List<DiaryRecord>> build() async => const [];

  @override
  Future<DiaryRecord> addDiary({
    required String title,
    String content = '',
    int mood = 3,
    String weather = '',
    List<String> tags = const [],
    String? folderId,
    DateTime? time,
    DateTime? startTime,
    DateTime? endTime,
    String displayTag = '',
    Map<String, dynamic>? bodyState,
    List<TagEntry> tagEntries = const [],
    List<String> photos = const [],
  }) async {
    final now = DateTime.now();
    return DiaryRecord(
      id: 'saved-1',
      title: title,
      content: content,
      time: time ?? now,
      startTime: startTime,
      endTime: endTime,
      tags: tags,
      displayTag: displayTag,
      bodyState: bodyState,
      tagEntries: tagEntries,
      photos: photos,
      folderId: folderId,
      mood: mood,
      weather: weather,
      createdAt: now,
      updatedAt: now,
    );
  }
}

class _SeedDraftNotifier extends DiaryComposeDraftNotifier {
  _SeedDraftNotifier(this._seed);

  final DiaryComposeDraft _seed;

  @override
  DiaryComposeDraft build() => _seed;
}

FixedEventTemplate _template() {
  return FixedEventTemplate(
    id: 't1',
    name: '晨跑',
    startTime: '07:00',
    endTime: '07:30',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

ShortcutConfig _sleepShortcut() {
  return ShortcutConfig(
    id: 'sleep',
    name: '睡眠',
    hasPopup: true,
    fields: [ShortcutField(id: 'fallAsleepTime', label: '入睡时间', type: 'time')],
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
}

List<Override> _overrides({
  List<ShortcutConfig> shortcuts = const [],
  List<FixedEventTemplate> fixedEvents = const [],
  DiaryComposeDraft? draft,
  TimelineTimeSelectEvent? selection,
  DiaryListNotifier Function() diaryList = _EmptyDiaryList.new,
}) {
  return [
    shortcutListProvider.overrideWith((ref) async => shortcuts),
    fixedEventListProvider.overrideWith((ref) async => fixedEvents),
    aiTemperaturesProvider.overrideWith((ref) async => null),
    diaryListProvider.overrideWith(diaryList),
    if (draft != null) diaryComposeDraftProvider.overrideWith(() => _SeedDraftNotifier(draft)),
    if (selection != null) diaryInputTimeProvider.overrideWith((ref) => selection),
  ];
}

Future<void> _pumpSheet(
  WidgetTester tester, {
  List<ShortcutConfig> shortcuts = const [],
  List<FixedEventTemplate> fixedEvents = const [],
  DiaryComposeDraft? draft,
  TimelineTimeSelectEvent? selection,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(shortcuts: shortcuts, fixedEvents: fixedEvents, draft: draft, selection: selection),
      child: const MaterialApp(home: Scaffold(body: DiaryRecordSheet())),
    ),
  );
  await tester.pumpAndSettle();
}

/// 带按钮锚点打开面板的测试宿主；[origin] 就是假记录按钮的全局 Rect。
Future<void> _pumpRouteHost(WidgetTester tester, {required Rect origin}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: _overrides(),
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => DiaryRecordSheet.show(
                context,
                originAnchor: RecordFabAnchor(rect: origin),
                readAnchor: () => RecordFabAnchor(rect: origin),
              ),
              child: const Text('打开记录'),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('固定事件与结束时间入口默认就可见，没有「更多字段」这一级', (tester) async {
    await _pumpSheet(tester, fixedEvents: [_template()]);

    // 固定事件常驻，不需要先点开任何折叠
    expect(find.text('晨跑'), findsOneWidget);
    expect(find.text('结束时间'), findsOneWidget);
    expect(find.text('更多字段'), findsNothing);

    // 动作入口全部就位：工具栏的 AI 提取（纯图标）+ 输入行末尾的发送键
    expect(find.byKey(const ValueKey('record-ai-extract')), findsOneWidget);
    expect(find.text('AI 提取'), findsNothing, reason: '提取钮只留图标，不带文字');
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
    // 头部不再有「保存 / 关闭」两个文字按钮，只留右上角圆形关闭键
    expect(find.text('保存'), findsNothing);
    expect(find.text('关闭'), findsNothing);
    expect(find.byKey(const ValueKey('record-close')), findsOneWidget);

    expect(find.byType(TextField), findsOneWidget);
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
  });

  testWidgets('标签自带字段时就地展开，不需要额外点击', (tester) async {
    await _pumpSheet(
      tester,
      shortcuts: [_sleepShortcut()],
      draft: DiaryComposeDraft(
        id: 'd1',
        tagEntries: [TagEntry(id: 'sleep', name: '睡眠', fields: {})],
      ),
    );

    expect(find.text('入睡时间'), findsOneWidget);
  });

  testWidgets('空草稿时发送键禁用', (tester) async {
    await _pumpSheet(tester);

    final button = tester.widget<FilledButton>(find.byKey(const ValueKey('record-send')));
    expect(button.onPressed, isNull);
  });

  testWidgets('有内容时发送键可用，草稿回填到输入框', (tester) async {
    await _pumpSheet(
      tester,
      draft: DiaryComposeDraft(id: 'd1', inputText: '喝了杯咖啡'),
    );

    final button = tester.widget<FilledButton>(find.byKey(const ValueKey('record-send')));
    expect(button.onPressed, isNotNull);
    expect(find.text('喝了杯咖啡'), findsOneWidget, reason: '草稿要回填到输入框');
  });

  testWidgets('打开面板时草稿时间跟随时间线上刚选中的时间', (tester) async {
    // 面板关闭期间在时间线上选的时间不会流进草稿（监听随面板卸载了），
    // 打开时必须对齐，否则头部显示旧时间，和左下角胶囊上刚看到的时间对不上。
    await _pumpSheet(
      tester,
      draft: DiaryComposeDraft(id: 'd1', startTime: const TimeOfDay(hour: 12, minute: 0)),
      selection: TimelineTimeSelectEvent(const TimeOfDay(hour: 14, minute: 30), date: DateTime.now()),
    );

    expect(find.textContaining('14:30'), findsOneWidget);
    expect(find.textContaining('12:00'), findsNothing);
  });

  testWidgets('点右上角圆形关闭键收起卡片', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) =>
                  TextButton(onPressed: () => DiaryRecordSheet.show(context), child: const Text('打开记录')),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开记录'));
    await tester.pumpAndSettle();
    expect(find.byType(DiaryRecordSheet), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('record-close')));
    await tester.pumpAndSettle();
    expect(find.byType(DiaryRecordSheet), findsNothing);
  });

  testWidgets('从按钮位置容器变形入场：起点在按钮，随后长成卡片', (tester) async {
    const origin = Rect.fromLTWH(16, 500, 44, 44);
    await _pumpRouteHost(tester, origin: origin);

    await tester.tap(find.text('打开记录'));
    await tester.pump(); // 插入路由 + 首帧

    final morph = find.byKey(const ValueKey('record-sheet-morph'));
    expect(morph, findsOneWidget);
    final first = tester.getRect(morph);
    expect(first.center.dx, closeTo(origin.center.dx, 2));
    expect(first.center.dy, closeTo(origin.center.dy, 2));

    await tester.pump(const Duration(milliseconds: 220));
    final mid = tester.getRect(morph);
    expect(mid.width, greaterThan(first.width + 40));

    await tester.pumpAndSettle();
    expect(find.byType(DiaryRecordSheet), findsOneWidget);
    // 入场结束容器撤掉，改由未裁切的内容窗口直接画卡片。
    expect(find.byKey(const ValueKey('record-sheet-morph')), findsNothing);
  });

  testWidgets('关闭时容器反向收回按钮位置', (tester) async {
    const origin = Rect.fromLTWH(16, 500, 44, 44);
    await _pumpRouteHost(tester, origin: origin);

    await tester.tap(find.text('打开记录'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('record-sheet-morph')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('record-close')));
    await tester.pump();

    final morph = find.byKey(const ValueKey('record-sheet-morph'));
    expect(morph, findsOneWidget);
    final start = tester.getRect(morph);

    await tester.pump(const Duration(milliseconds: 160));
    final mid = tester.getRect(morph);
    // 收回途中：比按钮宽、比卡片窄，说明是在连续插值而不是瞬移。
    expect(mid.width, greaterThan(origin.width));
    expect(mid.width, lessThan(start.width - 20));

    await tester.pumpAndSettle();
    expect(find.byType(DiaryRecordSheet), findsNothing);
    expect(find.byKey(const ValueKey('record-sheet-morph')), findsNothing);
  });

  testWidgets('收回途中：面板内容先淡掉，幽灵等容器落到按钮才亮', (tester) async {
    // 退场是「内容淡出 → 空容器收回按钮 → 幽灵落进按钮」三段。顺序错了就会看到
    // 两种闪：内容在缩小的窗口里残留半透明残影，或时间文字提前浮在卡片上。
    const origin = Rect.fromLTWH(16, 500, 44, 44);
    await _pumpRouteHost(tester, origin: origin);

    await tester.tap(find.text('打开记录'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('record-close')));
    await tester.pump();

    double contentOpacity() => tester
        .widget<Opacity>(
          find.descendant(of: find.byKey(const ValueKey('record-sheet-window')), matching: find.byType(Opacity)).first,
        )
        .opacity;

    double ghostOpacity() => tester
        .widget<Opacity>(
          find.descendant(of: find.byKey(const ValueKey('record-sheet-ghost')), matching: find.byType(Opacity)).first,
        )
        .opacity;

    // 约三成（100ms）时容器已收掉大半，内容必须已经淡完
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getRect(find.byKey(const ValueKey('record-sheet-morph'))).width, lessThan(300));
    expect(contentOpacity(), lessThan(0.05), reason: '内容不能留在缩小后的窗口里');

    // 约五成半（180ms）：容器基本落到按钮，幽灵这时才刚开始淡入
    await tester.pump(const Duration(milliseconds: 80));
    expect(ghostOpacity(), lessThan(0.3), reason: '幽灵不能提前浮在还没收小的卡片上');

    // 约七成半（240ms）：幽灵已经落满，最后一帧和真实按钮像素一致，才能无缝换回
    await tester.pump(const Duration(milliseconds: 60));
    expect(ghostOpacity(), greaterThan(0.9));

    await tester.pumpAndSettle();
    expect(find.byType(DiaryRecordSheet), findsNothing);
  });

  testWidgets('发送后面板飞向目标卡片，落位回调后收起', (tester) async {
    const origin = Rect.fromLTWH(16, 760, 44, 44);
    const target = Rect.fromLTWH(120, 260, 220, 120);
    List<String>? savedIds;
    var landed = false;
    // 量目标卡片时所在的调度阶段：飞行/落位全程都不能落在 persistentCallbacks
    // （= build/layout/paint）。在布局阶段量页面上的 RenderBox 会读到本轮尚未
    // 布局的祖先 Transform，抛「RenderBox was not laid out」，整帧被错误块顶替
    // —— release 下错误块是浅灰，深色主题里就是发送时的一下白闪。
    final readPhases = <SchedulerPhase>[];

    await tester.pumpWidget(
      ProviderScope(
        overrides: _overrides(
          diaryList: _MorphDiaryList.new,
          draft: DiaryComposeDraft(id: 'd1', inputText: '走了 8000 步'),
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => DiaryRecordSheet.show(
                  context,
                  originAnchor: const RecordFabAnchor(rect: origin),
                  readAnchor: () => const RecordFabAnchor(rect: origin),
                  onSaved: (ids) async {
                    savedIds = ids;
                    return RecordCardMorphTarget(
                      initialRect: target,
                      readRect: () {
                        readPhases.add(SchedulerBinding.instance.schedulerPhase);
                        return target;
                      },
                      onLanded: () => landed = true,
                    );
                  },
                ),
                child: const Text('打开记录'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('打开记录'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('record-send')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 360)); // ✓ 播完，飞行启动
    await tester.pump(const Duration(milliseconds: 180)); // 飞行途中

    // 回调拿到的是 addDiary 返回的落库 id，而不是面板自己造的临时 id。
    expect(savedIds, <String>['saved-1']);
    final morph = find.byKey(const ValueKey('record-sheet-morph'));
    expect(morph, findsOneWidget);
    final mid = tester.getRect(morph);
    // 目标卡片在面板左侧，飞行途中容器已经离开屏幕中心向左走。
    expect(mid.center.dx, lessThan(tester.getSize(find.byType(Scaffold)).width / 2));

    await tester.pumpAndSettle();
    expect(landed, isTrue);
    expect(find.byType(DiaryRecordSheet), findsNothing);
    expect(find.byKey(const ValueKey('record-sheet-morph')), findsNothing);

    // 飞行与落位都要读实时 Rect（列表/键盘变化时盖板跟着走），但必须在动画
    // tick 里采样，不能在布局阶段量。
    expect(readPhases, isNotEmpty);
    expect(readPhases, isNot(contains(SchedulerPhase.persistentCallbacks)));
  });
}
