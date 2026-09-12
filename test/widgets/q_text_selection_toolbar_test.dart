import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/widgets/q_text_selection_toolbar.dart';

void main() {
  // 模拟手机窄屏（360x640），验证菜单项放不下时会换行而不是折叠进 ⋮
  Widget buildToolbar({
    required Size surface,
    required List<ContextMenuButtonItem> items,
  }) {
    return MediaQuery(
      data: MediaQueryData(size: surface),
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: QTextSelectionToolbar(
              anchors: const TextSelectionToolbarAnchors(
                primaryAnchor: Offset(180, 300),
              ),
              buttonItems: items,
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('窄屏下全部菜单项平铺可见，不再出现 ⋮ 溢出按钮', (tester) async {
    const items = [
      ContextMenuButtonItem(label: '剪切', onPressed: null, type: ContextMenuButtonType.cut),
      ContextMenuButtonItem(label: '复制', onPressed: null, type: ContextMenuButtonType.copy),
      ContextMenuButtonItem(label: '粘贴', onPressed: null, type: ContextMenuButtonType.paste),
      ContextMenuButtonItem(label: '分享', onPressed: null, type: ContextMenuButtonType.share),
      ContextMenuButtonItem(label: '全选', onPressed: null, type: ContextMenuButtonType.selectAll),
      ContextMenuButtonItem(label: '给小Q', onPressed: null, type: ContextMenuButtonType.custom),
    ];

    await tester.pumpWidget(buildToolbar(surface: const Size(360, 640), items: items));
    await tester.pumpAndSettle();

    for (final label in ['剪切', '复制', '粘贴', '分享', '全选', '给小Q']) {
      expect(find.text(label), findsOneWidget, reason: '「$label」应直接可见');
    }
    // 默认工具栏的 ⋮ / 返回按钮不应出现
    expect(find.byIcon(Icons.more_vert), findsNothing);
    expect(find.byIcon(Icons.arrow_back), findsNothing);
  });

  testWidgets('点击「给小Q」触发回调', (tester) async {
    var pressed = false;
    await tester.pumpWidget(buildToolbar(
      surface: const Size(360, 640),
      items: [
        const ContextMenuButtonItem(label: '复制', onPressed: null, type: ContextMenuButtonType.copy),
        ContextMenuButtonItem(label: '给小Q', onPressed: () => pressed = true),
      ],
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('给小Q'));
    expect(pressed, isTrue);
  });

  testWidgets('自定义项按传入 label 渲染并用主题色高亮', (tester) async {
    await tester.pumpWidget(buildToolbar(
      surface: const Size(360, 640),
      items: [
        const ContextMenuButtonItem(label: '复制', onPressed: null, type: ContextMenuButtonType.copy),
        const ContextMenuButtonItem(label: '给小Q', onPressed: null, type: ContextMenuButtonType.custom),
      ],
    ));
    await tester.pumpAndSettle();

    final context = tester.element(find.text('给小Q'));
    final text = tester.widget<Text>(find.text('给小Q'));
    // 自定义项（ContextMenuButtonType.custom）使用 colorScheme.primary 高亮
    expect(text.style?.color, Theme.of(context).colorScheme.primary);
    // 默认项保持常规前景色
    final defaultText = tester.widget<Text>(find.text('复制'));
    expect(defaultText.style, isNull);
  });
}
