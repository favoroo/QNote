import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/pages/todo_page.dart';
import 'package:qnote_flutter/providers/todo_folder_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockTodoListNotifier extends TodoListNotifier {
  final List<Todo> _initial;
  _MockTodoListNotifier(this._initial);

  @override
  Future<List<Todo>> build() async => _initial;

  @override
  Future<Todo> addTodo({
    required String title,
    String description = '',
    String priority = 'normal',
    DateTime? dueDate,
    String tags = '',
    String? folderId,
    bool isLongTerm = false,
    String repeatRule = 'none',
    String? reminderTime,
  }) async {
    final todo = Todo(
      id: 'mock-todo-${DateTime.now().microsecondsSinceEpoch}',
      title: title,
      description: description,
      folderId: folderId,
      reminderTime: reminderTime,
      repeatRule: repeatRule,
      priority: priority,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    state = AsyncData([...state.value ?? [], todo]);
    return todo;
  }

  @override
  Future<void> toggleComplete(String id, bool isCompleted) async {
    state = AsyncData(
      (state.value ?? []).map((t) {
        if (t.id == id) {
          return t.copyWith(isCompleted: isCompleted);
        }
        return t;
      }).toList(),
    );
  }

  @override
  Future<void> deleteTodo(String id) async {
    state = AsyncData(
      (state.value ?? []).where((t) => t.id != id).toList(),
    );
  }

  @override
  Future<void> deleteTodos(List<String> ids) async {
    final idSet = ids.toSet();
    state = AsyncData(
      (state.value ?? []).where((t) => !idSet.contains(t.id)).toList(),
    );
  }
}

