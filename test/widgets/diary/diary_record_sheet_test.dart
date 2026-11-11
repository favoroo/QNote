import 'package:flutter/material.dart';
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
    fields: [
      ShortcutField(id: 'fallAsleepTime', label: '入睡时间', type: 'time'),
    ],
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );
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
      overrides: [
        shortcutListProvider.overrideWith((ref) async => shortcuts),
        fixedEventListProvider.overrideWith((ref) async => fixedEvents),
        aiTemperaturesProvider.overrideWith((ref) async => null),
        diaryListProvider.overrideWith(_EmptyDiaryList.new),
        if (draft != null)
          diaryComposeDraftProvider.overrideWith(() => _SeedDraftNotifier(draft)),
        if (selection != null)
          diaryInputTimeProvider.overrideWith((ref) => selection),
      ],
      child: const MaterialApp(home: Scaffold(body: DiaryRecordSheet())),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('默认轻量态：有时间和文本输入，重表单收在「更多字段」后面', (tester) async {
    await _pumpSheet(tester, fixedEvents: [_template()]);

    expect(find.text('关闭'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    expect(find.text('更多字段'), findsOneWidget);
    expect(find.byType(TextField), findsOneWidget);
    // 图片与相机入口常驻
    expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    expect(find.byIcon(Icons.camera_alt_outlined), findsOneWidget);
    // 固定事件尚未展开
    expect(find.text('晨跑'), findsNothing);
  });

  testWidgets('点「更多字段」后固定事件行出现', (tester) async {
    await _pumpSheet(tester, fixedEvents: [_template()]);

    await tester.tap(find.text('更多字段'));
    await tester.pumpAndSettle();

    expect(find.text('晨跑'), findsOneWidget);
  });

  testWidgets('标签自带字段时自动展开，必填表单不会藏在折叠区里', (tester) async {
    await _pumpSheet(
      tester,
      shortcuts: [_sleepShortcut()],
      draft: DiaryComposeDraft(
        id: 'd1',
        tagEntries: [TagEntry(id: 'sleep', name: '睡眠', fields: {})],
      ),
    );

    // 没有点过「更多字段」，字段表单就已经在
    expect(find.text('入睡时间'), findsOneWidget);
  });

  testWidgets('空草稿时保存按钮禁用', (tester) async {
    await _pumpSheet(tester);

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存'),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('有内容时保存按钮可用，关闭按钮不丢草稿', (tester) async {
    await _pumpSheet(tester, draft: DiaryComposeDraft(id: 'd1', inputText: '喝了杯咖啡'));

    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存'),
    );
    expect(button.onPressed, isNotNull);
    expect(find.text('喝了杯咖啡'), findsOneWidget, reason: '草稿要回填到输入框');
  });

  testWidgets('打开面板时草稿时间跟随时间线上刚选中的时间', (tester) async {
    // 面板关闭期间在时间线上选的时间不会流进草稿（监听随面板卸载了），
    // 打开时必须对齐，否则头部显示旧时间，和左下角胶囊上刚看到的时间对不上。
    await _pumpSheet(
      tester,
      draft: DiaryComposeDraft(
        id: 'd1',
        startTime: const TimeOfDay(hour: 12, minute: 0),
      ),
      selection: TimelineTimeSelectEvent(
        const TimeOfDay(hour: 14, minute: 30),
        date: DateTime.now(),
      ),
    );

    expect(find.textContaining('14:30'), findsOneWidget);
    expect(find.textContaining('12:00'), findsNothing);
  });
}
