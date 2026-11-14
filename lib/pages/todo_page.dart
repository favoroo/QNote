import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/core/theme/app_radius.dart';
import 'package:qnote_flutter/core/theme/app_theme.dart';
import 'package:qnote_flutter/core/utils/reorder_gesture.dart';
import 'package:qnote_flutter/core/utils/reminder_utils.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/providers/todo_folder_provider.dart';
import 'package:qnote_flutter/providers/todo_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/common/app_checkbox.dart';
import 'package:qnote_flutter/widgets/common/pressable_scale.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/app_error_state.dart';
import 'package:qnote_flutter/widgets/records_section_switcher.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';

part 'todo_page_widgets.dart';
part 'todo_page_sheets.dart';

/// 已完成待办折叠状态本地持久化键
const String _kTodoCompletedCollapsedKey = 'todo_completed_collapsed';

/// 按分类聚合后的待办视图。
///
/// 页面 build、分类标签栏角标与 PageView 的每一页都依赖同一份分组结果，
/// 集中计算一次即可避免「分类数 × 待办数」的重复扫描。
class _TodoGrouping {
  const _TodoGrouping({
    required this.activeTodosByFolder,
    required this.completedTodosByFolder,
    required this.pendingCounts,
    required this.allIdsByFolder,
    required this.orphanTodayIds,
  });

  /// 与 folders 下标一一对应的未完成待办。
  final List<List<Todo>> activeTodosByFolder;

  /// 与 folders 下标一一对应的已完成待办。
  final List<List<Todo>> completedTodosByFolder;

  /// 与 folders 下标一一对应的未完成数量（分类 Chip 角标）。
  final List<int> pendingCounts;

  /// 与 folders 下标一一对应的「全选」id 集合（包含已完成）。
  final List<Set<String>> allIdsByFolder;

  /// 分类列表为空时，「今日」兜底规则命中的待办 id。
  final Set<String> orphanTodayIds;
}

/// 待办是否归属指定分类。
///
/// 条件与原页面 where 保持逐字对应：有 folderId 的只认 id，folderId 为空的
/// 继续走「长期 / 今日」兜底，因此同一条待办可能同时命中多个分类。
bool _todoBelongsToFolder(Todo todo, Folder folder, int folderIndex) {
  if (todo.folderId == folder.id) {
    return true;
  }
  if (todo.folderId != null && todo.folderId!.isNotEmpty) {
    return false;
  }
  if (folder.id == 'todo_default_longterm' || folder.name == '长期') {
    return todo.isLongTerm;
  }
  if (folder.id == 'todo_default_today' || folderIndex == 0) {
    return !todo.isLongTerm;
  }
  return false;
}

