import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/utils/reminder_utils.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/providers/todo_folder_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';

/// 已完成待办折叠状态本地持久化键
const String _kTodoCompletedCollapsedKey = 'todo_completed_collapsed';

class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late PageController _pageController;
  final Map<String, ScrollController> _scrollControllers = {};
  bool _isCompletedCollapsed = true;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _loadCollapsedState();
  }

  Future<void> _loadCollapsedState() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getBool(_kTodoCompletedCollapsedKey);
    if (saved != null && mounted) {
      setState(() {
        _isCompletedCollapsed = saved;
      });
    }
  }

  void _toggleCompletedCollapsed() {
    setState(() {
      _isCompletedCollapsed = !_isCompletedCollapsed;
    });
    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(_kTodoCompletedCollapsedKey, _isCompletedCollapsed);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    _scrollControllers.clear();
    super.dispose();
  }

  ScrollController _getScrollController(String folderId) {
    return _scrollControllers.putIfAbsent(folderId, () => ScrollController());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final foldersAsync = ref.watch(todoFolderListProvider);
    final selectedFolderId = ref.watch(selectedTodoFolderIdProvider);
    final todosAsync = ref.watch(todoListProvider);

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: colorScheme.surface,
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          final folders = foldersAsync.valueOrNull;
          final currentFolderId = (selectedFolderId != null &&
                  folders != null &&
                  folders.any((f) => f.id == selectedFolderId))
              ? selectedFolderId
              : (folders != null && folders.isNotEmpty ? folders.first.id : null);
          _addNewTodo(currentFolderId);
        },
        backgroundColor: colorScheme.primary,
        foregroundColor: colorScheme.onPrimary,
        elevation: 2,
        shape: const CircleBorder(),
        child: const Icon(Icons.add, size: 28),
      ),
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: colorScheme.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () {
            FocusScope.of(context).unfocus();
            rootScaffoldKey.currentState?.openDrawer();
          },
        ),
        title: const Text('待办'),
        actions: [
          IconButton(
            icon: Icon(Icons.category_outlined, color: colorScheme.onSurfaceVariant),
            tooltip: '分类管理',
            onPressed: () {
              FocusScope.of(context).unfocus();
              _showFolderManagementBottomSheet(context);
            },
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () {
          FocusScope.of(context).unfocus();
        },
        child: foldersAsync.when(
          data: (folders) {
            if (folders.isEmpty) {
              return const Center(child: Text('暂无分类'));
            }

            final activeFolderId = (selectedFolderId != null &&
                    folders.any((f) => f.id == selectedFolderId))
                ? selectedFolderId
                : folders.first.id;

            final currentIndex = folders.indexWhere((f) => f.id == activeFolderId);
            final safeIndex = currentIndex >= 0 ? currentIndex : 0;

            // 监听外部切换或保持 pageController 同步
            if (_pageController.hasClients &&
                _pageController.page?.round() != safeIndex) {
              _pageController.jumpToPage(safeIndex);
            }

            final allTodos = todosAsync.valueOrNull ?? const <Todo>[];

            return Column(
              children: [
                // 动态横向分类标签栏
                _TodoFolderTabBar(
                  folders: folders,
                  selectedFolderId: activeFolderId,
                  todos: allTodos,
                  onSelect: (folderId) {
                    FocusScope.of(context).unfocus();
                    ref.read(selectedTodoFolderIdProvider.notifier).state = folderId;
                    final targetIndex = folders.indexWhere((f) => f.id == folderId);
                    if (targetIndex >= 0 && _pageController.hasClients) {
                      _pageController.animateToPage(
                        targetIndex,
                        duration: AppDurations.medium,
                        curve: Curves.easeInOut,
                      );
                    }
                  },
                  onAddFolder: () => _showAddFolderDialog(context),
                ),
                Expanded(
                  child: PageView.builder(
                    controller: _pageController,
                    itemCount: folders.length,
                    onPageChanged: (index) {
                      FocusScope.of(context).unfocus();
                      final fId = folders[index].id;
                      ref.read(selectedTodoFolderIdProvider.notifier).state = fId;
                    },
                    itemBuilder: (context, index) {
                      final folder = folders[index];
                      // 筛选当前分类的未完成待办
                      final activeTodos = allTodos.where((t) {
                        if (t.isCompleted) return false;
                        if (t.title.trim().isEmpty) return false;
                        if (t.folderId == folder.id) return true;
                        if (t.folderId == null || t.folderId!.isEmpty) {
                          if (folder.id == 'todo_default_longterm' || folder.name == '长期') {
                            return t.isLongTerm;
                          }
                          if (folder.id == 'todo_default_today' || index == 0) {
                            return !t.isLongTerm;
                          }
                        }
                        return false;
                      }).toList();

                      // 筛选当前分类的已完成待办
                      final completedTodos = allTodos.where((t) {
                        if (!t.isCompleted) return false;
                        if (t.title.trim().isEmpty) return false;
                        if (t.folderId == folder.id) return true;
                        if (t.folderId == null || t.folderId!.isEmpty) {
                          if (folder.id == 'todo_default_longterm' || folder.name == '长期') {
                            return t.isLongTerm;
                          }
                          if (folder.id == 'todo_default_today' || index == 0) {
                            return !t.isLongTerm;
                          }
                        }
                        return false;
                      }).toList();

                      return _buildTodoList(
                        context,
                        folder.id,
                        todosAsync,
                        activeTodos,
                        completedTodos,
                      );
                    },
                  ),
                ),
              ],
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('分类加载失败: $e')),
        ),
      ),
    );
  }

  Widget _buildTodoList(
    BuildContext context,
    String folderId,
    AsyncValue<List<Todo>> todosAsync,
    List<Todo> activeTodos,
    List<Todo> completedTodos,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return todosAsync.when(
      data: (_) {
        if (activeTodos.isEmpty && completedTodos.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.assignment_turned_in_outlined,
                  size: 56,
                  color: colorScheme.outlineVariant.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 12),
                Text(
                  '暂无待办，享受此刻吧',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          );
        }

        final scrollController = _getScrollController(folderId);

        return ReorderableListView.builder(
          scrollController: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
          itemCount: activeTodos.length,
          onReorderItem: (oldIndex, newIndex) {
            if (oldIndex < 0 || oldIndex >= activeTodos.length) return;
            if (newIndex < 0 || newIndex > activeTodos.length) return;
            final list = List<Todo>.from(activeTodos);
            final item = list.removeAt(oldIndex);
            list.insert(newIndex, item);
            final allTodosList = todosAsync.valueOrNull ?? [];
            final otherTodos =
                allTodosList.where((t) => t.isCompleted || t.folderId != folderId).toList();
            ref.read(todoListProvider.notifier).reorderTodos([...list, ...otherTodos]);
          },
          itemBuilder: (context, index) {
            final todo = activeTodos[index];
            return RepaintBoundary(
              key: ValueKey(todo.id),
              child: _TodoItem(
                key: ValueKey('todo_item_${todo.id}'),
                todo: todo,
                index: index,
                isDraggable: true,
                onTap: () => _showTodoBottomSheet(context, todo: todo, folderId: folderId),
                onToggleComplete: () {
                  ref.read(todoListProvider.notifier).toggleComplete(todo.id, true);
                },
                onLongPress: (globalKey) {
                  _showActionMenu(context, todo, globalKey);
                },
              ),
            );
          },
          footer: completedTodos.isEmpty
              ? null
              : _buildCompletedSection(context, completedTodos, folderId),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
    );
  }

  /// 构建已完成待办折叠区域
  Widget _buildCompletedSection(
    BuildContext context,
    List<Todo> completedTodos,
    String folderId,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 仿小米待办：折叠/展开栏
          InkWell(
            onTap: _toggleCompletedCollapsed,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _isCompletedCollapsed ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                    size: 18,
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '已完成 ${completedTodos.length}',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!_isCompletedCollapsed) ...[
            const SizedBox(height: 4),
            ...completedTodos.map(
              (todo) => _TodoItem(
                key: ValueKey('todo_completed_${todo.id}'),
                todo: todo,
                index: -1,
                isDraggable: false,
                onTap: () => _showTodoBottomSheet(context, todo: todo, folderId: folderId),
                onToggleComplete: () {
                  ref.read(todoListProvider.notifier).toggleComplete(todo.id, false);
                },
                onLongPress: (globalKey) {
                  _showActionMenu(context, todo, globalKey);
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 唤起底部小窗添加待办
  void _addNewTodo(String? folderId) {
    _showTodoBottomSheet(context, folderId: folderId);
  }

  /// 唤起底部小窗（用于添加或编辑待办）
  void _showTodoBottomSheet(
    BuildContext context, {
    Todo? todo,
    String? folderId,
  }) {
    final folders = ref.read(todoFolderListProvider).valueOrNull ?? [];
    final selectedFolderId = ref.read(selectedTodoFolderIdProvider);
    final currentFolderId = folderId ??
        ((selectedFolderId != null && folders.any((f) => f.id == selectedFolderId))
            ? selectedFolderId
            : (folders.isNotEmpty ? folders.first.id : null));

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _TodoEditBottomSheet(
        todo: todo,
        folderId: currentFolderId,
        folders: folders,
        onSaveAdd: ({
          required String title,
          String? reminderTime,
          String repeatRule = 'none',
          String? folderId,
        }) {
          if (title.trim().isEmpty) return;
          ref.read(todoListProvider.notifier).addTodo(
                title: title.trim(),
                folderId: folderId,
                reminderTime: reminderTime,
                repeatRule: repeatRule,
              );
        },
        onSaveEdit: ({required Todo updatedTodo}) {
          if (updatedTodo.title.trim().isEmpty) return;
          ref.read(todoListProvider.notifier).updateTodo(updatedTodo);
        },
        onDelete: (t) => _confirmDelete(t),
        onQuoteToQ: (t) => _quoteTodoToQ(t),
      ),
    );
  }

  void _showActionMenu(BuildContext context, Todo todo, GlobalKey key) {
    final folders = ref.read(todoFolderListProvider).valueOrNull ?? [];
    final items = <ActionMenuItem>[
      ActionMenuItem(
        iconWidget: QIcon(
          size: 20,
          color: Theme.of(context).colorScheme.primary,
        ),
        label: '给小Q',
        onTap: () => _quoteTodoToQ(todo),
      ),
      ActionMenuItem(
        icon: Icons.repeat,
        label: todo.isRecurring ? '重复: ${todo.repeatRuleLabel}' : '设置重复周期',
        onTap: () => _showRepeatRuleDialog(context, todo),
      ),
      ActionMenuItem(
        icon: Icons.alarm,
        label: todo.reminderTime != null ? '修改提醒 (${todo.reminderTime})' : '设置提醒时间',
        onTap: () => _setReminder(todo),
      ),
      if (todo.reminderTime != null)
        ActionMenuItem(
          icon: Icons.alarm_off,
          label: '清除提醒',
          isDestructive: true,
          onTap: () => ref.read(todoListProvider.notifier).clearReminder(todo.id),
        ),
      if (folders.length > 1)
        ActionMenuItem(
          icon: Icons.drive_file_move_outlined,
          label: '移动分类...',
          onTap: () => _showMoveFolderDialog(context, todo, folders),
        ),
      ActionMenuItem(
        icon: Icons.delete_outline,
        label: '删除',
        isDestructive: true,
        onTap: () => _confirmDelete(todo),
      ),
    ];

    ActionMenu.show(context: context, key: key, items: items);
  }

  /// 「给小Q」：把该条待办引用给悬浮小Q
  void _quoteTodoToQ(Todo todo) {
    HapticFeedback.lightImpact();
    final title = todo.title.trim();
    final desc = todo.description.trim();
    final due = todo.dueDate;
    ref.read(floatingQProvider.notifier).openWithQuote(QTextQuote(
          source: QQuoteSource.todo,
          sourceId: todo.id,
          sourceTitle: title.isEmpty ? '一条待办' : title,
          quotedText: desc.isNotEmpty ? desc : title,
          locationDesc: due == null
              ? null
              : '截止 ${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')} '
                  '${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}',
        ));
  }

  /// 设置待办重复周期
  Future<void> _showRepeatRuleDialog(BuildContext context, Todo todo) async {
    final rules = [
      {'key': 'none', 'label': '不重复', 'desc': '单次任务，完成后不自动生成'},
      {'key': 'daily', 'label': '每天重复', 'desc': '完成后自动生成次日待办'},
      {'key': 'workday', 'label': '工作日重复', 'desc': '周一至周五，周末自动顺延至下周一'},
      {'key': 'weekly', 'label': '每周重复', 'desc': '每周相同时间再次出现'},
      {'key': 'monthly', 'label': '每月重复', 'desc': '每月同日再次出现'},
      {'key': 'yearly', 'label': '每年重复', 'desc': '每年同日再次出现'},
    ];

    final theme = Theme.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.repeat, color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '设置重复周期',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ...rules.map((r) {
                  final isSelected = todo.repeatRule == r['key'];
                  return ListTile(
                    leading: Icon(
                      isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline,
                    ),
                    title: Text(
                      r['label']!,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      r['desc']!,
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onTap: () {
                      Navigator.pop(ctx);
                      ref.read(todoListProvider.notifier).setRepeatRule(todo.id, r['key']!);
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 移动分类对话框
  Future<void> _showMoveFolderDialog(
    BuildContext context,
    Todo todo,
    List<Folder> folders,
  ) async {
    final theme = Theme.of(context);
    await showModalBottomSheet(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.drive_file_move_outlined, color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '移动到分类',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ...folders.map((f) {
                  final isCurrent = todo.folderId == f.id;
                  return ListTile(
                    leading: Icon(
                      isCurrent ? Icons.folder : Icons.folder_outlined,
                      color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      f.name,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    trailing: isCurrent
                        ? Text('当前分类', style: TextStyle(fontSize: 12, color: theme.colorScheme.primary))
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      if (!isCurrent) {
                        ref.read(todoListProvider.notifier).moveToFolder(todo.id, f.id);
                      }
                    },
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 分类管理底栏
  Future<void> _showFolderManagementBottomSheet(BuildContext context) async {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large)),
      ),
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, child) {
            final folders = ref.watch(todoFolderListProvider).valueOrNull ?? [];
            return SafeArea(
              child: Container(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.7,
                ),
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.category, color: colorScheme.primary, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                '待办分类管理',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: colorScheme.onSurface,
                                ),
                              ),
                            ],
                          ),
                          TextButton.icon(
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('新建分类'),
                            onPressed: () => _showAddFolderDialog(context),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Expanded(
                      child: ListView.separated(
                        shrinkWrap: true,
                        itemCount: folders.length,
                        separatorBuilder: (context, index) => const Divider(height: 1, indent: 56),
                        itemBuilder: (context, index) {
                          final folder = folders[index];
                          final isOnlyOne = folders.length <= 1;
                          return ListTile(
                            leading: Icon(Icons.folder_open, color: colorScheme.primary),
                            title: Text(
                              folder.name,
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.edit_outlined, size: 18),
                                  tooltip: '重命名',
                                  onPressed: () => _showEditFolderDialog(context, folder),
                                ),
                                IconButton(
                                  icon: Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: isOnlyOne ? colorScheme.outlineVariant : colorScheme.error,
                                  ),
                                  tooltip: isOnlyOne ? '至少保留一个分类' : '删除分类',
                                  onPressed: isOnlyOne
                                      ? () {
                                          ScaffoldMessenger.of(context).showSnackBar(
                                            const SnackBar(content: Text('至少需要保留一个分类，无法删除')),
                                          );
                                        }
                                      : () => _confirmDeleteFolder(context, folder),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// 新建分类对话框
  Future<void> _showAddFolderDialog(BuildContext context) async {
    final controller = TextEditingController();
    final confirmed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分类'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '请输入分类名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    if (confirmed != null && confirmed.isNotEmpty) {
      ref.read(todoFolderListProvider.notifier).addFolder(confirmed);
    }
  }

  /// 编辑分类名称对话框
  Future<void> _showEditFolderDialog(BuildContext context, Folder folder) async {
    final controller = TextEditingController(text: folder.name);
    final confirmed = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分类'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '请输入新名称',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed != null && confirmed.isNotEmpty && confirmed != folder.name) {
      ref.read(todoFolderListProvider.notifier).updateFolder(folder.id, confirmed);
    }
  }

  /// 删除分类确认弹窗
  Future<void> _confirmDeleteFolder(BuildContext context, Folder folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('确定要删除分类「${folder.name}」吗？\n\n注意：该分类下的所有待办事项将一并删除！'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确认删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final success = await ref.read(todoFolderListProvider.notifier).deleteFolder(folder.id);
      if (!success && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('至少需要保留一个分类，无法删除')),
        );
      }
    }
  }

  Future<void> _setReminder(Todo todo) async {
    final reminder = todo.reminderTime;
    final result = await showTimePickerDialog(
      context: context,
      initialTime: reminder != null ? ReminderUtils.parse(reminder) : null,
      title: '设置提醒时间',
    );
    if (result == null) return;
    final formatted = ReminderUtils.format(result);
    ref.read(todoListProvider.notifier).setReminder(todo.id, formatted);
  }

  Future<void> _confirmDelete(Todo todo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「${todo.title.isEmpty ? '待办' : todo.title}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      HapticFeedback.heavyImpact();
      ref.read(todoListProvider.notifier).deleteTodo(todo.id);
    }
  }
}

/// 动态横向分类标签栏
class _TodoFolderTabBar extends StatelessWidget {
  final List<Folder> folders;
  final String selectedFolderId;
  final List<Todo> todos;
  final ValueChanged<String> onSelect;
  final VoidCallback onAddFolder;

  const _TodoFolderTabBar({
    required this.folders,
    required this.selectedFolderId,
    required this.todos,
    required this.onSelect,
    required this.onAddFolder,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      height: 46,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              physics: const BouncingScrollPhysics(),
              itemCount: folders.length,
              separatorBuilder: (context, index) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final folder = folders[index];
                final isSelected = folder.id == selectedFolderId;
                // 计算未完成待办数
                final count = todos.where((t) {
                  if (t.isCompleted || t.title.trim().isEmpty) return false;
                  if (t.folderId == folder.id) return true;
                  if (t.folderId == null || t.folderId!.isEmpty) {
                    if (folder.id == 'todo_default_longterm' || folder.name == '长期') {
                      return t.isLongTerm;
                    }
                    if (folder.id == 'todo_default_today' || index == 0) {
                      return !t.isLongTerm;
                    }
                  }
                  return false;
                }).length;

                return GestureDetector(
                  onTap: () => onSelect(folder.id),
                  child: AnimatedContainer(
                    duration: AppDurations.normal,
                    curve: Curves.easeInOut,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(AppRadius.large),
                      border: Border.all(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.outlineVariant.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          folder.name,
                          style: TextStyle(
                            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                            fontSize: 13.5,
                            color: isSelected
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
                          ),
                        ),
                        if (count > 0) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                            decoration: BoxDecoration(
                              color: isSelected
                                  ? colorScheme.onPrimary.withValues(alpha: 0.2)
                                  : colorScheme.primary.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$count',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: isSelected ? colorScheme.onPrimary : colorScheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: 6),
          IconButton(
            icon: const Icon(Icons.add, size: 20),
            tooltip: '新建分类',
            style: IconButton.styleFrom(
              backgroundColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.large)),
              padding: const EdgeInsets.all(8),
              minimumSize: const Size(36, 36),
            ),
            onPressed: onAddFolder,
          ),
        ],
      ),
    );
  }
}

/// 仿小米待办卡片组件
class _TodoItem extends StatefulWidget {
  final Todo todo;
  final int index;
  final bool isDraggable;
  final VoidCallback onTap;
  final VoidCallback onToggleComplete;
  final void Function(GlobalKey key) onLongPress;

  const _TodoItem({
    super.key,
    required this.todo,
    required this.index,
    this.isDraggable = true,
    required this.onTap,
    required this.onToggleComplete,
    required this.onLongPress,
  });

  @override
  State<_TodoItem> createState() => _TodoItemState();
}

class _TodoItemState extends State<_TodoItem> with SingleTickerProviderStateMixin {
  final GlobalKey _cardKey = GlobalKey();
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _heightFactor;
  late Animation<double> _opacityAnimation;

  bool _localCompleted = false;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: AppDurations.medium,
    );

    _scaleAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack,
      reverseCurve: Curves.easeIn,
    );

    _heightFactor = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeInOut,
    );

    _opacityAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeIn,
      reverseCurve: Curves.easeOut,
    );

    _animController.forward();
  }

  @override
  void didUpdateWidget(covariant _TodoItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.todo.isCompleted != widget.todo.isCompleted) {
      setState(() {
        _localCompleted = widget.todo.isCompleted;
      });
      if (widget.todo.isCompleted) {
        _animController.value = 1.0;
      } else {
        _animController.forward();
      }
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    super.dispose();
  }

  void _handleToggleComplete() {
    HapticFeedback.mediumImpact();
    if (widget.todo.isCompleted) {
      widget.onToggleComplete();
      return;
    }

    setState(() {
      _localCompleted = true;
    });

    _animController.reverse().then((_) {
      widget.onToggleComplete();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final todo = widget.todo;
    final isDone = todo.isCompleted || _localCompleted;

    return SizeTransition(
      sizeFactor: _heightFactor,
      alignment: const Alignment(-1.0, -1.0),
      child: FadeTransition(
        opacity: _opacityAnimation,
        child: ScaleTransition(
          scale: _scaleAnimation,
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: isDark
                  ? colorScheme.surfaceContainer
                  : colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: isDark ? 0.25 : 0.4),
              ),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.shadow.withValues(alpha: 0.02),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  if (widget.isDraggable)
                    ReorderableDragStartListener(
                      index: widget.index,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: Icon(
                          Icons.drag_indicator,
                          size: 18,
                          color: colorScheme.onSurfaceVariant.withValues(alpha: 0.25),
                        ),
                      ),
                    ),
                  // 小米风格圆角方形复选框
                  GestureDetector(
                    onTap: _handleToggleComplete,
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: AppDurations.medium,
                      curve: Curves.easeInOut,
                      width: 20,
                      height: 20,
                      margin: const EdgeInsets.only(right: 10),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(
                          color: isDone
                              ? (isDark ? Colors.white30 : colorScheme.outline.withValues(alpha: 0.4))
                              : colorScheme.outline.withValues(alpha: 0.5),
                          width: 1.8,
                        ),
                        color: isDone
                            ? (isDark ? Colors.white24 : colorScheme.primary.withValues(alpha: 0.15))
                            : Colors.transparent,
                      ),
                      child: isDone
                          ? TweenAnimationBuilder<double>(
                              tween: Tween(begin: 0.0, end: 1.0),
                              duration: AppDurations.medium,
                              curve: Curves.elasticOut,
                              builder: (context, value, child) {
                                return Transform.scale(
                                  scale: value,
                                  child: child,
                                );
                              },
                              child: Icon(
                                Icons.check,
                                size: 14,
                                color: isDark ? Colors.white70 : colorScheme.primary,
                              ),
                            )
                          : null,
                    ),
                  ),
                  // 待办标题与辅助状态（点击卡片唤出底部小窗编辑，长按弹出操作菜单）
                  Expanded(
                    child: GestureDetector(
                      key: _cardKey,
                      behavior: HitTestBehavior.opaque,
                      onTap: widget.onTap,
                      onLongPress: () => widget.onLongPress(_cardKey),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            todo.title.isEmpty ? '待办事项' : todo.title,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isDone ? FontWeight.normal : FontWeight.w600,
                              fontSize: 15.5,
                              decoration: isDone ? TextDecoration.lineThrough : TextDecoration.none,
                              color: isDone
                                  ? colorScheme.onSurfaceVariant.withValues(alpha: 0.5)
                                  : colorScheme.onSurface,
                            ),
                          ),
                          if (todo.isRecurring || todo.reminderTime != null || todo.description.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                if (todo.isRecurring) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                    margin: const EdgeInsets.only(right: 6),
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.repeat, size: 11, color: colorScheme.primary),
                                        const SizedBox(width: 3),
                                        Text(
                                          todo.repeatRuleLabel,
                                          style: TextStyle(
                                            fontSize: 10.5,
                                            fontWeight: FontWeight.bold,
                                            color: colorScheme.primary,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                                if (todo.reminderTime != null) ...[
                                  Icon(
                                    Icons.alarm,
                                    size: 12,
                                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                  ),
                                  const SizedBox(width: 3),
                                  Text(
                                    todo.reminderTime!,
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                ],
                                if (todo.description.isNotEmpty)
                                  Expanded(
                                    child: Text(
                                      todo.description,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.bodySmall?.copyWith(
                                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                        fontSize: 11,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 仿小米待办：底部弹出小窗（用于添加或编辑待办事项）
class _TodoEditBottomSheet extends StatefulWidget {
  final Todo? todo;
  final String? folderId;
  final List<Folder> folders;
  final void Function({
    required String title,
    String? reminderTime,
    String repeatRule,
    String? folderId,
  }) onSaveAdd;
  final void Function({required Todo updatedTodo}) onSaveEdit;
  final void Function(Todo todo)? onDelete;
  final void Function(Todo todo)? onQuoteToQ;

  const _TodoEditBottomSheet({
    this.todo,
    this.folderId,
    required this.folders,
    required this.onSaveAdd,
    required this.onSaveEdit,
    this.onDelete,
    this.onQuoteToQ,
  });

  @override
  State<_TodoEditBottomSheet> createState() => _TodoEditBottomSheetState();
}

class _TodoEditBottomSheetState extends State<_TodoEditBottomSheet> {
  late TextEditingController _textController;
  String? _reminderTime;
  String _repeatRule = 'none';
  String? _selectedFolderId;
  bool _isCompleted = false;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.todo?.title ?? '');
    _reminderTime = widget.todo?.reminderTime;
    _repeatRule = widget.todo?.repeatRule ?? 'none';
    _selectedFolderId = widget.todo?.folderId ?? widget.folderId;
    _isCompleted = widget.todo?.isCompleted ?? false;
    _textController.addListener(_onTextChanged);
  }

  void _onTextChanged() {
    setState(() {});
  }

  @override
  void dispose() {
    _textController.removeListener(_onTextChanged);
    _textController.dispose();
    super.dispose();
  }

  void _handleSubmitted(String value) {
    final text = value.trim();
    if (widget.todo == null) {
      // 添加模式：回车即可连续添加待办
      if (text.isNotEmpty) {
        widget.onSaveAdd(
          title: text,
          reminderTime: _reminderTime,
          repeatRule: _repeatRule,
          folderId: _selectedFolderId,
        );
        HapticFeedback.lightImpact();
        _textController.clear();
        setState(() {
          _reminderTime = null;
          _repeatRule = 'none';
        });
      }
    } else {
      // 编辑模式：回车直接保存并关闭
      _handleComplete();
    }
  }

  void _handleComplete() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      // 若没有编辑内容，直接返回，程序不会把空的事项添加上去
      Navigator.pop(context);
      return;
    }

    if (widget.todo == null) {
      // 添加待办
      widget.onSaveAdd(
        title: text,
        reminderTime: _reminderTime,
        repeatRule: _repeatRule,
        folderId: _selectedFolderId,
      );
    } else {
      // 编辑待办
      widget.onSaveEdit(
        updatedTodo: widget.todo!.copyWith(
          title: text,
          reminderTime: _reminderTime,
          repeatRule: _repeatRule,
          folderId: _selectedFolderId,
          isCompleted: _isCompleted,
        ),
      );
    }
    Navigator.pop(context);
  }

  Future<void> _pickReminderTime() async {
    final reminder = _reminderTime;
    final initialDate = reminder != null ? ReminderUtils.parse(reminder) : null;
    final result = await showTimePickerDialog(
      context: context,
      initialTime: initialDate,
      title: '设置提醒时间',
    );
    if (result != null) {
      setState(() {
        _reminderTime = ReminderUtils.format(result);
      });
    }
  }

  Future<void> _pickRepeatRule() async {
    final rules = [
      {'key': 'none', 'label': '不重复', 'desc': '单次任务，完成后不自动生成'},
      {'key': 'daily', 'label': '每天重复', 'desc': '完成后自动生成次日待办'},
      {'key': 'workday', 'label': '工作日重复', 'desc': '周一至周五，周末自动顺延至下周一'},
      {'key': 'weekly', 'label': '每周重复', 'desc': '每周相同时间再次出现'},
      {'key': 'monthly', 'label': '每月重复', 'desc': '每月同日再次出现'},
      {'key': 'yearly', 'label': '每年重复', 'desc': '每年同日再次出现'},
    ];

    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.repeat, color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '设置重复周期',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ...rules.map((r) {
                  final isSelected = _repeatRule == r['key'];
                  return ListTile(
                    leading: Icon(
                      isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
                      color: isSelected ? theme.colorScheme.primary : theme.colorScheme.outline,
                    ),
                    title: Text(
                      r['label']!,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    subtitle: Text(
                      r['desc']!,
                      style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                    ),
                    onTap: () => Navigator.pop(ctx, r['key']),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null) {
      setState(() {
        _repeatRule = selected;
      });
    }
  }

  Future<void> _pickFolder() async {
    if (widget.folders.length <= 1) return;
    final theme = Theme.of(context);
    final selected = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large)),
      ),
      builder: (ctx) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.folder_outlined, color: theme.colorScheme.primary, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '选择分类',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const Divider(height: 1),
                ...widget.folders.map((f) {
                  final isCurrent = _selectedFolderId == f.id;
                  return ListTile(
                    leading: Icon(
                      isCurrent ? Icons.folder : Icons.folder_outlined,
                      color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      f.name,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.onSurface,
                      ),
                    ),
                    trailing: isCurrent
                        ? Text('当前分类', style: TextStyle(fontSize: 12, color: theme.colorScheme.primary))
                        : null,
                    onTap: () => Navigator.pop(ctx, f.id),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );

    if (selected != null) {
      setState(() {
        _selectedFolderId = selected;
      });
    }
  }

  String _repeatRuleLabel(String rule) {
    switch (rule) {
      case 'daily':
        return '每天重复';
      case 'workday':
        return '工作日重复';
      case 'weekly':
        return '每周重复';
      case 'monthly':
        return '每月重复';
      case 'yearly':
        return '每年重复';
      default:
        return '重复';
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final hasText = _textController.text.trim().isNotEmpty;

    // 当前选中的分类名称
    final selectedFolder = widget.folders.where((f) => f.id == _selectedFolderId).firstOrNull ??
        widget.folders.firstOrNull;
    final selectedFolderName = selectedFolder?.name ?? '';

    final viewInsetsBottom = MediaQuery.of(context).viewInsets.bottom;
    final bottomMargin = viewInsetsBottom > 0 ? (viewInsetsBottom + 12.0) : 16.0;

    return Padding(
      padding: EdgeInsets.only(bottom: bottomMargin, left: 14, right: 14),
      child: Container(
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF222222) : colorScheme.surface,
          borderRadius: BorderRadius.circular(28),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 24,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
        child: SafeArea(
          top: false,
          bottom: viewInsetsBottom == 0,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 待办输入区（左侧圆角方块，中间自动聚焦输入框，更舒展宽阔）
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
                    onTap: widget.todo == null
                        ? null
                        : () {
                            setState(() {
                              _isCompleted = !_isCompleted;
                            });
                          },
                    child: Container(
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.only(top: 3, right: 14),
                      decoration: BoxDecoration(
                        color: _isCompleted
                            ? (isDark ? Colors.white24 : colorScheme.primary.withValues(alpha: 0.15))
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: _isCompleted
                              ? (isDark ? Colors.white38 : colorScheme.outline.withValues(alpha: 0.4))
                              : (isDark ? Colors.white54 : colorScheme.outline.withValues(alpha: 0.5)),
                          width: 2.0,
                        ),
                      ),
                      child: _isCompleted
                          ? Icon(
                              Icons.check,
                              size: 15,
                              color: isDark ? Colors.white70 : colorScheme.primary,
                            )
                          : null,
                    ),
                  ),
                  Expanded(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(minHeight: 52),
                      child: TextField(
                        controller: _textController,
                        autofocus: true,
                        maxLines: 5,
                        minLines: 1,
                        textInputAction: TextInputAction.send,
                        onSubmitted: _handleSubmitted,
                        style: TextStyle(
                          fontSize: 17.5,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                          color: isDark ? Colors.white : colorScheme.onSurface,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(vertical: 2),
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                          filled: false,
                          hintText: widget.todo == null ? '回车即可连续添加待办' : '输入待办内容...',
                          hintStyle: TextStyle(
                            fontSize: 17.5,
                            color: isDark
                                ? Colors.white.withValues(alpha: 0.35)
                                : colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
                            fontWeight: FontWeight.normal,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 26),
              // 底部功能胶囊栏与完成按钮
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          // 设置提醒胶囊
                          InkWell(
                            onTap: _pickReminderTime,
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                              decoration: BoxDecoration(
                                color: _reminderTime != null
                                    ? colorScheme.primary.withValues(alpha: 0.15)
                                    : (isDark ? Colors.white.withValues(alpha: 0.08) : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.alarm,
                                    size: 15,
                                    color: _reminderTime != null
                                        ? colorScheme.primary
                                        : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _reminderTime ?? '提醒',
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: _reminderTime != null ? FontWeight.w600 : FontWeight.normal,
                                      color: _reminderTime != null
                                          ? colorScheme.primary
                                          : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                    ),
                                  ),
                                  if (_reminderTime != null) ...[
                                    const SizedBox(width: 4),
                                    GestureDetector(
                                      onTap: () {
                                        setState(() => _reminderTime = null);
                                      },
                                      child: Icon(Icons.close, size: 13, color: colorScheme.primary),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 设置重复胶囊
                          InkWell(
                            onTap: _pickRepeatRule,
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                              decoration: BoxDecoration(
                                color: _repeatRule != 'none'
                                    ? colorScheme.primary.withValues(alpha: 0.15)
                                    : (isDark ? Colors.white.withValues(alpha: 0.08) : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.repeat,
                                    size: 15,
                                    color: _repeatRule != 'none'
                                        ? colorScheme.primary
                                        : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    _repeatRuleLabel(_repeatRule),
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: _repeatRule != 'none' ? FontWeight.w600 : FontWeight.normal,
                                      color: _repeatRule != 'none'
                                          ? colorScheme.primary
                                          : (isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          // 切换分类胶囊（若分类数大于1）
                          if (widget.folders.length > 1 && selectedFolderName.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            InkWell(
                              onTap: _pickFolder,
                              borderRadius: BorderRadius.circular(8),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5.5),
                                decoration: BoxDecoration(
                                  color: isDark ? Colors.white.withValues(alpha: 0.08) : colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.folder_outlined, size: 15, color: isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                    const SizedBox(width: 4),
                                    Text(
                                      selectedFolderName,
                                      style: TextStyle(fontSize: 13, color: isDark ? Colors.white70 : colorScheme.onSurfaceVariant),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                          // 编辑模式：给小Q 与 删除操作
                          if (widget.todo != null) ...[
                            const SizedBox(width: 6),
                            IconButton(
                              icon: QIcon(
                                size: 20,
                                color: colorScheme.primary,
                              ),
                              tooltip: '给小Q',
                              onPressed: () {
                                Navigator.pop(context);
                                widget.onQuoteToQ?.call(widget.todo!);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            ),
                            IconButton(
                              icon: Icon(Icons.delete_outline, size: 20, color: colorScheme.error),
                              tooltip: '删除',
                              onPressed: () {
                                Navigator.pop(context);
                                widget.onDelete?.call(widget.todo!);
                              },
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  // 圆形上箭头完成/提交按钮（统一遵循应用全局主题色）
                  Semantics(
                    button: true,
                    label: '完成',
                    child: Tooltip(
                      message: '完成',
                      child: GestureDetector(
                        onTap: _handleComplete,
                        child: AnimatedContainer(
                          duration: AppDurations.normal,
                          curve: Curves.easeInOut,
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: hasText
                                ? colorScheme.primary
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.1)
                                    : colorScheme.surfaceContainerHighest.withValues(alpha: 0.8)),
                          ),
                          child: Icon(
                            Icons.arrow_upward_rounded,
                            size: 20,
                            color: hasText
                                ? colorScheme.onPrimary
                                : (isDark
                                    ? Colors.white.withValues(alpha: 0.3)
                                    : colorScheme.onSurfaceVariant.withValues(alpha: 0.4)),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
