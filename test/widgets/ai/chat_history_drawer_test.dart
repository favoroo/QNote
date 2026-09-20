import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/providers/ai_provider.dart';
import 'package:qnote_flutter/widgets/ai/chat_history_drawer.dart';

/// 与 app.dart 的 `AppTheme.lightTheme(accentColor)` 用法保持一致，取代表性强调色
const Color _accent = Color(0xFF4C6EF5);

/// 固定「现在」，与用例里构造的时间戳配对
final _now = DateTime(2026, 9, 15, 12);

/// 不触库的会话列表替身。
///
/// 抽屉的渲染数据走构造入参，因此这里只需要挡住 `build()`（父类实现会去
/// `getAllChatSessions()` 取 sqflite，而 testWidgets 跑在 FakeAsync 区里，
/// 真实 IO Future 不会被 pump 冲刷，测试会**无声挂死**）。
class _FakeChatSessions extends ChatSessionListNotifier {
  _FakeChatSessions(this.sessions);

  List<ChatSession> sessions;
  final List<(String, bool)> pinnedCalls = [];
  final List<(String, String)> renameCalls = [];

  @override
  Future<List<ChatSession>> build() async => sessions;

  @override
  Future<void> setPinned(String id, bool isPinned) async {
    pinnedCalls.add((id, isPinned));
  }

  @override
  Future<void> renameSession(String id, String title) async {
    renameCalls.add((id, title));
  }
}

ChatSession _session(
  String id,
  DateTime updatedAt, {
  String? title,
  bool pinned = false,
  List<String> contents = const [],
}) {
  return ChatSession(
    id: id,
    title: title ?? '对话 $id',
    isPinned: pinned,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    messages: [
      for (final content in contents)
        ChatMessage(role: 'user', content: content, timestamp: updatedAt),
    ],
  );
}

/// 覆盖四个时间桶的一份样本：置顶、7 天内两条、30 天内一条、月组一条
List<ChatSession> _sampleSessions() => [
  _session('pin-old', DateTime(2025, 5, 5), pinned: true),
  _session('today', _now),
  _session('recent', DateTime(2026, 9, 12)),
  _session('mid', DateTime(2026, 9, 1)),
  _session('mar', DateTime(2026, 3, 3)),
];

late _FakeChatSessions _fake;

/// 命中高亮会把标题渲染成 `RichText` 而不是 `Text`，`find.text` 因此匹配不到；
/// 所有对会话标题的断言统一走这个 finder，两种渲染形态都能命中。
Finder findRowTitle(String title) => find.byWidgetPredicate(
  // 只认 RichText：每个 Text 内部本来就会构建一个 RichText，两个分支都写会把
  // 每个标题数成 2 个。未命中时是 Text→RichText，命中时是 RichText，都只有一层。
  (widget) => widget is RichText && widget.text.toPlainText() == title,
);