/// 一次性把待办按分类拆成未完成 / 已完成 / 全选 id。
///
/// 纯函数：只读取入参，不依赖 BuildContext 或页面状态，缓存失效时可安全重算。
_TodoGrouping _buildTodoGrouping(List<Todo> todos, List<Folder> folders) {
  final activeTodosByFolder = <List<Todo>>[];
  final completedTodosByFolder = <List<Todo>>[];
  final pendingCounts = <int>[];
  final allIdsByFolder = <Set<String>>[];

  for (var index = 0; index < folders.length; index++) {
    final folder = folders[index];
    final active = <Todo>[];
    final completed = <Todo>[];
    final allIds = <String>{};
    for (final todo in todos) {
      if (todo.title.trim().isEmpty || !_todoBelongsToFolder(todo, folder, index)) {
        continue;
      }
      allIds.add(todo.id);
      if (todo.isCompleted) {
        completed.add(todo);
      } else {
        active.add(todo);
      }
    }
    activeTodosByFolder.add(active);
    completedTodosByFolder.add(completed);
    pendingCounts.add(active.length);
    allIdsByFolder.add(allIds);
  }

  // 没有分类时页面仍会计算「全选」集合：原逻辑在 safeIndex == 0 时把
  // 无分类且非长期的待办视作今日待办，这里保留同样的兜底结果。
  final orphanTodayIds = <String>{};
  if (folders.isEmpty) {
    for (final todo in todos) {
      if (todo.title.trim().isEmpty) {
        continue;
      }
      if (todo.folderId != null && todo.folderId!.isNotEmpty) {
        continue;
      }
      if (!todo.isLongTerm) {
        orphanTodayIds.add(todo.id);
      }
    }
  }

  return _TodoGrouping(
    activeTodosByFolder: activeTodosByFolder,
    completedTodosByFolder: completedTodosByFolder,
    pendingCounts: pendingCounts,
    allIdsByFolder: allIdsByFolder,
    orphanTodayIds: orphanTodayIds,
  );
}

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

  /// 折叠时把已完成内容多保留一个动画周期，让 AnimatedCrossFade 能同时
  /// 收敛高度与透明度；动画结束后再真正移除，避免长列表常驻构建。
  bool _keepCompletedItems = false;
  Timer? _completedCollapseTimer;

  /// 用户点击分类标签后，PageView 正在按目标页播放滑动动画。
  /// 此期间不要用 build 里的同步逻辑 jumpToPage，否则会把动画直接打断成瞬跳。
  bool _isSwitchingFolder = false;

  /// 连续点击分类标签时只让最后一次动画负责清除 [_isSwitchingFolder]。
  int _folderSwitchSeq = 0;

  // 批量选择与批量删除状态
  bool _isSelectionMode = false;
  final Set<String> _selectedTodoIds = {};

  /// 正在播放收起退场的待办 id：动画结束后才真正提交删除
  final Set<String> _deletingTodoIds = <String>{};
  bool _isConfirming = false;
  Timer? _confirmTimer;

  // 底部添加/编辑弹窗打开守卫：小组件「+」触发时若弹窗已在，避免叠加弹出第二个
  bool _isTodoSheetOpen = false;

  // 排序拖拽状态：长按拾起后「原地松手」仍要弹操作菜单，所以要记住起拖下标，
  // 并用原始指针轨迹判断手指到底有没有移动过（拖过再拖回原位不算原地松手）。
  int? _reorderStartIndex;
  Offset? _pointerDownPosition;
  bool _pointerMoved = false;

  /// 待办分组缓存：provider 的所有写操作都会换新 List，因此引用未变即可认为
  /// 内容未变；分类名与顺序也参与分组规则，所以待办、分类两个引用都要比对。
  _TodoGrouping? _todoGroupingCache;
  List<Todo>? _todoGroupingTodos;
  List<Folder>? _todoGroupingFolders;

  /// 取得与当前输入对应的分组结果，仅在待办或分类列表换新对象时重算。
  _TodoGrouping _todoGroupingFor(List<Todo> todos, List<Folder> folders) {
    final cached = _todoGroupingCache;
    if (cached != null && identical(todos, _todoGroupingTodos) && identical(folders, _todoGroupingFolders)) {
      return cached;
    }
    final grouping = _buildTodoGrouping(todos, folders);
    _todoGroupingCache = grouping;
    _todoGroupingTodos = todos;
    _todoGroupingFolders = folders;
    return grouping;
  }

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
        _keepCompletedItems = !saved;
      });
    }
  }

  void _toggleCompletedCollapsed() {
    final nextCollapsed = !_isCompletedCollapsed;
    _completedCollapseTimer?.cancel();

    setState(() {
      _isCompletedCollapsed = nextCollapsed;
      if (!nextCollapsed) {
        _keepCompletedItems = true;
      }
    });

    if (nextCollapsed) {
      final duration = AppMotion.duration(context, AppDurations.normal);
      if (duration == Duration.zero) {
        setState(() => _keepCompletedItems = false);
      } else {
        // 比交叉淡化多留 50ms，确保动画收尾后再移除长列表。
        _completedCollapseTimer = Timer(duration + const Duration(milliseconds: 50), () {
          if (!mounted || !_isCompletedCollapsed) return;
          setState(() => _keepCompletedItems = false);
        });
      }
    }

    SharedPreferences.getInstance().then((prefs) {
      prefs.setBool(_kTodoCompletedCollapsedKey, _isCompletedCollapsed);
    });
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    _completedCollapseTimer?.cancel();
    _pageController.dispose();
    for (final controller in _scrollControllers.values) {
      controller.dispose();
    }
    _scrollControllers.clear();
    super.dispose();
  }

  void _enterSelectionMode([String? initialTodoId]) {
    HapticFeedback.mediumImpact();
    setState(() {
      _isSelectionMode = true;
      _selectedTodoIds.clear();
      if (initialTodoId != null) {
        _selectedTodoIds.add(initialTodoId);
      }
      _isConfirming = false;
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _isSelectionMode = false;
      _selectedTodoIds.clear();
      _isConfirming = false;
    });
    _confirmTimer?.cancel();
  }

  void _toggleSelectTodo(String id) {
    setState(() {
      if (_selectedTodoIds.contains(id)) {
        _selectedTodoIds.remove(id);
      } else {
        _selectedTodoIds.add(id);
      }
      _isConfirming = false;
    });
    _confirmTimer?.cancel();
  }

  Future<void> _handleBatchDelete() async {
    if (_selectedTodoIds.isEmpty) return;

    if (!_isConfirming) {
      setState(() {
        _isConfirming = true;
      });
      _confirmTimer?.cancel();
      _confirmTimer = Timer(const Duration(seconds: 3), () {
        if (mounted) {
          setState(() {
            _isConfirming = false;
          });
        }
      });
      return;
    }

    final count = _selectedTodoIds.length;
    final idsToDelete = _selectedTodoIds.toList();
    HapticFeedback.heavyImpact();
    await ref.read(todoListProvider.notifier).deleteTodos(idsToDelete);

    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已删除 $count 项'), duration: const Duration(seconds: 2)));
      _exitSelectionMode();
    }
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

    final folders = foldersAsync.valueOrNull ?? const <Folder>[];
    final activeFolderId = (selectedFolderId != null && folders.any((f) => f.id == selectedFolderId))
        ? selectedFolderId
        : (folders.isNotEmpty ? folders.first.id : null);
    final activeFolderIndex = folders.indexWhere((f) => f.id == activeFolderId);
    final safeIndex = activeFolderIndex >= 0 ? activeFolderIndex : 0;

    final allTodos = todosAsync.valueOrNull ?? const <Todo>[];
    // 分类分组、完成态拆分与角标计数只算一次，供标签栏和 PageView 各页复用。
    final grouping = _todoGroupingFor(allTodos, folders);
    final currentFolderTodoIds = folders.isEmpty ? grouping.orphanTodayIds : grouping.allIdsByFolder[safeIndex];

    final isCurrentFolderAllSelected =
        currentFolderTodoIds.isNotEmpty && currentFolderTodoIds.every((id) => _selectedTodoIds.contains(id));

    return PopScope(
      canPop: !_isSelectionMode,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isSelectionMode) {
          _exitSelectionMode();
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        backgroundColor: colorScheme.surface,
        // 与笔记页保持一致：选择态下加号同样淡出/缩放退场，而不是瞬间消失，
        // 切换批量选择时右下角不出现「一下子没了」的突兀感。
        floatingActionButton: AppMotion.switcher(
          context: context,
          baseDuration: AppDurations.fast,
          alignment: Alignment.bottomRight,
          child: _isSelectionMode
              ? const SizedBox.shrink(key: ValueKey('todo_fab_hidden'))
              : FloatingActionButton(
                  key: const ValueKey('todo_fab'),
                  // 显式 heroTag：与笔记页策略一致，避免同屏分支常驻时的默认 tag 冲突
                  heroTag: 'add_todo_fab',
                  onPressed: () {
                    final currentFolderId = (selectedFolderId != null && folders.any((f) => f.id == selectedFolderId))
                        ? selectedFolderId
                        : (folders.isNotEmpty ? folders.first.id : null);
                    _addNewTodo(currentFolderId);
                  },
                  backgroundColor: colorScheme.primary,
                  foregroundColor: colorScheme.onPrimary,
                  elevation: 2,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.add, size: 28),
                ),
        ),
        appBar: AppBar(
          centerTitle: true,
          backgroundColor: colorScheme.surface,
          elevation: 0,
          leading: AppMotion.switcher(
            context: context,
            baseDuration: AppDurations.fast,
            child: KeyedSubtree(
              key: ValueKey(_isSelectionMode ? 'select_leading' : 'menu_leading'),
              child: _isSelectionMode
                  ? IconButton(icon: const Icon(Icons.close), tooltip: '退出选择', onPressed: _exitSelectionMode)
                  : IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () {
                        FocusScope.of(context).unfocus();
                        rootScaffoldKey.currentState?.openDrawer();
                      },
                    ),
            ),
          ),
          title: AppMotion.switcher(
            context: context,
            baseDuration: AppDurations.fast,
            child: KeyedSubtree(
              key: ValueKey(_isSelectionMode ? 'select_title' : 'section_title'),
              // 与笔记页统一文案：避免「已选 / 已选择」宽度不同导致居中标题两端来回移动
              child: _isSelectionMode
                  ? Text('已选 ${_selectedTodoIds.length} 项')
                  : const RecordsSectionSwitcher(active: RecordsSection.todo),
            ),
          ),
          actions: [
            AppMotion.switcher(
              context: context,
              baseDuration: AppDurations.fast,
              child: KeyedSubtree(
                key: ValueKey(_isSelectionMode ? 'select_actions' : 'normal_actions'),
                child: _isSelectionMode
                    ? TextButton(
                        onPressed: () {
                          setState(() {
                            if (isCurrentFolderAllSelected) {
                              _selectedTodoIds.removeAll(currentFolderTodoIds);
                            } else {
                              _selectedTodoIds.addAll(currentFolderTodoIds);
                            }
                            _isConfirming = false;
                          });
                          _confirmTimer?.cancel();
                        },
                        child: Text(
                          isCurrentFolderAllSelected ? '取消全选' : '全选',
                          style: TextStyle(color: Theme.of(context).accentInk, fontWeight: FontWeight.bold),
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: Icon(Icons.checklist_outlined, color: colorScheme.onSurfaceVariant),
                            tooltip: '批量管理',
                            onPressed: () => _enterSelectionMode(),
                          ),
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
              ),
            ),
          ],
        ),
        bottomNavigationBar: AppCollapsible(
          // 统一幕布式收放，保留退出态条内容，避免收起瞬间变空白矩形空缩
          expanded: _isSelectionMode,
          rise: 0,
          child: Container(
            key: const ValueKey('todo_batch_bar'),
            decoration: BoxDecoration(
              color: colorScheme.surface,
              border: Border(top: BorderSide(color: colorScheme.outlineVariant.withValues(alpha: 0.15))),
              boxShadow: [
                BoxShadow(
                  color: colorScheme.shadow.withValues(alpha: 0.05),
                  offset: const Offset(0, -4),
                  blurRadius: 20,
                ),
              ],
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      '已选 ${_selectedTodoIds.length} 项',
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    FilledButton(
                      onPressed: _selectedTodoIds.isEmpty ? null : _handleBatchDelete,
                      style: FilledButton.styleFrom(
                        backgroundColor: colorScheme.error,
                        foregroundColor: colorScheme.onError,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.delete_outline, size: 16),
                          const SizedBox(width: 6),
                          Text(_isConfirming ? '再点确认' : '删除', style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
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

              final activeFolderId = (selectedFolderId != null && folders.any((f) => f.id == selectedFolderId))
                  ? selectedFolderId
                  : folders.first.id;

              final currentIndex = folders.indexWhere((f) => f.id == activeFolderId);
              final safeIndex = currentIndex >= 0 ? currentIndex : 0;

              // 监听外部切换或保持 pageController 同步
              if (!_isSwitchingFolder && _pageController.hasClients && _pageController.page?.round() != safeIndex) {
                _pageController.jumpToPage(safeIndex);
              }

              return Column(
                children: [
                  // 动态横向分类标签栏
                  _TodoFolderTabBar(
                    folders: folders,
                    selectedFolderId: activeFolderId,
                    pendingCounts: grouping.pendingCounts,
                    onSelect: (folderId) {
                      FocusScope.of(context).unfocus();
                      final targetIndex = folders.indexWhere((f) => f.id == folderId);
                      if (targetIndex >= 0 && _pageController.hasClients) {
                        // 先标记为「动画切换中」，provider 更新触发的 rebuild
                        // 就不会在动画起步前把页面直接 jump 到目标页。
                        _isSwitchingFolder = true;
                        final switchSeq = ++_folderSwitchSeq;
                        ref.read(selectedTodoFolderIdProvider.notifier).state = folderId;
                        AppMotion.animateToPage(_pageController, targetIndex, context: context).whenComplete(() {
                          if (switchSeq == _folderSwitchSeq) {
                            _isSwitchingFolder = false;
                          }
                        });
                      } else {
                        ref.read(selectedTodoFolderIdProvider.notifier).state = folderId;
                      }
                    },
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
                        // 直接复用按列表引用缓存的分组结果，不再让每一页各自扫描 allTodos。
                        final activeTodos = grouping.activeTodosByFolder[index];
                        final completedTodos = grouping.completedTodosByFolder[index];
                        return _buildTodoList(context, folder.id, todosAsync, activeTodos, completedTodos);
                      },
                    ),
                  ),
                ],
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) =>
                AppErrorState(error: e, action: '加载分类失败', onRetry: () => ref.invalidate(todoFolderListProvider)),
          ),
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

    final stateKey = todosAsync.isLoading
        ? 'loading'
        : todosAsync.hasError
        ? 'error'
        : (activeTodos.isEmpty && completedTodos.isEmpty ? 'empty' : 'list');
    // 加载 / 空态 / 列表之间交叉淡化，删除最后一条时不再整页硬切
    return AppMotion.switcher(
      context: context,
      baseDuration: AppDurations.normal,
      child: KeyedSubtree(
        key: ValueKey(stateKey),
        child: todosAsync.when(
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
                      '暂无待办',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              );
            }

            final scrollController = _getScrollController(folderId);

            return Listener(
              onPointerDown: _handleListPointerDown,
              onPointerMove: _handleListPointerMove,
              child: ReorderableListView.builder(
                scrollController: scrollController,
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 88),
                // 关掉框架默认手柄：桌面/Web 分支会额外画一个 Icons.drag_handle 叠在
                // 行尾（与本页自绘手柄重复），移动端分支则把整行包进
                // ReorderableDelayedDragStartListener，会与长按弹菜单的识别器在
                // 500ms 处正面冲突。排序改由 _TodoItem 自行接管（见该组件）。
                buildDefaultDragHandles: false,
                itemCount: activeTodos.length,
                onReorderStart: (index) {
                  _reorderStartIndex = index;
                  // 拾起反馈：拖拽浮层由 ReorderableListView 负责，这里补触感
                  HapticFeedback.mediumImpact();
                },
                onReorderEnd: (index) {
                  final startIndex = _reorderStartIndex;
                  final moved = _pointerMoved;
                  final anchor = _pointerDownPosition;
                  _reorderStartIndex = null;
                  _pointerMoved = false;
                  _pointerDownPosition = null;
                  // 长按拾起后原地松手 → 按「长按手势」弹操作菜单（原有长按菜单不变）。
                  // 桌面/Web 仍由行尾手柄负责拖拽、卡片自身长按负责菜单，不走这条路径。
                  if (useDragHandleFor(Theme.of(context).platform)) return;
                  if (startIndex == null) return;
                  final isLongPress = isLongPressRelease(pointerMoved: moved, landedElsewhere: index != startIndex);
                  if (!isLongPress) return;
                  if (startIndex < 0 || startIndex >= activeTodos.length) return;
                  _showActionMenu(context, activeTodos[startIndex], anchor: anchor);
                },
                onReorderItem: (oldIndex, newIndex) {
                  if (oldIndex < 0 || oldIndex >= activeTodos.length) return;
                  if (newIndex < 0 || newIndex > activeTodos.length) return;
                  final list = List<Todo>.from(activeTodos);
                  final item = list.removeAt(oldIndex);
                  list.insert(newIndex, item);
                  final allTodosList = todosAsync.valueOrNull ?? [];
                  final otherTodos = allTodosList.where((t) => t.isCompleted || t.folderId != folderId).toList();
                  ref.read(todoListProvider.notifier).reorderTodos([...list, ...otherTodos]);
                },
                itemBuilder: (context, index) {
                  final todo = activeTodos[index];
                  return RepaintBoundary(
                    key: ValueKey(todo.id),
                    child: AppCollapsible(
                      expanded: !_deletingTodoIds.contains(todo.id),
                      rise: 0,
                      child: _TodoItem(
                        key: ValueKey('todo_item_${todo.id}'),
                        todo: todo,
                        index: index,
                        isDraggable: !_isSelectionMode,
                        isSelectionMode: _isSelectionMode,
                        isSelected: _selectedTodoIds.contains(todo.id),
                        onTap: () => _showTodoBottomSheet(context, todo: todo, folderId: folderId),
                        onToggleComplete: () {
                          ref.read(todoListProvider.notifier).toggleComplete(todo.id, true);
                        },
                        onLongPress: (globalKey) {
                          _showActionMenu(context, todo, key: globalKey);
                        },
                        onDelete: () => _confirmDelete(todo),
                        onSelectToggle: () => _toggleSelectTodo(todo.id),
                      ),
                    ),
                  );
                },
                footer: completedTodos.isEmpty ? null : _buildCompletedSection(context, completedTodos, folderId),
              ),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => AppErrorState(error: e, action: '加载待办失败', onRetry: () => ref.invalidate(todoListProvider)),
        ),
      ),
    );
  }

  /// 构建已完成待办折叠区域
  Widget _buildCompletedSection(BuildContext context, List<Todo> completedTodos, String folderId) {
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
                  AnimatedRotation(
                    turns: _isCompletedCollapsed ? 0.0 : 0.5,
                    duration: AppMotion.duration(context, AppDurations.normal),
                    curve: AppCurves.emphasized,
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(width: 4),
                  AppMotion.switcher(
                    context: context,
                    baseDuration: AppDurations.fast,
                    scale: false,
                    child: Text(
                      '已完成 ${completedTodos.length}',
                      key: ValueKey<int>(completedTodos.length),
                      style: TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 折叠/展开同时过渡高度与透明度；折叠完成后才移除长列表。
          AnimatedCrossFade(
            duration: AppMotion.duration(context, AppDurations.normal),
            sizeCurve: AppCurves.emphasized,
            firstCurve: AppCurves.exit,
            secondCurve: AppCurves.emphasized,
            crossFadeState: _isCompletedCollapsed ? CrossFadeState.showFirst : CrossFadeState.showSecond,
            alignment: Alignment.topCenter,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: _keepCompletedItems
                ? Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const SizedBox(height: 4),
                      ...completedTodos.map(
                        (todo) => AppCollapsible(
                          expanded: !_deletingTodoIds.contains(todo.id),
                          rise: 0,
                          child: _TodoItem(
                            key: ValueKey('todo_completed_${todo.id}'),
                            todo: todo,
                            index: -1,
                            isDraggable: false,
                            animateIn: false,
                            isSelectionMode: _isSelectionMode,
                            isSelected: _selectedTodoIds.contains(todo.id),
                            onTap: () => _showTodoBottomSheet(context, todo: todo, folderId: folderId),
                            onToggleComplete: () {
                              ref.read(todoListProvider.notifier).toggleComplete(todo.id, false);
                            },
                            onLongPress: (globalKey) {
                              _showActionMenu(context, todo, key: globalKey);
                            },
                            onDelete: () => _confirmDelete(todo),
                            onSelectToggle: () => _toggleSelectTodo(todo.id),
                          ),
                        ),
                      ),
                    ],
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// 唤起底部小窗添加待办
  void _addNewTodo(String? folderId) {
    _showTodoBottomSheet(context, folderId: folderId);
  }

  /// 唤起底部小窗（用于添加或编辑待办）
  void _showTodoBottomSheet(BuildContext context, {Todo? todo, String? folderId}) {
    // 弹窗为模态，常规交互不会重入；此守卫仅拦截小组件「+」等异步触发路径的极端时序
    if (_isTodoSheetOpen) return;
    final folders = ref.read(todoFolderListProvider).valueOrNull ?? [];
    final selectedFolderId = ref.read(selectedTodoFolderIdProvider);
    final currentFolderId =
        folderId ??
        ((selectedFolderId != null && folders.any((f) => f.id == selectedFolderId))
            ? selectedFolderId
            : (folders.isNotEmpty ? folders.first.id : null));

    _isTodoSheetOpen = true;
    showModalBottomSheet(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _TodoEditBottomSheet(
        todo: todo,
        folderId: currentFolderId,
        folders: folders,
        onSaveAdd: ({required String title, String? reminderTime, String repeatRule = 'none', String? folderId}) {
          if (title.trim().isEmpty) return;
          ref
              .read(todoListProvider.notifier)
              .addTodo(title: title.trim(), folderId: folderId, reminderTime: reminderTime, repeatRule: repeatRule);
        },
        onSaveEdit: ({required Todo updatedTodo}) {
          if (updatedTodo.title.trim().isEmpty) return;
          ref.read(todoListProvider.notifier).updateTodo(updatedTodo);
        },
        onDelete: (t) => _confirmDelete(t),
        onQuoteToQ: (t) => _quoteTodoToQ(t),
      ),
    ).whenComplete(() => _isTodoSheetOpen = false);
  }

  /// 弹待办操作菜单。
  ///
  /// [key] 与 [anchor] 二选一：常规长按用卡片自身的 [key] 定位；
  /// 「长按拾起后原地松手」时卡片可能正被拖拽浮层替换，改用手指落点定位。
  void _showActionMenu(BuildContext context, Todo todo, {GlobalKey? key, Offset? anchor}) {
    final folders = ref.read(todoFolderListProvider).valueOrNull ?? [];
    final items = <ActionMenuItem>[
      ActionMenuItem(
        iconWidget: QIcon(size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
        label: '给小Q',
        onTap: () => _quoteTodoToQ(todo),
      ),
      ActionMenuItem(icon: Icons.checklist_outlined, label: '批量管理', onTap: () => _enterSelectionMode(todo.id)),
      ActionMenuItem(
        icon: Icons.repeat,
        label: todo.isRecurring ? '重复：${todo.repeatRuleLabel}' : '设置重复',
        onTap: () => _showRepeatRuleDialog(context, todo),
      ),
      ActionMenuItem(
        icon: Icons.alarm,
        label: todo.reminderTime != null ? '修改提醒 ${todo.reminderTime}' : '设置提醒',
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
          label: '移动到分类',
          onTap: () => _showMoveFolderDialog(context, todo, folders),
        ),
      ActionMenuItem(icon: Icons.delete_outline, label: '删除', isDestructive: true, onTap: () => _confirmDelete(todo)),
    ];

    if (anchor != null) {
      ActionMenu.showAt(context: context, position: anchor, items: items);
    } else if (key != null) {
      ActionMenu.show(context: context, key: key, items: items);
    }
  }

  /// 记录按压起点：拖拽排序识别器赢下手势竞技场后不再向业务层吐移动事件，
  /// 而 [Listener] 走原始指针路由、不参与竞技场，能稳定拿到全程位移。
  void _handleListPointerDown(PointerDownEvent event) {
    _pointerDownPosition = event.position;
    _pointerMoved = false;
  }

  void _handleListPointerMove(PointerMoveEvent event) {
    final origin = _pointerDownPosition;
    if (origin == null || _pointerMoved) return;
    if ((event.position - origin).distance > kReorderMoveThreshold) {
      _pointerMoved = true;
    }
  }

  /// 「给小Q」：把该条待办引用给悬浮小Q
  void _quoteTodoToQ(Todo todo) {
    HapticFeedback.lightImpact();
    final title = todo.title.trim();
    final desc = todo.description.trim();
    final due = todo.dueDate;
    ref
        .read(floatingQProvider.notifier)
        .openWithQuote(
          QTextQuote(
            source: QQuoteSource.todo,
            sourceId: todo.id,
            sourceTitle: title.isEmpty ? '一条待办' : title,
            quotedText: desc.isNotEmpty ? desc : title,
            locationDesc: due == null
                ? null
                : '截止 ${due.month.toString().padLeft(2, '0')}-${due.day.toString().padLeft(2, '0')} '
                      '${due.hour.toString().padLeft(2, '0')}:${due.minute.toString().padLeft(2, '0')}',
          ),
        );
  }

  /// 设置待办重复周期
  Future<void> _showRepeatRuleDialog(BuildContext context, Todo todo) async {
    final rules = [
      {'key': 'none', 'label': '不重复', 'desc': '单次任务，不自动生成'},
      {'key': 'daily', 'label': '每天', 'desc': '完成后生成次日待办'},
      {'key': 'workday', 'label': '工作日', 'desc': '周一至周五，周末顺延至下周一'},
      {'key': 'weekly', 'label': '每周', 'desc': '每周同一时间重复'},
      {'key': 'monthly', 'label': '每月', 'desc': '每月同日重复'},
      {'key': 'yearly', 'label': '每年', 'desc': '每年同日重复'},
    ];

    final theme = Theme.of(context);
    await showModalBottomSheet(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large))),
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
                      Icon(Icons.repeat, color: theme.colorScheme.onSurfaceVariant, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '重复周期',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
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
                      color: isSelected ? theme.colorScheme.onSurface : theme.colorScheme.outline,
                    ),
                    title: Text(
                      r['label']!,
                      style: TextStyle(
                        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                        color: isSelected ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
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
  Future<void> _showMoveFolderDialog(BuildContext context, Todo todo, List<Folder> folders) async {
    final theme = Theme.of(context);
    await showModalBottomSheet(
      context: context,
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      backgroundColor: theme.colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large))),
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
                      Icon(Icons.drive_file_move_outlined, color: theme.colorScheme.onSurfaceVariant, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        '移动到分类',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
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
                      color: isCurrent ? theme.accentInk : theme.colorScheme.onSurfaceVariant,
                    ),
                    title: Text(
                      f.name,
                      style: TextStyle(
                        fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                        color: isCurrent ? theme.accentInk : theme.colorScheme.onSurface,
                      ),
                    ),
                    trailing: isCurrent ? Text('当前分类', style: TextStyle(fontSize: 12, color: theme.accentInk)) : null,
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
      sheetAnimationStyle: AppTheme.sheetAnimationStyle,
      isScrollControlled: true,
      backgroundColor: colorScheme.surface,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.large))),
      builder: (ctx) {
        return Consumer(
          builder: (context, ref, child) {
            final folders = ref.watch(todoFolderListProvider).valueOrNull ?? [];
            return SafeArea(
              child: Container(
                constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
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
                              Icon(Icons.category, color: colorScheme.onSurfaceVariant, size: 20),
                              const SizedBox(width: 8),
                              Text(
                                '分类管理',
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
                            leading: Icon(Icons.folder_open, color: colorScheme.onSurfaceVariant),
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
                                          ScaffoldMessenger.of(
                                            context,
                                          ).showSnackBar(const SnackBar(content: Text('至少保留一个分类')));
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
    final confirmed = await AppMotion.showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('新建分类'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '分类名称', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('创建')),
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
    final confirmed = await AppMotion.showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名分类'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '新名称', border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, controller.text.trim()), child: const Text('保存')),
        ],
      ),
    );
    if (confirmed != null && confirmed.isNotEmpty && confirmed != folder.name) {
      ref.read(todoFolderListProvider.notifier).updateFolder(folder.id, confirmed);
    }
  }

  /// 删除分类确认弹窗
  Future<void> _confirmDeleteFolder(BuildContext context, Folder folder) async {
    final confirmed = await AppMotion.showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除分类'),
        content: Text('删除「${folder.name}」？该分类下的待办会一并删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      final success = await ref.read(todoFolderListProvider.notifier).deleteFolder(folder.id);
      if (!success && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('至少保留一个分类')));
      }
    }
  }

  Future<void> _setReminder(Todo todo) async {
    final reminder = todo.reminderTime;
    final result = await showTimePickerDialog(
      context: context,
      initialTime: reminder != null ? ReminderUtils.parse(reminder) : null,
      title: '提醒时间',
    );
    if (result == null) return;
    final formatted = ReminderUtils.format(result);
    ref.read(todoListProvider.notifier).setReminder(todo.id, formatted);
  }

  Future<void> _confirmDelete(Todo todo) async {
    // 在 await 之前取好依赖：收起动画时长用于「先收起再删除」的时序
    final collapse = AppMotion.duration(context, AppDurations.normal);
    final notifier = ref.read(todoListProvider.notifier);
    final confirmed = await AppMotion.showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除待办'),
        content: Text('删除「${todo.title.isEmpty ? '待办' : todo.title}」？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed == true) {
      HapticFeedback.heavyImpact();
      // 先在原地收起再提交删除，避免行瞬间蒸发；减弱动效下直接删除
      setState(() => _deletingTodoIds.add(todo.id));
      if (collapse > Duration.zero) {
        await Future.delayed(collapse);
      }
      notifier.deleteTodo(todo.id);
      if (mounted) _deletingTodoIds.remove(todo.id);
    }
  }
}
