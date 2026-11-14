import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/theme/app_accent.dart';
import 'package:qnote_flutter/core/theme/app_contrast.dart';
import 'package:qnote_flutter/core/theme/app_curves.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/core/theme/app_motion.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/utils/note_file_type.dart';
import 'package:qnote_flutter/core/utils/note_tree_drag.dart';
import 'package:qnote_flutter/core/utils/reorder_gesture.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/floating_q_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/widgets/common/app_collapsible.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/ai/q_avatar.dart';
import 'package:qnote_flutter/widgets/app_error_state.dart';
import 'package:qnote_flutter/widgets/common/app_checkbox.dart';
import 'package:qnote_flutter/widgets/common/app_icon_badge.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';
import 'package:qnote_flutter/widgets/records_section_switcher.dart';
import 'package:qnote_flutter/widgets/diary/journal_editor_view.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';

part 'notes_page_tiles.dart';

class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  bool _isSelectionMode = false;
  Set<String> _selectedNoteIds = {};
  Set<String> _selectedFolderIds = {};

  /// 正在播放收起退场的笔记 / 文件夹 id：动画结束后才真正删除
  final Set<String> _deletingNoteIds = <String>{};
  final Set<String> _deletingFolderIds = <String>{};
  bool _isConfirming = false;
  Timer? _confirmTimer;

  /// 当前正在被拖拽的项（用于优雅展示底部「移至根目录」靶区等全局联动）
  FlattenedItem? _activeDraggingItem;

  /// 拖拽期间的最新指针全局坐标。
  ///
  /// 不再依赖 DragTarget 的 details.offset（那是浮层左上角，会被拖拽锚点偏移），
  /// 页面级命中测试用真实指针位置才能准确区分 before/inside/after。
  Offset? _lastDragGlobal;

  /// 当前指针命中的行与行内落点
  String? _hoverTargetId;
  ReorderDropPosition? _hoverPosition;
  bool _isRootDropHover = false;

  /// 起拖位置与「是否真的移动过」：长按原地不动时不要自动滚动列表
  Offset? _dragStartGlobal;
  bool _dragMoved = false;

  /// 可见行的渲染盒注册表，用于页面级拖拽命中测试
  final Map<String, GlobalKey> _rowKeys = {};
  final GlobalKey _rootDropKey = GlobalKey();
  final GlobalKey _listViewportKey = GlobalKey();
  final ScrollController _scrollController = ScrollController();

  Timer? _autoScrollTimer;
  Timer? _springLoadTimer;

  /// 自动滚动的触发距离与每帧步长（与原实现保持一致，避免改变手感）
  static const double _autoScrollEdge = 72;
  static const double _autoScrollStep = 9;

  /// 拖拽期间的可放置性快照。
  ///
  /// `canDropNoteTreeItem` 内部会多次遍历笔记/文件夹列表并重建文件夹映射，
  /// 每次指针移动都调用代价很高；同一次拖拽内数据不变时判定结果稳定，
  /// 因此起拖时算好（滚动露出新行时按需补算），移动过程中只做查表。
  final Map<String, bool> _dragDropAllowed = {};
  List<Folder>? _dragFolders;
  List<Note>? _dragNotes;

  /// 合并同一帧内多次「滚动后重新命中」请求，避免重复计算
  bool _dragHoverRefreshScheduled = false;

  // 树结构缓存：folders/notes 引用未变时直接复用，
  // 避免每次 rebuild（拖拽 hover、选择模式切换等）重算整棵树。
  // 渲染用完整树，拖拽命中测试则用「当前可见行」的展平结果。
  List<Folder>? _lastFolders;
  List<Note>? _lastNotes;
  List<_TreeNode>? _cachedTreeRoots;
  List<FlattenedItem>? _cachedFlattened;
  Map<String, FlattenedItem>? _cachedFlattenedById;

  List<_TreeNode> _getTreeRoots(List<Folder> folders, List<Note> notes) {
    if (identical(folders, _lastFolders) && identical(notes, _lastNotes) && _cachedTreeRoots != null) {
      return _cachedTreeRoots!;
    }
    final roots = _buildTreeNodes(parentId: null, depth: 0, folders: folders, notes: notes);
    _lastFolders = folders;
    _lastNotes = notes;
    _cachedTreeRoots = roots;
    _cachedFlattened = _flattenVisibleRows(roots);
    _cachedFlattenedById = {for (final item in _cachedFlattened!) item.id: item};
    return roots;
  }

  @override
  void dispose() {
    _confirmTimer?.cancel();
    _autoScrollTimer?.cancel();
    _springLoadTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _exitSelectionMode() {
    setState(() {
      _selectedNoteIds.clear();
      _selectedFolderIds.clear();
      _isSelectionMode = false;
      _isConfirming = false;
    });
    _confirmTimer?.cancel();
  }

  /// 进入批量选择模式（右上角「批量管理」入口，与待办页保持一致的手感）
  void _enterSelectionMode() {
    HapticFeedback.mediumImpact();
    setState(() {
      _isSelectionMode = true;
      _selectedNoteIds.clear();
      _selectedFolderIds.clear();
      _isConfirming = false;
    });
  }

  void _handleBatchDelete() async {
    if (_selectedNoteIds.isEmpty && _selectedFolderIds.isEmpty) return;

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

    final Set<String> deletedFolderIds = {};

    Future<void> deleteFolderAndContents(String folderId) async {
      if (deletedFolderIds.contains(folderId)) return;
      // 日记文件夹不允许被删除（选择入口已屏蔽，此处防御性兜底）
      if (folderId == JournalService.rootFolderId) return;
      deletedFolderIds.add(folderId);

      final allNotes = ref.read(noteListProvider).value ?? [];
      final allFolders = ref.read(folderListProvider).value ?? [];

      final childFolders = allFolders.where((f) => f.parentId == folderId).toList();
      for (final child in childFolders) {
        await deleteFolderAndContents(child.id);
      }

      final notesInFolder = allNotes.where((n) => n.folderId == folderId).toList();
      for (final note in notesInFolder) {
        await ref.read(noteListProvider.notifier).deleteNote(note.id);
      }

      await ref.read(folderListProvider.notifier).deleteFolder(folderId);
    }

    // 1. Delete selected folders recursively
    for (final folderId in _selectedFolderIds) {
      await deleteFolderAndContents(folderId);
    }

    // 2. Delete selected notes (if not already deleted recursively)
    for (final noteId in _selectedNoteIds) {
      await ref.read(noteListProvider.notifier).deleteNote(noteId);
    }

    setState(() {
      _selectedNoteIds.clear();
      _selectedFolderIds.clear();
      _isSelectionMode = false;
      _isConfirming = false;
    });
    _confirmTimer?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    // noteListProvider/folderListProvider 的订阅收窄到 AppBar 全选按钮与 body
    // 两个 Consumer 内，笔记/文件夹任何变更不再重建整个页面骨架
    final scaffold = Scaffold(
      appBar: AppBar(
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
                      // 与待办页一致：开抽屉前先收键盘，避免键盘回落引起的二次布局位移
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
            child: _isSelectionMode
                ? Text('已选 ${_selectedNoteIds.length + _selectedFolderIds.length} 项')
                : const RecordsSectionSwitcher(active: RecordsSection.notes),
          ),
        ),
        centerTitle: true,
        actions: [
          AppMotion.switcher(
            context: context,
            baseDuration: AppDurations.fast,
            child: KeyedSubtree(
              key: ValueKey(_isSelectionMode ? 'select_actions' : 'normal_actions'),
              child: _isSelectionMode
                  ? Consumer(
                      builder: (context, ref, _) {
                        // 日记体系节点不参与批量选择与全选
                        final notes = ref.watch(noteListProvider).value ?? [];
                        final folders = ref.watch(folderListProvider).value ?? [];
                        final selectableNoteIds = notes
                            .where((n) => !JournalService.isJournalNote(n.id))
                            .map((n) => n.id)
                            .toSet();
                        final selectableFolderIds = folders
                            .where((f) => !JournalService.isJournalFolder(f))
                            .map((f) => f.id)
                            .toSet();
                        final isAllSelected =
                            _selectedNoteIds.length == selectableNoteIds.length &&
                            _selectedFolderIds.length == selectableFolderIds.length;
                        return TextButton(
                          onPressed: () {
                            setState(() {
                              if (isAllSelected) {
                                _selectedNoteIds.clear();
                                _selectedFolderIds.clear();
                              } else {
                                _selectedNoteIds = Set<String>.from(selectableNoteIds);
                                _selectedFolderIds = Set<String>.from(selectableFolderIds);
                              }
                            });
                          },
                          child: Text(
                            isAllSelected ? '取消全选' : '全选',
                            style: TextStyle(color: Theme.of(context).accentInk, fontWeight: FontWeight.bold),
                          ),
                        );
                      },
                    )
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: Icon(Icons.checklist_outlined, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          tooltip: '批量管理',
                          onPressed: _enterSelectionMode,
                        ),
                        IconButton(
                          icon: const Icon(Icons.search),
                          tooltip: '搜索',
                          onPressed: () {
                            Navigator.of(context).push(AppMotion.fadeRoute(const SearchView()));
                          },
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
      body: Consumer(
        builder: (context, ref, _) {
          final noteListAsync = ref.watch(noteListProvider);
          final folderListAsync = ref.watch(folderListProvider);
          return noteListAsync.when(
            data: (notes) => folderListAsync.when(
              data: (folders) => _buildTree(context, folders, notes),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) =>
                  AppErrorState(error: e, action: '加载文件夹失败', onRetry: () => ref.invalidate(folderListProvider)),
            ),
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => AppErrorState(error: e, action: '加载笔记失败', onRetry: () => ref.invalidate(noteListProvider)),
          );
        },
      ),
      floatingActionButton: AppMotion.switcher(
        context: context,
        baseDuration: AppDurations.fast,
        alignment: Alignment.bottomRight,
        child: _isSelectionMode
            ? const SizedBox.shrink(key: ValueKey('notes_fabs_hidden'))
            : Column(
                key: const ValueKey('notes_fabs'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  FloatingActionButton.small(
                    heroTag: 'add_folder_fab',
                    shape: const CircleBorder(),
                    onPressed: () => _showCreateFolderDialog(),
                    backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                    foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                    child: const Icon(Icons.create_new_folder_outlined),
                  ),
                  const SizedBox(height: 12),
                  FloatingActionButton(
                    heroTag: 'add_note_fab',
                    shape: const CircleBorder(),
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
                    elevation: 2,
                    onPressed: () => _createNote(),
                    child: const Icon(Icons.add, size: 28),
                  ),
                ],
              ),
      ),
      bottomNavigationBar: AppCollapsible(
        // 统一幕布式收放，保留退出态条内容，避免收起瞬间变空白矩形空缩
        expanded: _isSelectionMode,
        rise: 0,
        child: Container(
          key: const ValueKey('notes_batch_bar'),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            border: Border(top: BorderSide(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.1))),
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.shadow.withValues(alpha: 0.05),
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
                    '已选 ${_selectedNoteIds.length + _selectedFolderIds.length} 项',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  FilledButton(
                    onPressed: (_selectedNoteIds.isEmpty && _selectedFolderIds.isEmpty) ? null : _handleBatchDelete,
                    style: FilledButton.styleFrom(
                      backgroundColor: _isConfirming
                          ? Theme.of(context).colorScheme.error
                          : Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
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
    );

    // 页面级 DragTarget 只负责接收「确实落手」的信号，不参与行内位置判定：
    // 位置由页面用真实指针坐标 + 行渲染盒计算，取消拖拽时不会触发 onAccept。
    return DragTarget<FlattenedItem>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (details) => _handleDropAccepted(details.data),
      builder: (context, candidateData, rejectedData) => scaffold,
    );
  }

  void _showCreateFolderDialog([String? parentId]) {
    final controller = TextEditingController();
    AppMotion.showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null ? '新建文件夹' : '新建子文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名称', border: OutlineInputBorder()),
          onSubmitted: (value) {
            if (value.isNotEmpty) {
              ref.read(folderListProvider.notifier).addFolder(value, parentId);
              Navigator.pop(ctx);
            }
          },
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                ref.read(folderListProvider.notifier).addFolder(controller.text, parentId);
              }
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  void _createNote([String? folderId]) async {
    final note = await ref.read(noteListProvider.notifier).addNote(title: '新笔记', folderId: folderId);
    if (mounted) {
      Navigator.of(context).push(AppMotion.fadeRoute(NoteEditorView(note: note)));
    }
  }

  /// 构建完整树：折叠文件夹的子孙也保留在模型中。
  ///
  /// 折叠只在渲染层隐藏（见 [AppCollapsible]），这样展开动画一开始就能拿到子级，
  /// 收起动画期间也能继续绘制旧内容，直到高度完全收拢。
  List<_TreeNode> _buildTreeNodes({
    required String? parentId,
    required int depth,
    required List<Folder> folders,
    required List<Note> notes,
  }) {
    final nodes = <_TreeNode>[];

    // 展示顺序统一由纯逻辑 buildNoteTreeLevel 决定，落点计算复用同一顺序
    for (final item in buildNoteTreeLevel(folders: folders, notes: notes, parentId: parentId)) {
      if (item is Note) {
        nodes.add(
          _TreeNode(
            FlattenedItem(
              id: item.id,
              isFolder: false,
              note: item,
              depth: depth,
              parentId: parentId,
              isPinned: item.isPinned,
              isJournal: JournalService.isJournalNote(item.id),
            ),
          ),
        );
      } else if (item is Folder) {
        nodes.add(
          _TreeNode(
            FlattenedItem(
              id: item.id,
              isFolder: true,
              folder: item,
              depth: depth,
              parentId: parentId,
              isPinned: false,
              isJournal: JournalService.isJournalFolder(item),
            ),
            children: _buildTreeNodes(parentId: item.id, depth: depth + 1, folders: folders, notes: notes),
          ),
        );
      }
    }

    // 空文件夹展开时插入"空"占位行，避免看起来像点击无响应
    if (nodes.isEmpty && parentId != null) {
      nodes.add(
        _TreeNode(
          FlattenedItem(
            id: 'empty_placeholder_$parentId',
            isFolder: false,
            depth: depth,
            parentId: parentId,
            isPinned: false,
            isEmptyPlaceholder: true,
          ),
        ),
      );
    }

    return nodes;
  }

  /// 展平出当前可见行（折叠文件夹的子孙不参与），供拖拽命中测试按 id 查表。
  List<FlattenedItem> _flattenVisibleRows(List<_TreeNode> roots) {
    final result = <FlattenedItem>[];

    void visit(_TreeNode node) {
      result.add(node.item);
      final folder = node.item.folder;
      if (folder == null || !folder.isExpanded) return;
      for (final child in node.children) {
        visit(child);
      }
    }

    for (final root in roots) {
      visit(root);
    }
    return result;
  }

  void _registerRow(String id, GlobalKey key) {
    _rowKeys[id] = key;
  }

  void _unregisterRow(String id, GlobalKey key) {
    // 同一 id 可能已经换成新的 State，旧 State 销毁时不能误删新注册的 key
    if (identical(_rowKeys[id], key)) {
      _rowKeys.remove(id);
    }
  }

  void _handleDragStarted(FlattenedItem item) {
    _dragFolders = ref.read(folderListProvider).value ?? [];
    _dragNotes = ref.read(noteListProvider).value ?? [];
    _dragDropAllowed.clear();
    // 起拖时一次性为当前可见行算好可放置性，避免指针每次移动都全量扫描数据
    for (final id in _rowKeys.keys) {
      _resolveDragDropAllowed(item.id, id);
    }

    _dragStartGlobal = _lastDragGlobal;
    _dragMoved = false;

    setState(() {
      _activeDraggingItem = item;
      _hoverTargetId = null;
      _hoverPosition = null;
      _isRootDropHover = false;
    });

    final pointer = _lastDragGlobal;
    if (pointer != null) {
      _updateDragHover(pointer);
    }
    // 原地长按不动时不需要自动滚动，等指针真正靠近边缘再启动定时器
    _syncAutoScrollTimer();
  }

  void _handleDragPosition(Offset globalPosition) {
    _lastDragGlobal = globalPosition;
    if (_activeDraggingItem == null) return;

    if (!_dragMoved) {
      final start = _dragStartGlobal;
      if (start != null && (globalPosition - start).distance > kReorderMoveThreshold) {
        _dragMoved = true;
      }
    }
    _updateDragHover(globalPosition);
    _syncAutoScrollTimer();
  }

  void _handleDragEnded() {
    _stopAutoScrollTimer();
    _springLoadTimer?.cancel();
    _springLoadTimer = null;
    // 拖拽结束后快照失效，释放引用并清空缓存，避免下次拖拽误用旧数据
    _dragDropAllowed.clear();
    _dragFolders = null;
    _dragNotes = null;
    if (!mounted) return;

    setState(() {
      _activeDraggingItem = null;
      _lastDragGlobal = null;
      _dragStartGlobal = null;
      _dragMoved = false;
      _hoverTargetId = null;
      _hoverPosition = null;
      _isRootDropHover = false;
    });
  }

  void _handleDropAccepted(FlattenedItem dragged) {
    final pointer = _lastDragGlobal;
    if (pointer == null) return;

    // 落手瞬间再按最后指针位置校准一次，避免自动滚动后沿用上一帧的悬停行
    _updateDragHover(pointer, silent: true);

    if (_isRootDropHover) {
      HapticFeedback.lightImpact();
      final name = dragged.isFolder ? dragged.folder?.name : dragged.note?.title;
      unawaited(
        _applyDrop(draggedId: dragged.id, targetId: null, position: ReorderDropPosition.after).then((ok) {
          if (!ok || !mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('已将 "${name ?? ''}" 移至根目录'),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 2),
            ),
          );
        }),
      );
      return;
    }

    final targetId = _hoverTargetId;
    final position = _hoverPosition;
    if (targetId == null || position == null) return;

    HapticFeedback.lightImpact();
    unawaited(_applyDrop(draggedId: dragged.id, targetId: targetId, position: position));
  }

  /// 统一处理所有「移动到某层级」的落库：拖拽、菜单、底部根目录胶囊共用。
  Future<bool> _applyDrop({
    required String draggedId,
    required String? targetId,
    required ReorderDropPosition position,
  }) async {
    final folders = ref.read(folderListProvider).value ?? [];
    final notes = ref.read(noteListProvider).value ?? [];
    final plan = planNoteTreeDrop(
      folders: folders,
      notes: notes,
      draggedId: draggedId,
      targetId: targetId,
      position: position,
    );
    if (plan == null || plan.isEmpty) return false;

    try {
      if (plan.notes.isNotEmpty) {
        await ref.read(noteListProvider.notifier).reorderNotes(plan.notes);
      }
      if (plan.folders.isNotEmpty) {
        await ref.read(folderListProvider.notifier).reorderFolders(plan.folders);
      }
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logDatabase('笔记拖拽保存失败', level: LogLevel.error, details: '$e\n$stackTrace');
      if (mounted) {
        // 两项写入可能只成功了一项，统一让 Provider 回库对齐
        ref.invalidate(noteListProvider);
        ref.invalidate(folderListProvider);
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('拖拽保存失败，请重试'), behavior: SnackBarBehavior.floating));
      }
      return false;
    }
  }

  /// 用真实指针坐标在可见行中做命中测试，再按行内纵坐标解析落点。
  void _updateDragHover(Offset globalPosition, {bool silent = false}) {
    final dragged = _activeDraggingItem;
    if (dragged == null) return;

    // 1. 底部「移至根目录」胶囊优先，避免被下方的行抢走
    if (dragged.parentId != null) {
      final rootBox = _rootDropKey.currentContext?.findRenderObject() as RenderBox?;
      if (rootBox != null && rootBox.hasSize) {
        final rootRect = rootBox.localToGlobal(Offset.zero) & rootBox.size;
        if (rootRect.contains(globalPosition)) {
          _setHover(targetId: null, position: null, rootHover: true, silent: silent);
          return;
        }
      }
    }

    // 2. 只在列表视口内命中可见行；视口外的坐标为无效落点
    final viewportBox = _listViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) {
      _setHover(targetId: null, position: null, rootHover: false, silent: silent);
      return;
    }
    final viewportRect = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    if (!viewportRect.contains(globalPosition)) {
      _setHover(targetId: null, position: null, rootHover: false, silent: silent);
      return;
    }

    // 数据若在拖拽期间被外部改动（弹簧展开文件夹、同步等），清空旧判定按新数据重算
    _refreshDragDropData();

    for (final entry in _rowKeys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      final rect = box.localToGlobal(Offset.zero) & box.size;
      if (!rect.contains(globalPosition)) continue;

      final target = _cachedFlattenedById?[entry.key];
      if (target == null) continue;

      // 可放置性在起拖时已算好，这里只查表，不再逐行扫描笔记/文件夹
      if (!_resolveDragDropAllowed(dragged.id, target.id)) {
        _setHover(targetId: null, position: null, rootHover: false, silent: silent);
        return;
      }

      final position = resolveReorderDropPosition(
        localY: globalPosition.dy - rect.top,
        rowHeight: rect.height,
        allowsInside: target.isFolder && !target.isJournal,
      );
      _setHover(targetId: target.id, position: position, rootHover: false, silent: silent);
      return;
    }

    _setHover(targetId: null, position: null, rootHover: false, silent: silent);
  }

  /// 拖拽期间数据引用变化时丢弃旧判定结果，保证与实时读取数据的行为一致。
  void _refreshDragDropData() {
    final folders = ref.read(folderListProvider).value ?? [];
    final notes = ref.read(noteListProvider).value ?? [];
    if (identical(folders, _dragFolders) && identical(notes, _dragNotes)) return;
    _dragFolders = folders;
    _dragNotes = notes;
    _dragDropAllowed.clear();
  }

  /// 查询某目标行的可放置性：命中快照直接返回，滚动露出的新行按需补算。
  bool _resolveDragDropAllowed(String draggedId, String targetId) {
    final cached = _dragDropAllowed[targetId];
    if (cached != null) return cached;
    final allowed = canDropNoteTreeItem(
      folders: _dragFolders ?? const <Folder>[],
      notes: _dragNotes ?? const <Note>[],
      draggedId: draggedId,
      targetId: targetId,
    );
    _dragDropAllowed[targetId] = allowed;
    return allowed;
  }

  void _setHover({
    required String? targetId,
    required ReorderDropPosition? position,
    required bool rootHover,
    required bool silent,
  }) {
    if (_hoverTargetId == targetId && _hoverPosition == position && _isRootDropHover == rootHover) {
      return;
    }

    if (!silent && !rootHover && position == ReorderDropPosition.inside) {
      HapticFeedback.selectionClick();
    }

    setState(() {
      _hoverTargetId = targetId;
      _hoverPosition = position;
      _isRootDropHover = rootHover;
    });
    _syncSpringLoad(targetId, position, rootHover);
  }

  void _syncSpringLoad(String? targetId, ReorderDropPosition? position, bool rootHover) {
    _springLoadTimer?.cancel();
    _springLoadTimer = null;
    if (rootHover || position != ReorderDropPosition.inside || targetId == null) return;

    final folder = _cachedFlattenedById?[targetId]?.folder;
    if (folder == null || folder.isExpanded) return;

    // 悬停片刻自动展开，支持一次拖拽进入多层文件夹
    _springLoadTimer = Timer(const Duration(milliseconds: 600), () {
      _springLoadTimer = null;
      if (!mounted) return;
      unawaited(ref.read(folderListProvider.notifier).toggleExpanded(folder.id, true));
    });
  }

  /// 指针是否位于列表视口上下边缘的自动滚动触发区。
  bool _isPointerNearAutoScrollEdge() {
    final pointer = _lastDragGlobal;
    if (pointer == null || _activeDraggingItem == null || !_dragMoved || _isRootDropHover) return false;
    if (!_scrollController.hasClients) return false;

    final viewportBox = _listViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) return false;
    final viewportRect = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;
    if (!viewportRect.contains(pointer)) return false;

    return pointer.dy < viewportRect.top + _autoScrollEdge || pointer.dy > viewportRect.bottom - _autoScrollEdge;
  }

  /// 仅在指针靠近边缘时启动 16ms 定时器，离开边缘立即停表，避免常驻空转。
  void _syncAutoScrollTimer() {
    if (_isPointerNearAutoScrollEdge()) {
      // 复用已有定时器，避免指针每次微动都重置计时相位
      _autoScrollTimer ??= Timer.periodic(const Duration(milliseconds: 16), (_) => _tickAutoScroll());
    } else {
      _stopAutoScrollTimer();
    }
  }

  void _stopAutoScrollTimer() {
    _autoScrollTimer?.cancel();
    _autoScrollTimer = null;
  }

  /// 拖到列表上下边缘时持续滚动，滚动后主动重新命中（指针本身没动）。
  void _tickAutoScroll() {
    if (!_isPointerNearAutoScrollEdge()) {
      _stopAutoScrollTimer();
      return;
    }
    final pointer = _lastDragGlobal!;

    final viewportBox = _listViewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (viewportBox == null || !viewportBox.hasSize) {
      _stopAutoScrollTimer();
      return;
    }
    final viewportRect = viewportBox.localToGlobal(Offset.zero) & viewportBox.size;

    final delta = pointer.dy < viewportRect.top + _autoScrollEdge ? -_autoScrollStep : _autoScrollStep;
    final position = _scrollController.position;
    final next = (position.pixels + delta).clamp(position.minScrollExtent, position.maxScrollExtent).toDouble();
    // 已到滚动边界时保持定时器，与原实现一致，等指针移动后自然继续
    if ((next - position.pixels).abs() < 0.5) return;

    _scrollController.jumpTo(next);
    // 滚动后行位置变了但指针没动，等本帧布局完成再补一次命中计算
    _scheduleDragHoverRefresh();
  }

  /// 合并同一帧内的多次刷新请求，布局完成后再用最新行位置重新命中。
  void _scheduleDragHoverRefresh() {
    if (_dragHoverRefreshScheduled) return;
    _dragHoverRefreshScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _dragHoverRefreshScheduled = false;
      if (!mounted || _activeDraggingItem == null) return;
      final latest = _lastDragGlobal;
      if (latest != null) {
        _updateDragHover(latest);
      }
      // 行集合可能因弹簧展开而变化，指针仍在边缘区时需要继续自动滚动
      _syncAutoScrollTimer();
    });
  }

  /// 渲染一个树节点：文件夹把子级包进带展开/收起动画的 [AppCollapsible]。
  ///
  /// 子级始终来自完整树，折叠时由 [AppCollapsible] 决定卸载并在收起期间保留快照绘制。
  Widget _buildTreeNode(_TreeNode node) {
    final item = node.item;
    final tile = _buildFlattenedTile(item);

    if (!item.isFolder) {
      return KeyedSubtree(
        key: ValueKey('tree_${item.id}'),
        child: AppCollapsible(expanded: !_deletingNoteIds.contains(item.id), rise: 0, child: tile),
      );
    }

    return KeyedSubtree(
      key: ValueKey('tree_${item.id}'),
      child: AppCollapsible(
        expanded: !_deletingFolderIds.contains(item.id),
        rise: 0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            tile,
            AppCollapsible(
              expanded: item.folder!.isExpanded,
              // 折叠时不再递归构建整棵子树：AppCollapsible 收起时会自行保留
              // 最后一份真实内容播放退场，稳态下隐藏节点不产生任何 widget 分配。
              child: item.folder!.isExpanded
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [for (final child in node.children) _buildTreeNode(child)],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFlattenedTile(FlattenedItem item) {
    return _FlattenedTile(
      key: ValueKey('${item.isFolder ? 'folder' : 'note'}_${item.id}'),
      item: item,
      isSelectionMode: _isSelectionMode,
      isSelected: item.isFolder ? _selectedFolderIds.contains(item.id) : _selectedNoteIds.contains(item.id),
      hoverPosition: _activeDraggingItem != null && _hoverTargetId == item.id ? _hoverPosition : null,
      onRegisterRow: _registerRow,
      onUnregisterRow: _unregisterRow,
      onToggleSelection: () {
        setState(() {
          if (item.isFolder) {
            if (_selectedFolderIds.contains(item.id)) {
              _selectedFolderIds.remove(item.id);
            } else {
              _selectedFolderIds.add(item.id);
            }
          } else {
            if (_selectedNoteIds.contains(item.id)) {
              _selectedNoteIds.remove(item.id);
            } else {
              _selectedNoteIds.add(item.id);
            }
          }
          if (_selectedNoteIds.isEmpty && _selectedFolderIds.isEmpty) {
            _isSelectionMode = false;
          }
        });
      },
      onEditNote: _editNote,
      onShowNoteMenu: _showNoteMenu,
      onToggleFolder: _toggleFolder,
      onShowFolderMenu: _showFolderMenu,
      onCreateNote: _createNote,
      onCreateFolder: _showCreateFolderDialog,
      onDragStarted: _handleDragStarted,
      onDragPosition: _handleDragPosition,
      onDragEnded: _handleDragEnded,
    );
  }

  Widget _buildTree(BuildContext context, List<Folder> folders, List<Note> notes) {
    if (folders.isEmpty && notes.isEmpty) {
      // 空态与树之间交叉淡化，删除/新建最后一条时不再整页硬切
      final emptyView = AppMotion.switcher(
        context: context,
        baseDuration: AppDurations.normal,
        child: KeyedSubtree(
          key: const ValueKey('notes_empty'),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const EmptyStateWidget(icon: Icons.note_outlined, message: '暂无笔记'),
              const SizedBox(height: 8),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _showCreateFolderDialog(),
                    icon: const Icon(Icons.create_new_folder_outlined),
                    label: const Text('新建文件夹'),
                  ),
                  const SizedBox(width: 12),
                  FilledButton.icon(
                    onPressed: () => _createNote(),
                    icon: const Icon(Icons.add),
                    label: const Text('新建笔记'),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      return _withBlankAreaMenu(emptyView);
    }

    final roots = _getTreeRoots(folders, notes);
    final theme = Theme.of(context);

    final treeView = AppMotion.switcher(
      context: context,
      baseDuration: AppDurations.normal,
      child: KeyedSubtree(
        key: const ValueKey('notes_tree'),
        child: Stack(
          children: [
            ListView.builder(
              key: _listViewportKey,
              controller: _scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 140),
              itemCount: roots.length,
              itemBuilder: (context, index) => _buildTreeNode(roots[index]),
            ),

            // 仅当拖动项是有父级的子项时，悬浮呼出底部「移至根目录」胶囊。
            // 收窄为居中胶囊并补上入退场过渡，避免整行宽靶区遮挡列表且松手瞬间闪灭。
            Positioned(
              left: 0,
              right: 0,
              bottom: 24,
              child: IgnorePointer(
                ignoring: _activeDraggingItem == null || _activeDraggingItem!.parentId == null,
                child: Center(
                  child: AppMotion.switcher(
                    context: context,
                    alignment: Alignment.bottomCenter,
                    child: (_activeDraggingItem != null && _activeDraggingItem!.parentId != null)
                        ? SizedBox(
                            key: const ValueKey('root_drop_pill'),
                            width: 220,
                            height: 56,
                            child: AnimatedContainer(
                              key: _rootDropKey,
                              duration: AppMotion.duration(context, AppDurations.fast),
                              curve: AppCurves.standard,
                              decoration: BoxDecoration(
                                color: _isRootDropHover
                                    ? theme.colorScheme.primaryContainer
                                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
                                borderRadius: BorderRadius.circular(28),
                                border: Border.all(
                                  color: _isRootDropHover
                                      ? theme.colorScheme.primary
                                      : theme.colorScheme.outlineVariant,
                                  width: _isRootDropHover ? 2.0 : 1.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: Colors.black.withValues(alpha: _isRootDropHover ? 0.2 : 0.12),
                                    blurRadius: _isRootDropHover ? 16 : 8,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                              ),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.drive_file_move_outlined,
                                    size: _isRootDropHover ? 24 : 20,
                                    color: _isRootDropHover
                                        ? theme.colorScheme.primary
                                        : theme.colorScheme.onSurfaceVariant,
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    _isRootDropHover ? '松手移至根目录' : '移至根目录',
                                    style: TextStyle(
                                      color: _isRootDropHover
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.onSurfaceVariant,
                                      fontWeight: _isRootDropHover ? FontWeight.bold : FontWeight.w600,
                                      fontSize: 15,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          )
                        : const SizedBox.shrink(key: ValueKey('root_drop_empty')),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return _withBlankAreaMenu(treeView);
  }

  /// 长按列表空白处（未命中任何可见行）唤起页面级快捷菜单，锚点直接用长按落点；
  /// 落点若在行内则不拦截，交给行自身的长按手势（拖拽拾起/行菜单）。
  void _handleBlankAreaLongPress(LongPressStartDetails details) {
    if (_isSelectionMode || _activeDraggingItem != null) return;

    final position = details.globalPosition;
    for (final key in _rowKeys.values) {
      final box = key.currentContext?.findRenderObject() as RenderBox?;
      if (box == null || !box.hasSize) continue;
      // 命中已注册的可见行（含日记系统节点）不算空白处，维持行内原有交互
      if ((box.localToGlobal(Offset.zero) & box.size).contains(position)) return;
    }

    HapticFeedback.lightImpact();
    ActionMenu.showAt(
      context: context,
      position: position,
      items: [
        ActionMenuItem(icon: Icons.add, label: '新建笔记', onTap: () => _createNote()),
        ActionMenuItem(icon: Icons.create_new_folder_outlined, label: '新建文件夹', onTap: () => _showCreateFolderDialog()),
        ActionMenuItem(icon: Icons.select_all_outlined, label: '批量编辑', onTap: _enterSelectionMode),
      ],
    );
  }

  /// 给树的两种形态（空态/列表）统一包上「长按空白处弹菜单」手势层
  Widget _withBlankAreaMenu(Widget child) {
    return GestureDetector(onLongPressStart: _handleBlankAreaLongPress, behavior: HitTestBehavior.opaque, child: child);
  }

  void _editNote(Note note) {
    // 日记笔记统一走日记编辑器，与时间线入口保持一致体验
    if (JournalService.isJournalNote(note.id)) {
      final date = DateTime.tryParse(note.title);
      if (date != null) {
        Navigator.of(context).push(AppMotion.fadeRoute(JournalEditorView(date: date)));
        return;
      }
    }
    Navigator.of(context).push(AppMotion.fadeRoute(NoteEditorView(note: note)));
  }

  void _toggleFolder(Folder folder) {
    ref.read(folderListProvider.notifier).toggleExpanded(folder.id, !folder.isExpanded);
  }

  void _showMoveToFolderDialog(BuildContext context, {Note? note, Folder? folder}) {
    assert(note != null || folder != null);
    final isFolder = folder != null;
    final title = isFolder ? '移动文件夹 "${folder.name}"' : '移动笔记 "${note!.title}"';

    final folderListAsync = ref.read(folderListProvider);
    final allFolders = folderListAsync.value ?? [];

    final invalidIds = <String>{};
    if (isFolder) {
      for (final candidate in allFolders) {
        if (isFolderSelfOrDescendant(folderId: candidate.id, ancestorId: folder.id, folders: allFolders)) {
          invalidIds.add(candidate.id);
        }
      }
    }

    final flattened = <Map<String, dynamic>>[];
    void traverse(String? parentId, int depth) {
      final children = allFolders.where((f) => f.parentId == parentId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      for (final child in children) {
        // 日记文件夹不可作为普通笔记/文件夹的移动目标
        if (JournalService.isJournalFolder(child)) continue;
        flattened.add({'folder': child, 'depth': depth});
        traverse(child.id, depth + 1);
      }
    }

    traverse(null, 0);

    final theme = Theme.of(context);

    AppMotion.showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              ListTile(
                leading: Icon(
                  Icons.folder_open,
                  color: (isFolder ? folder.parentId == null : note!.folderId == null)
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                title: Text(
                  '根目录',
                  style: TextStyle(
                    fontWeight: (isFolder ? folder.parentId == null : note!.folderId == null)
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                onTap: () {
                  final currentParentId = isFolder ? folder.parentId : note!.folderId;
                  Navigator.pop(ctx);
                  // 已经在根目录时无需追加排序，避免一次无意义的整层重排
                  if (currentParentId == null) return;
                  unawaited(
                    _applyDrop(
                      draggedId: isFolder ? folder.id : note!.id,
                      targetId: null,
                      position: ReorderDropPosition.after,
                    ),
                  );
                },
              ),
              const Divider(),
              ...flattened.map((item) {
                final Folder f = item['folder'];
                final int depth = item['depth'];
                final isInvalid = invalidIds.contains(f.id);
                final isCurrentParent = isFolder ? folder.parentId == f.id : note!.folderId == f.id;

                return ListTile(
                  contentPadding: EdgeInsets.only(left: 16.0 + depth * 16.0),
                  enabled: !isInvalid,
                  leading: Icon(
                    Icons.folder,
                    color: isInvalid
                        ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.2)
                        : (isCurrentParent
                              ? theme.colorScheme.primary
                              : theme.colorScheme.primary.withValues(alpha: 0.5)),
                  ),
                  title: Text(
                    f.name,
                    style: TextStyle(
                      fontWeight: isCurrentParent ? FontWeight.bold : FontWeight.normal,
                      color: isInvalid ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.3) : null,
                    ),
                  ),
                  onTap: () {
                    final currentParentId = isFolder ? folder.parentId : note!.folderId;
                    Navigator.pop(ctx);
                    // 点当前父级不做「追加到末尾」，保持原位置
                    if (currentParentId == f.id) return;
                    unawaited(
                      _applyDrop(
                        draggedId: isFolder ? folder.id : note!.id,
                        targetId: f.id,
                        position: ReorderDropPosition.inside,
                      ),
                    );
                  },
                );
              }),
            ],
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消'))],
      ),
    );
  }

  void _showNoteMenu(Note note, GlobalKey key) {
    ActionMenu.show(
      context: context,
      key: key,
      items: [
        ActionMenuItem(
          iconWidget: QIcon(size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
          label: '给小Q',
          onTap: () => _quoteNoteToQ(note),
        ),
        ActionMenuItem(icon: Icons.edit_outlined, label: '编辑笔记', onTap: () => _editNote(note)),
        ActionMenuItem(
          icon: Icons.drive_file_move_outlined,
          label: '移至文件夹',
          onTap: () => _showMoveToFolderDialog(context, note: note),
        ),
        ActionMenuItem(icon: Icons.share_outlined, label: '分享笔记', onTap: () {}),
        ActionMenuItem(
          icon: Icons.select_all_outlined,
          label: '批量编辑',
          onTap: () {
            setState(() {
              _isSelectionMode = true;
              _selectedNoteIds.add(note.id);
            });
          },
        ),
        ActionMenuItem(
          icon: Icons.delete_outline,
          label: '删除笔记',
          isDestructive: true,
          onTap: () async {
            // 先在原地收起再提交删除，避免行瞬间消失；减弱动效下直接删除
            final collapse = AppMotion.duration(context, AppDurations.normal);
            final notifier = ref.read(noteListProvider.notifier);
            setState(() => _deletingNoteIds.add(note.id));
            if (collapse > Duration.zero) {
              await Future.delayed(collapse);
            }
            await notifier.deleteNote(note.id);
            if (mounted) _deletingNoteIds.remove(note.id);
          },
        ),
      ],
    );
  }

  /// 「给小Q」：把整篇笔记引用给悬浮小Q（总结/改写/提问均可，无需先打开笔记），
  /// 笔记 id 与 VFS 路径在发送时由引用块注入，这里只带内容摘录展示
  void _quoteNoteToQ(Note note) {
    HapticFeedback.lightImpact();
    final content = decodeNoteContent(note.content).trim();
    final excerpt = content.isNotEmpty ? content : note.title.trim();
    ref
        .read(floatingQProvider.notifier)
        .openWithQuote(
          QTextQuote(
            source: QQuoteSource.note,
            sourceId: note.id,
            sourceTitle: note.title.trim().isEmpty ? '无标题' : note.title.trim(),
            quotedText: excerpt.length > 500 ? '${excerpt.substring(0, 500)}…' : excerpt,
          ),
        );
  }

  void _showFolderMenu(Folder folder, GlobalKey key) {
    ActionMenu.show(
      context: context,
      key: key,
      items: [
        ActionMenuItem(icon: Icons.edit_outlined, label: '重命名文件夹', onTap: () => _renameFolder(folder)),
        ActionMenuItem(
          icon: Icons.create_new_folder_outlined,
          label: '新建子文件夹',
          onTap: () => _showCreateFolderDialog(folder.id),
        ),
        ActionMenuItem(icon: Icons.add, label: '新建笔记', onTap: () => _createNote(folder.id)),
        ActionMenuItem(
          icon: Icons.drive_file_move_outlined,
          label: '移动文件夹',
          onTap: () => _showMoveToFolderDialog(context, folder: folder),
        ),
        ActionMenuItem(
          icon: Icons.select_all_outlined,
          label: '批量编辑',
          onTap: () {
            setState(() {
              _isSelectionMode = true;
              _selectedFolderIds.add(folder.id);
            });
          },
        ),
        ActionMenuItem(
          icon: Icons.delete_outline,
          label: '删除文件夹',
          isDestructive: true,
          onTap: () async {
            // 整个文件夹子树先收起再删除，避免整块内容瞬间消失
            final collapse = AppMotion.duration(context, AppDurations.normal);
            final notifier = ref.read(folderListProvider.notifier);
            setState(() => _deletingFolderIds.add(folder.id));
            if (collapse > Duration.zero) {
              await Future.delayed(collapse);
            }
            await notifier.deleteFolder(folder.id);
            if (mounted) _deletingFolderIds.remove(folder.id);
          },
        ),
      ],
    );
  }

  void _renameFolder(Folder folder) {
    final controller = TextEditingController(text: folder.name);
    AppMotion.showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '名称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                ref.read(folderListProvider.notifier).updateFolder(folder.copyWith(name: controller.text));
              }
              Navigator.pop(ctx);
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }
}