/// 抽屉内可能出现 `EmptyStateWidget`，它的呼吸动画是无限 `repeat()` 的循环，
/// 用 `pumpAndSettle` 会一直等到超时；这里改成手动推过抽屉的入场动画。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _pumpDrawer(
  WidgetTester tester, {
  List<ChatSession>? sessions,
  String? activeId,
  Brightness brightness = Brightness.light,
  Size size = const Size(900, 1200),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final list = sessions ?? _sampleSessions();
  _fake = _FakeChatSessions(list);
  final scaffoldKey = GlobalKey<ScaffoldState>();

  await tester.pumpWidget(
    ProviderScope(
      overrides: [chatSessionListProvider.overrideWith(() => _fake)],
      child: MaterialApp(
        theme: AppTheme.lightTheme(_accent),
        darkTheme: AppTheme.darkTheme(_accent),
        themeMode: brightness == Brightness.dark
            ? ThemeMode.dark
            : ThemeMode.light,
        // EmptyStateWidget 的呼吸动画与 LoadingRing 都是无限循环，
        // 不关掉动画的话 pumpAndSettle 会一直等到超时
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        ),
        home: Scaffold(
          key: scaffoldKey,
          endDrawer: ChatHistoryDrawer(
            sessionsAsync: AsyncValue.data(list),
            activeId: activeId,
            now: _now,
          ),
          body: Center(
            child: ElevatedButton(
              onPressed: () => scaffoldKey.currentState!.openEndDrawer(),
              child: const Text('open_history'),
            ),
          ),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open_history'));
  await _settle(tester);
}

void main() {
  group('分组与节头', () {
    testWidgets('四个时间桶的节头同时可见，月组默认折叠因此不渲染其行', (tester) async {
      await _pumpDrawer(tester);

      for (final label in ['置顶对话', '7 天内', '30 天内', '2026年3月']) {
        expect(find.text(label), findsOneWidget, reason: '缺少节头 $label');
      }
      expect(findRowTitle('对话 today'), findsOneWidget);
      expect(findRowTitle('对话 mar'), findsNothing, reason: '月组默认折叠，不该铺出内容');
    });

    testWidgets('点节头折叠后该组的行消失，但节头自身位置不动（不许 jumpTo）', (tester) async {
      await _pumpDrawer(tester);

      final before = tester.getTopLeft(find.text('7 天内'));
      await tester.tap(find.text('7 天内'));
      await _settle(tester);

      expect(findRowTitle('对话 today'), findsNothing);
      expect(findRowTitle('对话 recent'), findsNothing);
      expect(findRowTitle('对话 mid'), findsOneWidget, reason: '30 天内不受影响');
      expect(
        tester.getTopLeft(find.text('7 天内')),
        before,
        reason: '折叠只改展开态，绝不移动滚动位置',
      );

      await tester.tap(find.text('7 天内'));
      await _settle(tester);
      expect(findRowTitle('对话 today'), findsOneWidget);
    });

    testWidgets('折叠态在展开另一个组之后依然被记住', (tester) async {
      await _pumpDrawer(tester);

      await tester.tap(find.text('30 天内'));
      await _settle(tester);
      await tester.tap(find.text('2026年3月'));
      await _settle(tester);

      expect(findRowTitle('对话 mid'), findsNothing, reason: '仍折叠');
      expect(findRowTitle('对话 mar'), findsOneWidget, reason: '已展开');
    });

    testWidgets('节头右侧常驻批量选择入口，且不再有满宽「新建对话」大按钮', (tester) async {
      await _pumpDrawer(tester);

      expect(find.byIcon(Icons.grid_view), findsWidgets);
      expect(find.widgetWithText(FilledButton, '新建对话'), findsNothing);
      expect(find.byIcon(Icons.maps_ugc_outlined), findsOneWidget);
    });
  });

  group('搜索', () {
    testWidgets('命中正文即算命中，结果退化为扁平列表并给出计数', (tester) async {
      await _pumpDrawer(
        tester,
        sessions: [
          _session('a', _now, title: '杂项', contents: ['电池容量怎么算']),
          _session('b', DateTime(2026, 3, 3), title: '电池相关'),
          _session('c', DateTime(2026, 9, 1), title: '无关话题'),
        ],
      );

      await tester.enterText(find.byType(TextField), '电池');
      await _settle(tester);

      expect(find.text('2 个结果'), findsOneWidget);
      expect(findRowTitle('杂项'), findsOneWidget, reason: '只命中正文也要出现');
      expect(findRowTitle('无关话题'), findsNothing);
      // 搜索态绕过分桶与折叠：月组那条必须照样渲染出来
      expect(findRowTitle('电池相关'), findsOneWidget);
      expect(find.text('7 天内'), findsNothing);
    });

    testWidgets('清空关键词后回到分组态，且折叠记忆完好', (tester) async {
      await _pumpDrawer(tester);
      await tester.tap(find.text('7 天内'));
      await _settle(tester);

      await tester.enterText(find.byType(TextField), 'today');
      await _settle(tester);
      await tester.enterText(find.byType(TextField), '');
      await _settle(tester);

      expect(find.text('7 天内'), findsOneWidget);
      expect(findRowTitle('对话 today'), findsNothing, reason: '折叠态被完整记住');
    });

    testWidgets('无命中与零会话两种空态分别可见', (tester) async {
      await _pumpDrawer(tester);
      await tester.enterText(find.byType(TextField), 'zzz');
      await _settle(tester);
      expect(find.text('没有匹配的对话'), findsOneWidget);

      await _pumpDrawer(tester, sessions: const []);
      expect(find.text('暂无对话'), findsOneWidget);
    });
  });

  group('批量选择', () {
    testWidgets('从节头进入批量态：行首换勾选框、行尾菜单入口消失', (tester) async {
      await _pumpDrawer(tester);

      expect(find.byType(Checkbox), findsNothing);
      await tester.tap(find.byIcon(Icons.grid_view).first);
      await _settle(tester);

      expect(find.byType(Checkbox), findsWidgets);
      expect(find.byIcon(Icons.more_horiz), findsNothing);
    });

    testWidgets('刚进批量、一条都没勾时「全选」就已可用', (tester) async {
      await _pumpDrawer(tester);
      await tester.tap(find.byIcon(Icons.grid_view).first);
      await _settle(tester);

      expect(find.text('全选'), findsOneWidget);
      expect(find.text('清空全部'), findsOneWidget);
      expect(find.text('删除已选 (0)'), findsNothing, reason: '没勾就不给删除条');
    });

    testWidgets('搜索态下「全选」只作用于命中集', (tester) async {
      await _pumpDrawer(tester);
      await tester.enterText(find.byType(TextField), 'today');
      await _settle(tester);
      await tester.tap(find.byIcon(Icons.grid_view).first);
      await _settle(tester);

      await tester.tap(find.text('全选'));
      await _settle(tester);
      expect(find.text('删除已选 (1)'), findsOneWidget, reason: '命中只有 1 条');
    });

    testWidgets('勾选后底部出现「删除已选」条', (tester) async {
      await _pumpDrawer(tester);
      await tester.tap(find.byIcon(Icons.grid_view).first);
      await _settle(tester);

      await tester.tap(find.byType(Checkbox).first);
      await _settle(tester);
      expect(find.text('删除已选 (1)'), findsOneWidget);
    });
  });

  group('行级菜单', () {
    testWidgets('长按一行弹出置顶 / 重命名 / 批量选择 / 删除', (tester) async {
      await _pumpDrawer(tester);

      await tester.longPress(findRowTitle('对话 today'));
      await _settle(tester);

      expect(find.text('置顶'), findsOneWidget, reason: '菜单项');
      expect(find.text('重命名'), findsOneWidget);
      expect(find.text('批量选择'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('点菜单里的「置顶」会打到 Notifier，且不写库', (tester) async {
      await _pumpDrawer(tester);

      // 挑一条未置顶的行：已置顶那行的菜单项文案是「取消置顶」
      await tester.longPress(findRowTitle('对话 today'));
      await _settle(tester);
      await tester.tap(find.text('置顶'));
      await _settle(tester);

      expect(_fake.pinnedCalls, [('today', true)]);
    });

    testWidgets('已置顶的行给出「取消置顶」', (tester) async {
      await _pumpDrawer(tester);

      await tester.longPress(findRowTitle('对话 pin-old'));
      await _settle(tester);
      expect(find.text('取消置顶'), findsOneWidget);
    });
  });

  group('渲染健壮性', () {
    testWidgets('深色 + 窄视口下不抛异常（吸顶节头与长标题省略号的溢出回归）', (tester) async {
      await _pumpDrawer(
        tester,
        brightness: Brightness.dark,
        size: const Size(360, 640),
        sessions: [
          _session(
            'long',
            _now,
            title: '这是一条长得必须被省略号截断的会话标题，用来压测窄抽屉下的排版边界情况',
          ),
          ..._sampleSessions(),
        ],
      );

      expect(tester.takeException(), isNull);
      expect(find.text('置顶对话'), findsOneWidget);
    });

    testWidgets('当前会话行处于选中态，其余不是', (tester) async {
      await _pumpDrawer(tester, activeId: 'recent');

      ListTile tileOf(String title) => tester.widget<ListTile>(
        find.ancestor(
          of: findRowTitle(title),
          matching: find.byType(ListTile),
        ),
      );

      expect(tileOf('对话 recent').selected, isTrue);
      expect(tileOf('对话 today').selected, isFalse);
    });
  });
}
