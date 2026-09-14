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
      id: 'mock-todo-id',
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
  });

  testWidgets('点击FAB弹出底部小窗，输入空白直接返回不会添加空事项', (tester) async {
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

    // 验证底部小窗已弹出，包含"完成"按钮与"设置提醒"
    expect(find.text('完成'), findsOneWidget);
    expect(find.text('设置提醒'), findsOneWidget);

    // 点空白处返回
    await tester.tapAt(const Offset(20, 20));
    await tester.pumpAndSettle();

    // 验证弹窗关闭，且列表依然为空（没有添加空事项）
    expect(find.text('设置提醒'), findsNothing);
    expect(find.text('待办事项'), findsNothing);
  });

  testWidgets('底部小窗输入内容并点击完成，成功添加新待办', (tester) async {
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

    // 输入待办内容
    await tester.enterText(find.byType(TextField), '优化Qwen模型推理');
    await tester.pumpAndSettle();

    // 点击完成按钮
    await tester.tap(find.text('完成'));
    await tester.pumpAndSettle();

    // 验证弹窗关闭，且列表中出现了新增的待办事项
    expect(find.text('设置提醒'), findsNothing);
    expect(find.text('优化Qwen模型推理'), findsOneWidget);
  });
}
