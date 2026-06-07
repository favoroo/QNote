import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';

class TodoPage extends ConsumerStatefulWidget {
  const TodoPage({super.key});

  @override
  ConsumerState<TodoPage> createState() => _TodoPageState();
}

class _TodoPageState extends ConsumerState<TodoPage> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  String? _focusedTodoId;
  late PageController _pageController;

  @override
  void initState() {
    super.initState();
    final initialIsLongTerm = ref.read(isLongTermFilterProvider);
    _pageController = PageController(initialPage: initialIsLongTerm ? 1 : 0);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isLongTerm = ref.watch(isLongTermFilterProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: colorScheme.surface,
      endDrawer: const _HistoryDrawer(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _addNewTodo(isLongTerm),
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
            icon: Icon(Icons.history_rounded, color: colorScheme.onSurfaceVariant),
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
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: _SegmentedControl(
                isLongTerm: isLongTerm,
                onChanged: (value) {
                  FocusScope.of(context).unfocus();
                  setState(() {
                    _focusedTodoId = null;
                  });
                  ref.read(isLongTermFilterProvider.notifier).state = value;
                  _pageController.animateToPage(
                    value ? 1 : 0,
                    duration: AppDurations.medium,
                    curve: Curves.easeInOut,
                  );
                },
              ),
            ),
            Expanded(
              child: PageView(
                controller: _pageController,
                onPageChanged: (index) {
                  FocusScope.of(context).unfocus();
                  setState(() {
                    _focusedTodoId = null;
                  });
                  ref.read(isLongTermFilterProvider.notifier).state = (index == 1);
                },
                children: [
                  _buildTodoList(context, false),
                  _buildTodoList(context, true),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTodoList(BuildContext context, bool isLongTerm) {
    final todosAsync = ref.watch(todoListProvider);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return todosAsync.when(
      data: (allTodos) {
        final filteredTodos = allTodos
            .where((t) => t.isLongTerm == isLongTerm && !t.isCompleted)
            .toList();

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
        return ReorderableListView.builder(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          itemCount: filteredTodos.length,
          onReorder: (oldIndex, newIndex) {
            if (newIndex > oldIndex) newIndex -= 1;
            final list = List<Todo>.from(filteredTodos);
            final item = list.removeAt(oldIndex);
            list.insert(newIndex, item);
            final allTodosList = todosAsync.valueOrNull ?? [];
            final otherTodos =
                allTodosList.where((t) => t.isCompleted || t.isLongTerm != isLongTerm).toList();
            ref.read(todoListProvider.notifier).reorderTodos([...list, ...otherTodos]);
          },
          itemBuilder: (context, index) {
            final todo = filteredTodos[index];
            return _TodoItem(
              key: ValueKey(todo.id),
              todo: todo,
              index: index,
              autoFocus: todo.id == _focusedTodoId,
              onFocused: () {
                setState(() {
                  _focusedTodoId = null;
                });
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
              onShowMenu: (globalKey) {
                _showActionMenu(context, todo, globalKey);
              },
              onSetReminder: () => _setReminder(todo),
            );
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('加载失败: $e')),
    );
  }

  void _addNewTodo(bool isLongTerm) {
    ref.read(todoListProvider.notifier).addTodo(
          title: '',
          isLongTerm: isLongTerm,
        ).then((todo) {
      setState(() {
        _focusedTodoId = todo.id;
      });
    });
  }

  void _showActionMenu(BuildContext context, Todo todo, GlobalKey key) {
    final items = <ActionMenuItem>[
      ActionMenuItem(
        icon: todo.priority == 'important' ? Icons.flag_outlined : Icons.flag,
        label: todo.priority == 'important' ? '设为普通' : '设为重要',
        onTap: () => ref.read(todoListProvider.notifier).togglePriority(todo.id),
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
      ActionMenuItem(
        icon: Icons.swap_horiz,
        label: todo.isLongTerm ? '移动到今日' : '移动到长期',
        onTap: () {
          if (todo.isLongTerm) {
            ref.read(todoListProvider.notifier).moveToToday(todo.id);
          } else {
            ref.read(todoListProvider.notifier).moveToLongTerm(todo.id);
          }
        },
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

  Future<void> _setReminder(Todo todo) async {
    final result = await showTimePickerDialog(
      context: context,
      initialTime: todo.reminderTime != null ? _parseReminderTime(todo.reminderTime!) : null,
      title: '设置提醒时间',
    );
    if (result == null) return;
    final formatted =
        '${result.month.toString().padLeft(2, '0')}-${result.day.toString().padLeft(2, '0')} ${result.hour.toString().padLeft(2, '0')}:${result.minute.toString().padLeft(2, '0')}';
    ref.read(todoListProvider.notifier).setReminder(todo.id, formatted);
  }

  DateTime? _parseReminderTime(String timeStr) {
    try {
      // Expecting MM-dd HH:mm
      final parts = timeStr.split(' ');
      final dateParts = parts[0].split('-');
      final timeParts = parts[1].split(':');
      final now = DateTime.now();
      return DateTime(
        now.year,
        int.parse(dateParts[0]),
        int.parse(dateParts[1]),
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
      );
    } catch (_) {
      return null;
    }
  }

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

class _SegmentedControl extends StatelessWidget {
  final bool isLongTerm;
  final ValueChanged<bool> onChanged;

  const _SegmentedControl({required this.isLongTerm, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return Container(
      height: 44,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(AppRadius.large),
      ),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(false),
              child: AnimatedContainer(
                duration: AppDurations.normal,
                curve: Curves.easeInOut,
                decoration: BoxDecoration(
                  color: !isLongTerm ? colorScheme.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.large),
                  boxShadow: !isLongTerm
                      ? [
                          BoxShadow(
                            color: colorScheme.shadow.withValues(alpha: 0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          )
                        ]
                      : null,
                ),
                child: Center(
                  child: Text(
                    '今日',
                    style: TextStyle(
                      fontWeight: !isLongTerm ? FontWeight.bold : FontWeight.w600,
                      fontSize: 13.5,
                      color: !isLongTerm
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () => onChanged(true),
              child: AnimatedContainer(
                duration: AppDurations.normal,
                curve: Curves.easeInOut,
                decoration: BoxDecoration(
                  color: isLongTerm ? colorScheme.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.large),
                  boxShadow: isLongTerm
                      ? [
                          BoxShadow(
                            color: colorScheme.shadow.withValues(alpha: 0.05),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          )
                        ]
                      : null,
                ),
                child: Center(
                  child: Text(
                    '长期',
                    style: TextStyle(
                      fontWeight: isLongTerm ? FontWeight.bold : FontWeight.w600,
                      fontSize: 13.5,
                      color: isLongTerm
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
            ),
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
  final VoidCallback? onFocused;
  final VoidCallback onToggleComplete;
  final ValueChanged<String> onTitleChanged;
  final void Function(GlobalKey key) onShowMenu;
  final VoidCallback onSetReminder;

  const _TodoItem({
    super.key,
    required this.todo,
    required this.index,
    this.autoFocus = false,
    this.onFocused,
    required this.onToggleComplete,
    required this.onTitleChanged,
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
        widget.onFocused?.call();
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
    if (text.trim().isNotEmpty && text.trim() != widget.todo.title) {
      widget.onTitleChanged(text);
    } else if (text.trim() != widget.todo.title) {
      _titleController.text = widget.todo.title;
    }
  }

  void _handleToggleComplete() {
    HapticFeedback.mediumImpact();
    if (widget.todo.isCompleted) {
      // If restoring, just toggle immediately
      widget.onToggleComplete();
      return;
    }

    setState(() {
      _localCompleted = true;
    });

    // Run exit collapse animation
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
      axisAlignment: -1.0,
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
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  ReorderableDragStartListener(
                    index: widget.index,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.drag_indicator,
                          size: 18, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
                    ),
                  ),
                  GestureDetector(
                    onTap: _handleToggleComplete,
                    child: AnimatedContainer(
                      duration: AppDurations.normal,
                      curve: Curves.easeInOut,
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: isDone ? colorScheme.primary : colorScheme.outlineVariant,
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
                        if (todo.reminderTime != null || todo.description.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              todo.reminderTime ?? todo.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                                fontWeight: FontWeight.w500,
                                fontSize: 11.5,
                              ),
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

    return Drawer(
      width: MediaQuery.of(context).size.width * 0.85,
      child: Column(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Row(
                children: [
                  Icon(Icons.history, color: theme.colorScheme.primary, size: 24),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '已完成历史',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
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
                if (completedTodos.isEmpty) {
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

                final todayCompleted = completedTodos.where((t) => !t.isLongTerm).toList();
                final longtermCompleted = completedTodos.where((t) => t.isLongTerm).toList();

                return ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  children: [
                    if (todayCompleted.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10, left: 4, top: 8),
                        child: Row(
                          children: [
                            Icon(Icons.calendar_today, size: 12, color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                             Text(
                              '今日已完成',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...todayCompleted.map((todo) => _HistoryTodoItem(todo: todo)),
                      const SizedBox(height: 12),
                    ],
                    if (longtermCompleted.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6, left: 4),
                        child: Row(
                          children: [
                            Icon(Icons.access_time, size: 12, color: theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              '长期已完成',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurfaceVariant,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ...longtermCompleted.map((todo) => _HistoryTodoItem(todo: todo)),
                    ],
                  ],
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
            child: Text(
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
        title: const Text('确认永久删除'),
        content: Text('确定要永久删除「${todo.title.isEmpty ? '新待办' : todo.title}」吗？此操作不可恢复。'),
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
      ref.read(todoListProvider.notifier).permanentDelete(todo.id);
    }
  }
}
