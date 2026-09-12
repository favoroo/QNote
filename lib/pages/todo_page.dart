import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:qnote_flutter/widgets/time_picker.dart';

class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _focusedTodoId;
  late PageController _pageController;
  final Map<String, ScrollController> _scrollControllers = {};

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
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
      endDrawer: const _HistoryDrawer(),
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
          IconButton(
            icon: Icon(Icons.history_rounded, color: colorScheme.onSurfaceVariant),
            tooltip: '已完成历史',
            onPressed: () {
              FocusScope.of(context).unfocus();
              _scaffoldKey.currentState?.openEndDrawer();
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
                    setState(() => _focusedTodoId = null);
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
                      setState(() => _focusedTodoId = null);
                      final fId = folders[index].id;
                      ref.read(selectedTodoFolderIdProvider.notifier).state = fId;
                    },
                    itemBuilder: (context, index) {
                      final folder = folders[index];
                      // 筛选当前分类的待办
                      final folderTodos = allTodos.where((t) {
                        if (t.isCompleted) return false;
                        // 内容为空且不是当前新建聚焦待办，不予显示
                        if (t.title.trim().isEmpty && t.id != _focusedTodoId) return false;
                        if (t.folderId == folder.id) return true;
                        // 容错兜底：若 folderId 为空，非长期待办归于今日/首个分类，长期待办归于长期分类
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

                      return _buildTodoList(context, folder.id, todosAsync, folderTodos);
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
    List<Todo> filteredTodos,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return todosAsync.when(
      data: (_) {
        if (filteredTodos.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.assignment_turned_in_outlined,
                    size: 56, color: colorScheme.outlineVariant.withValues(alpha: 0.5)),
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
          itemCount: filteredTodos.length,
          onReorderItem: (oldIndex, newIndex) {
            final list = List<Todo>.from(filteredTodos);
            final item = list.removeAt(oldIndex);
            list.insert(newIndex, item);
            final allTodosList = todosAsync.valueOrNull ?? [];
            final otherTodos =
                allTodosList.where((t) => t.isCompleted || t.folderId != folderId).toList();
            ref.read(todoListProvider.notifier).reorderTodos([...list, ...otherTodos]);
          },
          itemBuilder: (context, index) {
            final todo = filteredTodos[index];
            return RepaintBoundary(
              key: ValueKey(todo.id),
              child: _TodoItem(
                key: ValueKey('todo_item_${todo.id}'),
                todo: todo,
                index: index,
                autoFocus: todo.id == _focusedTodoId,
                onEditingComplete: () {
                  if (mounted && _focusedTodoId == todo.id) {
                    setState(() {
                      _focusedTodoId = null;
                    });
                  }
                },
                onToggleComplete: () {
                  ref.read(todoListProvider.notifier).toggleComplete(todo.id, true);
                },
                onTitleChanged: (newTitle) {
                  if (newTitle.trim().isEmpty) return;
                  if (newTitle.trim() == todo.title) return;
                  ref.read(todoListProvider.notifier).updateTodo(
                        todo.copyWith(title: newTitle.trim()),
                      );
                },
                onDeleteEmpty: () {
                  ref.read(todoListProvider.notifier).deleteTodo(todo.id);
                },
                onShowMenu: (globalKey) {
                  _showActionMenu(context, todo, globalKey);
                },
                onSetReminder: () => _setReminder(todo),
              ),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
    );
  }

  void _addNewTodo(String? folderId) {
    var targetFolderId = folderId;
    if (targetFolderId == null) {
      final folders = ref.read(todoFolderListProvider).valueOrNull;
      if (folders != null && folders.isNotEmpty) {
        targetFolderId = folders.first.id;
      }
    }
    if (targetFolderId == null) return;

    ref.read(todoListProvider.notifier).addTodo(
          title: '',
          folderId: targetFolderId,
        ).then((todo) {
      if (!mounted) return;
      setState(() {
        _focusedTodoId = todo.id;
      });
      // 自动滚动到底部，确保新建的输入框立即可见
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final sc = _scrollControllers[targetFolderId];
        if (sc != null && sc.hasClients) {
          sc.animateTo(
            sc.position.maxScrollExtent,
            duration: AppDurations.normal,
            curve: Curves.easeOut,
          );
        }
      });
    });
  }

  void _showActionMenu(BuildContext context, Todo todo, GlobalKey key) {
    final folders = ref.read(todoFolderListProvider).valueOrNull ?? [];
    final items = <ActionMenuItem>[
      ActionMenuItem(
        icon: Icons.smart_toy_rounded,
        label: '给小Q',
        onTap: () => _quoteTodoToQ(todo),
      ),
      ActionMenuItem(
        icon: todo.priority == 'important' ? Icons.flag_outlined : Icons.flag,
        label: todo.priority == 'important' ? '设为普通' : '设为重要',
        onTap: () => ref.read(todoListProvider.notifier).togglePriority(todo.id),
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

  /// 「给小Q」：把该条待办引用给悬浮小Q（修改内容/时间、拆解子任务均可），
  /// 待办 id 与 VFS 路径在发送时由引用块注入，这里只带标题/描述摘录展示
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

  /// 重命名分类对话框
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

  /// 删除分类确认弹窗（依据用户需求：同时删除分类下的待办事项）
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
    final result = await showTimePickerDialog(
      context: context,
      initialTime: todo.reminderTime != null ? _parseReminderTime(todo.reminderTime!) : null,
      title: '设置提醒时间',
    );
    if (result == null) return;
    final formatted = ReminderUtils.format(result);
    ref.read(todoListProvider.notifier).setReminder(todo.id, formatted);
  }

  /// 解析提醒时间；兼容 `MM-DD HH:mm`、`YYYY-MM-DD HH:mm` 等写法。
  DateTime? _parseReminderTime(String timeStr) => ReminderUtils.parse(timeStr);

  Future<void> _confirmDelete(Todo todo) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除「${todo.title.isEmpty ? '新待办' : todo.title}」吗？'),
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
                // 计算未完成待办数（包含未分类兜底）
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
                          : colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(AppRadius.large),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: colorScheme.shadow.withValues(alpha: 0.08),
                                blurRadius: 4,
                                offset: const Offset(0, 2),
                              ),
                            ]
                          : null,
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

class _TodoItem extends StatefulWidget {
  final Todo todo;
  final int index;
  final bool autoFocus;
  final VoidCallback? onEditingComplete;
  final VoidCallback onToggleComplete;
  final ValueChanged<String> onTitleChanged;
  final VoidCallback? onDeleteEmpty;
  final void Function(GlobalKey key) onShowMenu;
  final VoidCallback onSetReminder;

  const _TodoItem({
    super.key,
    required this.todo,
    required this.index,
    this.autoFocus = false,
    this.onEditingComplete,
    required this.onToggleComplete,
    required this.onTitleChanged,
    this.onDeleteEmpty,
    required this.onShowMenu,
    required this.onSetReminder,
  });

  @override
  State<_TodoItem> createState() => _TodoItemState();
}

class _TodoItemState extends State<_TodoItem> with SingleTickerProviderStateMixin {
  late TextEditingController _titleController;
  late FocusNode _focusNode;
  final _menuKey = GlobalKey();

  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _heightFactor;
  late Animation<double> _opacityAnimation;

  bool _localCompleted = false;
  bool _isEditing = false; // 是否处于编辑状态

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.todo.title);
    _focusNode = FocusNode(skipTraversal: true);
    _focusNode.addListener(_onFocusChange);

    _animController = AnimationController(
      vsync: this,
      duration: AppDurations.medium,
    );

    _scaleAnimation = CurvedAnimation(
      parent: _animController,
      curve: Curves.easeOutBack, // Playful bounce on entry
      reverseCurve: Curves.easeIn, // Smooth exit
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

    // Play entry animation
    _animController.forward();

    if (widget.autoFocus) {
      _isEditing = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_focusNode.canRequestFocus) {
          _focusNode.requestFocus();
        }
      });
    }
  }

  void _onFocusChange() {
    if (!_focusNode.hasFocus) {
      _handleBlur();
      if (mounted) {
        setState(() {
          _isEditing = false;
        });
      }
    }
  }

  @override
  void didUpdateWidget(covariant _TodoItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.todo.title != widget.todo.title &&
        widget.todo.title != _titleController.text.trim()) {
      _titleController.text = widget.todo.title;
    }
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
    _focusNode.removeListener(_onFocusChange);
    _titleController.dispose();
    _focusNode.dispose();
    _animController.dispose();
    super.dispose();
  }

  void _handleBlur() {
    final text = _titleController.text;
    if (text.trim().isNotEmpty) {
      if (text.trim() != widget.todo.title) {
        widget.onTitleChanged(text);
      }
    } else {
      if (widget.todo.title.trim().isEmpty) {
        widget.onDeleteEmpty?.call();
      } else {
        _titleController.text = widget.todo.title;
      }
    }
    widget.onEditingComplete?.call();
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
            margin: const EdgeInsets.only(bottom: 6),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.shadow.withValues(alpha: 0.02),
                  blurRadius: 10,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
              child: Row(
                children: [
                  ReorderableDragStartListener(
                    index: widget.index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                  GestureDetector(
                    onTap: _handleToggleComplete,
                    behavior: HitTestBehavior.opaque,
                    child: AnimatedContainer(
                      duration: AppDurations.medium,
                      curve: Curves.easeInOut,
                      width: 22,
                      height: 22,
                      margin: const EdgeInsets.symmetric(horizontal: 4),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDone
                              ? colorScheme.primary
                              : colorScheme.outline.withValues(alpha: 0.5),
                          width: 2,
                        ),
                        color: isDone ? colorScheme.primary : Colors.transparent,
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
                              child: Icon(Icons.check, size: 16, color: colorScheme.onPrimary),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isDone && _isEditing)
                          TextField(
                            controller: _titleController,
                            focusNode: _focusNode,
                            onSubmitted: (_) {
                              _focusNode.unfocus();
                            },
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14.5,
                              color: colorScheme.onSurface,
                            ),
                            decoration: const InputDecoration(
                              isDense: true,
                              contentPadding: EdgeInsets.zero,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              errorBorder: InputBorder.none,
                              disabledBorder: InputBorder.none,
                              filled: false,
                            ),
                          )
                        else
                          GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            // 长按标题弹出操作菜单（与 more_vert 共用，含「给小Q」）
                            onLongPress: () => widget.onShowMenu(_menuKey),
                            onTap: () {
                              if (isDone) return;
                              setState(() {
                                _isEditing = true;
                              });
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (_focusNode.canRequestFocus) {
                                  _focusNode.requestFocus();
                                }
                              });
                            },
                            child: Container(
                              width: double.infinity,
                              color: Colors.transparent,
                              child: AnimatedDefaultTextStyle(
                                duration: AppDurations.medium,
                                curve: Curves.easeInOut,
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14.5,
                                  decoration: isDone ? TextDecoration.lineThrough : TextDecoration.none,
                                  color: isDone ? theme.disabledColor : colorScheme.onSurface,
                                ),
                                child: Text(
                                  _titleController.text.isEmpty ? ' ' : _titleController.text,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ),
                          ),
                        // 底部状态信息：重复周期、提醒时间、描述备注
                        if (todo.isRecurring || todo.reminderTime != null || todo.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Row(
                              children: [
                                if (todo.isRecurring) ...[
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                    margin: const EdgeInsets.only(right: 6),
                                    decoration: BoxDecoration(
                                      color: colorScheme.primary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(Icons.repeat, size: 10, color: colorScheme.primary),
                                        const SizedBox(width: 2),
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
                                  Icon(Icons.alarm, size: 11, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
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
                          ),
                      ],
                    ),
                  ),
                  if (todo.priority == 'important')
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 8),
                      decoration: BoxDecoration(
                        color: colorScheme.primary,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: colorScheme.primary.withValues(alpha: 0.4),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                  IconButton(
                    key: _menuKey,
                    icon: Icon(Icons.more_vert, size: 18, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                    onPressed: () => widget.onShowMenu(_menuKey),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
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

class _HistoryDrawer extends ConsumerWidget {
  const _HistoryDrawer();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final completedAsync = ref.watch(completedTodoListProvider);
    final foldersAsync = ref.watch(todoFolderListProvider);

    return Drawer(
      width: MediaQuery.of(context).size.width * 0.85,
      backgroundColor: theme.colorScheme.surface,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(
                    '已完成历史',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: completedAsync.when(
              data: (completedTodos) {
                final validTodos = completedTodos.where((t) => t.title.trim().isNotEmpty).toList();
                if (validTodos.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline, size: 48, color: theme.disabledColor.withValues(alpha: 0.3)),
                        const SizedBox(height: 8),
                        Text('暂无已完成记录', style: TextStyle(fontSize: 12, color: theme.disabledColor)),
                      ],
                    ),
                  );
                }

                final folders = foldersAsync.valueOrNull ?? [];
                final folderMap = {for (final f in folders) f.id: f.name};

                // 按分类分组显示已完成事项
                final items = <Object>[];
                // 1. 已分类的
                for (final folder in folders) {
                  final groupTodos = validTodos.where((t) => t.folderId == folder.id).toList();
                  if (groupTodos.isNotEmpty) {
                    items.add(folder.name);
                    items.addAll(groupTodos);
                    items.add('spacer');
                  }
                }
                // 2. 无明确分类的
                final otherTodos = validTodos.where((t) => !folderMap.containsKey(t.folderId)).toList();
                if (otherTodos.isNotEmpty) {
                  items.add('其他已完成');
                  items.addAll(otherTodos);
                }

                return ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  itemCount: items.length,
                  itemBuilder: (context, index) {
                    final item = items[index];
                    if (item is Todo) {
                      return _HistoryTodoItem(todo: item);
                    }
                    if (item == 'spacer') {
                      return const SizedBox(height: 12);
                    }
                    // 标题栏
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 8, left: 4, top: 4),
                      child: Row(
                        children: [
                          Icon(Icons.folder_outlined, size: 13, color: theme.colorScheme.onSurfaceVariant),
                          const SizedBox(width: 6),
                          Text(
                            item as String,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.bold,
                              color: theme.colorScheme.outline,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败: $e')),
            ),
          ),
        ],
      ),
    );
  }
}

class _HistoryTodoItem extends ConsumerWidget {
  final Todo todo;

  const _HistoryTodoItem({required this.todo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
        boxShadow: [
          BoxShadow(
            color: theme.colorScheme.shadow.withValues(alpha: 0.02),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3)),
            ),
            child: Icon(Icons.check, size: 14, color: theme.colorScheme.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  todo.title.isEmpty ? '新待办' : todo.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.lineThrough,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                if (todo.isRecurring)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      '已自动生成下期「${todo.repeatRuleLabel}」待办',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: theme.colorScheme.primary.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.restore, size: 14, color: theme.colorScheme.onSurfaceVariant),
            onPressed: () => ref.read(todoListProvider.notifier).restoreTodo(todo.id),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            tooltip: '还原待办',
          ),
          IconButton(
            icon: Icon(Icons.delete_outline, size: 14, color: theme.colorScheme.error),
            onPressed: () => _confirmPermanentDelete(context, ref),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            tooltip: '永久删除',
          ),
        ],
      ),
    );
  }

  Future<void> _confirmPermanentDelete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('彻底删除'),
        content: const Text('彻底删除后将无法恢复，确定要永久删除这条待办吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('彻底删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(todoListProvider.notifier).permanentDelete(todo.id);
    }
  }
}
