import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/widgets/shell_branch_container.dart';

/// 可计数的测试分支页面：用来验证切换分支不会重建、局部状态得以保留。
class _BranchProbe extends StatefulWidget {
  const _BranchProbe({required this.label});

  final String label;

  @override
  State<_BranchProbe> createState() => _BranchProbeState();
}

class _BranchProbeState extends State<_BranchProbe> {
  int _taps = 0;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.label),
            Text('taps:$_taps'),
            TextButton(onPressed: () => setState(() => _taps++), child: const Text('inc')),
          ],
        ),
      ),
    );
  }
}

/// 在测试里手动驱动 currentIndex，模拟 shell 分支切换。
class _Host extends StatefulWidget {
  const _Host();

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ShellBranchContainer(
          currentIndex: _index,
          children: const [
            _BranchProbe(label: 'branch-a'),
            _BranchProbe(label: 'branch-b'),
            _BranchProbe(label: 'branch-c'),
          ],
        ),
      ),
    );
  }

  void goTo(int index) => setState(() => _index = index);
}

_HostState _hostOf(WidgetTester tester) => tester.state<_HostState>(find.byType(_Host));

void main() {
  testWidgets('切换分支：过渡期新旧两页共存，收起后只剩目标分支', (tester) async {
    await tester.pumpWidget(const _Host());

    // 初始只有 branch-a 可见；未访问过的分支不参与命中（Offstage）。
    expect(find.text('branch-a'), findsOneWidget);
    expect(find.text('branch-b'), findsNothing);

    _hostOf(tester).goTo(1);
    await tester.pump();

    // 过渡刚开始：目标分支已在树中（垫底页保持挂载，新页淡入）。
    expect(find.text('branch-a'), findsOneWidget);
    expect(find.text('branch-b'), findsOneWidget);

    await tester.pumpAndSettle();

    // 过渡结束：只保留目标分支，其余分支退回 Offstage。
    expect(find.text('branch-b'), findsOneWidget);
    expect(find.text('branch-a'), findsNothing);
    expect(find.text('branch-c'), findsNothing);
  });

  testWidgets('切换分支不重建页面：分支局部状态跨切换保留', (tester) async {
    await tester.pumpWidget(const _Host());

    // 在 branch-a 上把计数点到 2。
    await tester.tap(find.text('inc'));
    await tester.pump();
    await tester.tap(find.text('inc'));
    await tester.pump();
    expect(find.text('taps:2'), findsOneWidget);

    // 切走再切回，计数不该归零（State 未被销毁）。
    _hostOf(tester).goTo(2);
    await tester.pumpAndSettle();
    expect(find.text('branch-c'), findsOneWidget);

    _hostOf(tester).goTo(0);
    await tester.pumpAndSettle();
    expect(find.text('taps:2'), findsOneWidget);
  });

  testWidgets('记录板块内部切换：两页交叉溶解后落到目标页', (tester) async {
    // 传 1/2 两个索引的容器，模拟 ShellBranch.notes ↔ ShellBranch.todo。
    // （记录板块内切换不做位移是容器内部行为，由 _slideBegin/_slideEnd 恒零保证。）
    Widget host(int index) => MaterialApp(
      home: Scaffold(
        body: ShellBranchContainer(
          currentIndex: index,
          children: const [
            _BranchProbe(label: 'timeline'),
            _BranchProbe(label: 'notes'),
            _BranchProbe(label: 'todo'),
            _BranchProbe(label: 'ai'),
          ],
        ),
      ),
    );

    var index = 1;
    late StateSetter setOuter;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          setOuter = setState;
          return host(index);
        },
      ),
    );

    setOuter(() => index = 2);
    await tester.pump();

    // 过渡期两页共存，做交叉溶解。
    expect(find.text('todo'), findsOneWidget);
    expect(find.text('notes'), findsOneWidget);

    await tester.pumpAndSettle();
    expect(find.text('todo'), findsOneWidget);
    expect(find.text('notes'), findsNothing);
  });
}