class _MockTodoFolderNotifier extends TodoFolderListNotifier {
  @override
  Future<List<Folder>> build() async => [
        Folder(
          id: 'folder-1',
          name: '工作',
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ),
      ];
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'todo_completed_collapsed': false,
    });
  });

  testWidgets('待办页面正常渲染，未完成与已完成分段展示，且无三点菜单', (tester) async {
    final todos = [
      Todo(
        id: 't-1',
        title: '正在进行的任务',
        isCompleted: false,
        folderId: 'folder-1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      Todo(
        id: 't-2',
        title: '已经完成的任务',
        isCompleted: true,
        folderId: 'folder-1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todoListProvider.overrideWith(() => _MockTodoListNotifier(todos)),
          todoFolderListProvider.overrideWith(() => _MockTodoFolderNotifier()),
        ],
        child: const MaterialApp(
          home: TodoPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 验证未完成与已完成待办均展示
    expect(find.text('正在进行的任务'), findsOneWidget);
    expect(find.text('已经完成的任务'), findsOneWidget);

    // 验证已完成折叠栏显示：包含 "已完成 1"
    expect(find.textContaining('已完成 1'), findsOneWidget);

    // 验证三点菜单按钮 (Icons.more_vert) 已被彻底移除
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // 验证未完成待办拥有拖动手柄 (Icons.drag_indicator)，且手柄位于待办项右侧
    expect(find.byIcon(Icons.drag_indicator), findsOneWidget);
    final dragIconCenter = tester.getCenter(find.byIcon(Icons.drag_indicator));
    final todoTextCenter = tester.getCenter(find.text('正在进行的任务'));
    expect(dragIconCenter.dx, greaterThan(todoTextCenter.dx));
  });

  testWidgets('点击FAB弹出底部大弹窗，支持回车连续添加待办', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todoListProvider.overrideWith(() => _MockTodoListNotifier([])),
          todoFolderListProvider.overrideWith(() => _MockTodoFolderNotifier()),
        ],
        child: const MaterialApp(
          home: TodoPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 点击浮动按钮添加待办
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // 验证小米风格大弹窗已弹出，文案对齐
    expect(find.text('回车即可连续添加待办'), findsOneWidget);
    expect(find.text('重复'), findsOneWidget);
    expect(find.text('提醒'), findsOneWidget);
    expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);

    // 1. 输入第一条，按回车提交
    await tester.enterText(find.byType(TextField), '第一项任务');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    // 验证弹窗依然存在（光标保留可连续输入），输入框已清空，列表中已录入第一条
    expect(find.text('回车即可连续添加待办'), findsOneWidget);
    expect(find.text('第一项任务'), findsOneWidget);

    // 2. 输入第二条，按回车提交
    await tester.enterText(find.byType(TextField), '第二项任务');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    // 验证第二条也已成功录入
    expect(find.text('第二项任务'), findsOneWidget);

    // 3. 点击圆形的上箭头按钮退出
    await tester.tap(find.byIcon(Icons.arrow_upward_rounded));
    await tester.pumpAndSettle();

    // 验证弹窗关闭，两条待办都在列表中展示
    expect(find.text('提醒'), findsNothing);
    expect(find.text('第一项任务'), findsOneWidget);
    expect(find.text('第二项任务'), findsOneWidget);
  });

  testWidgets('点击FAB弹出底部小窗，未输入任何内容点击空白退出不添加空事项', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todoListProvider.overrideWith(() => _MockTodoListNotifier([])),
          todoFolderListProvider.overrideWith(() => _MockTodoFolderNotifier()),
        ],
        child: const MaterialApp(
          home: TodoPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 点击浮动按钮添加待办
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // 验证底部小窗已弹出
    expect(find.text('回车即可连续添加待办'), findsOneWidget);

    // 点空白处返回
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // 验证弹窗关闭，且列表依然为空（没有添加空事项）
    expect(find.text('设置提醒'), findsNothing);
    expect(find.text('待办事项'), findsNothing);
  });

  testWidgets('待办事项左滑出现圆形删除按钮，点击删除按钮弹出确认对话框并可删除', (tester) async {
    final todos = [
      Todo(
        id: 't-swipe-1',
        title: '需要左滑删除的待办',
        isCompleted: false,
        folderId: 'folder-1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todoListProvider.overrideWith(() => _MockTodoListNotifier(todos)),
          todoFolderListProvider.overrideWith(() => _MockTodoFolderNotifier()),
        ],
        child: const MaterialApp(
          home: TodoPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 确认待办卡片存在，删除按钮初始未露出
    expect(find.text('需要左滑删除的待办'), findsOneWidget);
    expect(find.byIcon(Icons.delete_outline), findsNothing);

    // 在待办卡片上执行左滑手势
    final todoCard = find.text('需要左滑删除的待办');
    await tester.drag(todoCard, const Offset(-150, 0));
    await tester.pumpAndSettle();

    // 验证左滑后露出了红色圆形的删除按钮
    expect(find.byIcon(Icons.delete_outline), findsOneWidget);

    // 点击圆形删除按钮
    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pumpAndSettle();

    // 验证弹出确认删除对话框
    expect(find.text('确认删除'), findsOneWidget);
    expect(find.text('确定要删除「需要左滑删除的待办」吗？'), findsOneWidget);

    // 点击确认删除
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();

    // 验证待办已被删除，页面展示空状态
    expect(find.text('需要左滑删除的待办'), findsNothing);
    expect(find.text('暂无待办，享受此刻吧'), findsOneWidget);
  });

  testWidgets('支持批量选择、全选/取消全选、二次确认与批量删除', (tester) async {
    final todos = [
      Todo(
        id: 'batch-1',
        title: '批量任务一',
        isCompleted: false,
        folderId: 'folder-1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      Todo(
        id: 'batch-2',
        title: '批量任务二',
        isCompleted: false,
        folderId: 'folder-1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
      Todo(
        id: 'batch-3',
        title: '批量任务三',
        isCompleted: true,
        folderId: 'folder-1',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          todoListProvider.overrideWith(() => _MockTodoListNotifier(todos)),
          todoFolderListProvider.overrideWith(() => _MockTodoFolderNotifier()),
        ],
        child: const MaterialApp(
          home: TodoPage(),
        ),
      ),
    );

    await tester.pumpAndSettle();

    // 初始状态：3 项任务均可见
    expect(find.text('批量任务一'), findsOneWidget);
    expect(find.text('批量任务二'), findsOneWidget);
    expect(find.text('批量任务三'), findsOneWidget);
    expect(find.byIcon(Icons.checklist_outlined), findsOneWidget);

    // 1. 点击顶栏批量管理图标，进入批量选择模式
    await tester.tap(find.byIcon(Icons.checklist_outlined));
    await tester.pumpAndSettle();

    // 验证进入选择模式：AppBar 标题、全选按钮、退出关闭按钮
    expect(find.text('已选择 0 项'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);
    expect(find.byIcon(Icons.close), findsOneWidget);

    // 2. 点击「批量任务一」卡片进行勾选
    await tester.tap(find.text('批量任务一'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 1 项'), findsOneWidget);

    // 3. 点击「批量任务二」卡片进行勾选
    await tester.tap(find.text('批量任务二'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);

    // 4. 点击「全选」，当前分类下的 3 项全部被选中，按钮文案变为「取消全选」
    await tester.tap(find.text('全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 3 项'), findsOneWidget);
    expect(find.text('取消全选'), findsOneWidget);

    // 5. 点击「取消全选」，清空选中项
    await tester.tap(find.text('取消全选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsOneWidget);
    expect(find.text('全选'), findsOneWidget);

    // 6. 勾选前两项任务进行批量删除
    await tester.tap(find.text('批量任务一'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量任务二'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);

    // 7. 点击底栏红色「删除」按钮，触发 3 秒防误触二次确认
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('再次点击确认'), findsOneWidget);

    // 8. 再次点击「再次点击确认」，执行批量删除
    await tester.tap(find.text('再次点击确认'));
    await tester.pumpAndSettle();

    // 验证已删除选中的 2 项，第 3 项仍然存在，且已退出多选模式
    expect(find.text('批量任务一'), findsNothing);
    expect(find.text('批量任务二'), findsNothing);
    expect(find.text('批量任务三'), findsOneWidget);
    expect(find.text('待办'), findsOneWidget);
    expect(find.byIcon(Icons.checklist_outlined), findsOneWidget);
  });
}
