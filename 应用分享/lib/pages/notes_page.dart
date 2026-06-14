import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/core/theme/app_durations.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';
import 'package:qnote_flutter/widgets/empty_state.dart';

class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  bool _isSelectionMode = false;
  Set<String> _selectedNoteIds = {};
  Set<String> _selectedFolderIds = {};
  bool _isConfirming = false;
  Timer? _confirmTimer;

  @override
  void dispose() {
    _confirmTimer?.cancel();
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
    final noteListAsync = ref.watch(noteListProvider);
    final folderListAsync = ref.watch(folderListProvider);

    final notes = noteListAsync.value ?? [];
    final folders = folderListAsync.value ?? [];

    return Scaffold(
      appBar: AppBar(
        leading: _isSelectionMode
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: _exitSelectionMode,
              )
            : IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => rootScaffoldKey.currentState?.openDrawer(),
              ),
        title: Text(
          _isSelectionMode
              ? '已选择 ${_selectedNoteIds.length + _selectedFolderIds.length} 项'
              : '笔记',
        ),
        actions: [
          if (_isSelectionMode)
            TextButton(
              onPressed: () {
                final isAllSelected = _selectedNoteIds.length == notes.length &&
                    _selectedFolderIds.length == folders.length;
                setState(() {
                  if (isAllSelected) {
                    _selectedNoteIds.clear();
                    _selectedFolderIds.clear();
                  } else {
                    _selectedNoteIds = notes.map((n) => n.id).toSet();
                    _selectedFolderIds = folders.map((f) => f.id).toSet();
                  }
                });
              },
              child: Text(
                _selectedNoteIds.length == notes.length &&
                        _selectedFolderIds.length == folders.length
                    ? '取消全选'
                    : '全选',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          else
            IconButton(
              icon: const Icon(Icons.search),
              tooltip: '搜索',
              onPressed: () {
                Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SearchView()));
              },
            ),
        ],
      ),
      body: noteListAsync.when(
        data: (notes) => folderListAsync.when(
          data: (folders) => _buildTree(context, folders, notes),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(child: Text('加载文件夹失败: $e')),
        ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('加载失败: $e')),
      ),
      floatingActionButton: _isSelectionMode
          ? null
          : Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FloatingActionButton.small(
                  heroTag: 'add_folder_fab',
                  shape: const CircleBorder(),
                  onPressed: () => _showCreateFolderDialog(),
                  backgroundColor:
                      Theme.of(context).colorScheme.secondaryContainer,
                  foregroundColor:
                      Theme.of(context).colorScheme.onSecondaryContainer,
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
      bottomNavigationBar: _isSelectionMode
          ? Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border(
                  top: BorderSide(
                    color: Theme.of(context)
                        .colorScheme
                        .outlineVariant
                        .withValues(alpha: 0.1),
                  ),
                ),
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
                        style: Theme.of(context)
                            .textTheme
                            .bodyMedium
                            ?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      FilledButton(
                        onPressed: (_selectedNoteIds.isEmpty &&
                                _selectedFolderIds.isEmpty)
                            ? null
                            : _handleBatchDelete,
                        style: FilledButton.styleFrom(
                          backgroundColor: _isConfirming
                              ? Theme.of(context).colorScheme.error
                              : Theme.of(context).colorScheme.error,
                          foregroundColor: Colors.white,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(24),
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.delete_outline, size: 16),
                            const SizedBox(width: 6),
                            Text(
                              _isConfirming ? '再次点击确认' : '删除',
                              style:
                                  const TextStyle(fontWeight: FontWeight.bold),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            )
          : null,
    );
  }

  void _showCreateFolderDialog([String? parentId]) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(parentId == null ? '新建文件夹' : '新建子文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: '文件夹名称',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            if (value.isNotEmpty) {
              ref.read(folderListProvider.notifier).addFolder(value, parentId);
              Navigator.pop(ctx);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                ref
                    .read(folderListProvider.notifier)
                    .addFolder(controller.text, parentId);
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
    final note = await ref
        .read(noteListProvider.notifier)
        .addNote(title: '新笔记', folderId: folderId);
    if (mounted) {
      Navigator.of(
        context,
      ).push(MaterialPageRoute(builder: (_) => NoteEditorView(note: note)));
    }
  }

  List<FlattenedItem> _flattenTree(
    String? parentId,
    int depth,
    List<Folder> folders,
    List<Note> notes,
  ) {
    final List<FlattenedItem> result = [];

    // 获取该层级的文件夹和笔记
    final childFolders = folders.where((f) => f.parentId == parentId).toList();
    final childNotes = notes.where((n) => n.folderId == parentId).toList();

    final pinnedNotes = childNotes.where((n) => n.isPinned).toList();
    final unpinnedNotes = childNotes.where((n) => !n.isPinned).toList();

    final List<dynamic> sortableItems = [...unpinnedNotes, ...childFolders];
    sortableItems.sort((a, b) {
      final aOrder = a is Note ? a.sortOrder : (a as Folder).sortOrder;
      final bOrder = b is Note ? b.sortOrder : (b as Folder).sortOrder;
      if (aOrder != bOrder) {
        return aOrder.compareTo(bOrder);
      }
      if (a is Note && b is Note) {
        return b.createdAt.compareTo(a.createdAt);
      } else if (a is Folder && b is Folder) {
        return a.name.compareTo(b.name);
      } else {
        return a is Folder ? -1 : 1;
      }
    });

    // 1. 先加入置顶的笔记
    for (final note in pinnedNotes) {
      result.add(FlattenedItem(
        id: note.id,
        isFolder: false,
        note: note,
        depth: depth,
        parentId: parentId,
        isPinned: true,
      ));
    }

    // 2. 加入排序后的可排项（文件夹和未置顶笔记）
    for (final item in sortableItems) {
      if (item is Note) {
        result.add(FlattenedItem(
          id: item.id,
          isFolder: false,
          note: item,
          depth: depth,
          parentId: parentId,
          isPinned: false,
        ));
      } else {
        final folder = item as Folder;
        result.add(FlattenedItem(
          id: folder.id,
          isFolder: true,
          folder: folder,
          depth: depth,
          parentId: parentId,
          isPinned: false,
        ));
        // 如果文件夹展开，递归将其子孙节点也加入展平列表
        if (folder.isExpanded) {
          result.addAll(_flattenTree(folder.id, depth + 1, folders, notes));
        }
      }
    }

    return result;
  }

  bool _isDescendantOf(String? parentId, String folderId, List<Folder> allFolders) {
    if (parentId == null) return false;
    if (parentId == folderId) return true;
    final parentFolder = allFolders.where((f) => f.id == parentId).firstOrNull;
    if (parentFolder == null) return false;
    return _isDescendantOf(parentFolder.parentId, folderId, allFolders);
  }

  Future<void> _handleDrop({
    required FlattenedItem draggedItem,
    required FlattenedItem targetItem,
    required String dropPosition,
  }) async {
    final now = DateTime.now();

    // 1. 基本安全检查
    if (draggedItem.id == targetItem.id) return;

    final allFolders = ref.read(folderListProvider).value ?? [];

    // 2. 文件夹循环移动防御
    if (draggedItem.isFolder) {
      final isTargetDescendant = _isDescendantOf(
        dropPosition == 'inside' ? targetItem.id : targetItem.parentId,
        draggedItem.id,
        allFolders,
      );
      if (isTargetDescendant) return;
    }

    // 3. 确定目标 parentId
    final String? destParentId = dropPosition == 'inside' ? targetItem.id : targetItem.parentId;

    // 4. 更新 draggedItem 的 parentId 属性并通知 Provider
    if (draggedItem.isFolder) {
      final folder = draggedItem.folder!;
      if (folder.parentId != destParentId) {
        await ref.read(folderListProvider.notifier).updateFolder(
          folder.copyWith(parentId: destParentId, updatedAt: now),
        );
      }
    } else {
      final note = draggedItem.note!;
      if (note.folderId != destParentId) {
        await ref.read(noteListProvider.notifier).updateNote(
          note.copyWith(folderId: destParentId, updatedAt: now),
        );
      }
    }

    if (dropPosition == 'inside') {
      // 移入文件夹：给它一个最大的 sortOrder 即可
      final allNotes = ref.read(noteListProvider).value ?? [];
      final refreshedFolders = ref.read(folderListProvider).value ?? [];

      final siblings = [
        ...refreshedFolders.where((f) => f.parentId == destParentId && f.id != draggedItem.id),
        ...allNotes.where((n) => n.folderId == destParentId && !n.isPinned && n.id != draggedItem.id),
      ];
      int maxSortOrder = -1;
      for (final s in siblings) {
        final order = s is Note ? s.sortOrder : (s as Folder).sortOrder;
        if (order > maxSortOrder) {
          maxSortOrder = order;
        }
      }

      if (draggedItem.isFolder) {
        final folder = refreshedFolders.firstWhere((f) => f.id == draggedItem.id);
        await ref.read(folderListProvider.notifier).updateFolder(
          folder.copyWith(sortOrder: maxSortOrder + 1, updatedAt: now),
        );
      } else {
        final note = allNotes.firstWhere((n) => n.id == draggedItem.id);
        await ref.read(noteListProvider.notifier).updateNote(
          note.copyWith(sortOrder: maxSortOrder + 1, updatedAt: now),
        );
      }
      return;
    }

    // 对于 before 和 after，重新对 destParentId 下的可排列表排序
    final allNotes = ref.read(noteListProvider).value ?? [];
    final refreshedFolders = ref.read(folderListProvider).value ?? [];

    final isPinnedSort = !draggedItem.isFolder && draggedItem.note!.isPinned && 
                         !targetItem.isFolder && targetItem.note!.isPinned;

    if (isPinnedSort) {
      final siblingPinnedNotes = allNotes
          .where((n) => n.folderId == destParentId && n.isPinned && n.id != draggedItem.id)
          .toList();

      int targetIndex = siblingPinnedNotes.indexWhere((n) => n.id == targetItem.id);
      if (targetIndex == -1) {
        siblingPinnedNotes.add(allNotes.firstWhere((n) => n.id == draggedItem.id));
      } else {
        final draggedNote = allNotes.firstWhere((n) => n.id == draggedItem.id);
        if (dropPosition == 'before') {
          siblingPinnedNotes.insert(targetIndex, draggedNote);
        } else {
          siblingPinnedNotes.insert(targetIndex + 1, draggedNote);
        }
      }

      final updatedNotes = <Note>[];
      for (int i = 0; i < siblingPinnedNotes.length; i++) {
        updatedNotes.add(siblingPinnedNotes[i].copyWith(sortOrder: i, updatedAt: now));
      }
      await ref.read(noteListProvider.notifier).reorderNotes(updatedNotes);
    } else {
      final siblings = [
        ...refreshedFolders.where((f) => f.parentId == destParentId && f.id != draggedItem.id),
        ...allNotes.where((n) => n.folderId == destParentId && !n.isPinned && n.id != draggedItem.id),
      ];

      siblings.sort((a, b) {
        final aOrder = a is Note ? a.sortOrder : (a as Folder).sortOrder;
        final bOrder = b is Note ? b.sortOrder : (b as Folder).sortOrder;
        if (aOrder != bOrder) {
          return aOrder.compareTo(bOrder);
        }
        if (a is Note && b is Note) {
          return b.createdAt.compareTo(a.createdAt);
        } else if (a is Folder && b is Folder) {
          return a.name.compareTo(b.name);
        } else {
          return a is Folder ? -1 : 1;
        }
      });

      int targetIndex = siblings.indexWhere((item) {
        if (item is Folder) return item.id == targetItem.id;
        if (item is Note) return item.id == targetItem.id;
        return false;
      });

      dynamic draggedObject;
      if (draggedItem.isFolder) {
        draggedObject = refreshedFolders.firstWhere((f) => f.id == draggedItem.id);
      } else {
        draggedObject = allNotes.firstWhere((n) => n.id == draggedItem.id);
      }

      if (targetIndex == -1) {
        siblings.add(draggedObject);
      } else {
        if (dropPosition == 'before') {
          siblings.insert(targetIndex, draggedObject);
        } else {
          siblings.insert(targetIndex + 1, draggedObject);
        }
      }

      final updatedNotes = <Note>[];
      final updatedFolders = <Folder>[];
      for (int i = 0; i < siblings.length; i++) {
        final item = siblings[i];
        if (item is Note) {
          updatedNotes.add(item.copyWith(sortOrder: i, updatedAt: now));
        } else if (item is Folder) {
          updatedFolders.add(item.copyWith(sortOrder: i, updatedAt: now));
        }
      }

      if (updatedNotes.isNotEmpty) {
        await ref.read(noteListProvider.notifier).reorderNotes(updatedNotes);
      }
      if (updatedFolders.isNotEmpty) {
        await ref.read(folderListProvider.notifier).reorderFolders(updatedFolders);
      }
    }
  }

  Widget _buildTree(
    BuildContext context,
    List<Folder> folders,
    List<Note> notes,
  ) {
    if (folders.isEmpty && notes.isEmpty) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          EmptyStateWidget(icon: Icons.note_outlined, message: '暂无笔记'),
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
      );
    }

    final flattenedItems = _flattenTree(null, 0, folders, notes);
    final theme = Theme.of(context);

    return DragTarget<FlattenedItem>(
      onWillAcceptWithDetails: (details) {
        return details.data.parentId != null;
      },
      onAcceptWithDetails: (details) async {
        final now = DateTime.now();
        final draggedItem = details.data;
        if (draggedItem.isFolder) {
          final folder = folders.firstWhere((f) => f.id == draggedItem.id);
          await ref.read(folderListProvider.notifier).updateFolder(
            folder.copyWith(parentId: null, updatedAt: now),
          );
        } else {
          final note = notes.firstWhere((n) => n.id == draggedItem.id);
          await ref.read(noteListProvider.notifier).updateNote(
            note.copyWith(folderId: null, updatedAt: now),
          );
        }
      },
      builder: (context, candidateData, rejectedData) {
        final isHoveringRoot = candidateData.isNotEmpty;

        return Stack(
          children: [
            ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 120),
              itemCount: flattenedItems.length,
              itemBuilder: (context, index) {
                final item = flattenedItems[index];
                return _FlattenedTile(
                  key: ValueKey('${item.isFolder ? 'folder' : 'note'}_${item.id}'),
                  item: item,
                  index: index,
                  isSelectionMode: _isSelectionMode,
                  isSelected: item.isFolder
                      ? _selectedFolderIds.contains(item.id)
                      : _selectedNoteIds.contains(item.id),
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
                  onEnterSelectionMode: () {
                    setState(() {
                      _isSelectionMode = true;
                      if (item.isFolder) {
                        _selectedFolderIds.add(item.id);
                      } else {
                        _selectedNoteIds.add(item.id);
                      }
                    });
                  },
                  onEditNote: _editNote,
                  onShowNoteMenu: _showNoteMenu,
                  onToggleFolder: _toggleFolder,
                  onShowFolderMenu: _showFolderMenu,
                  onCreateNote: _createNote,
                  onCreateFolder: _showCreateFolderDialog,
                  onDrop: _handleDrop,
                );
              },
            ),
            if (isHoveringRoot)
              Positioned.fill(
                child: IgnorePointer(
                  child: Container(
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: theme.colorScheme.primary.withValues(alpha: 0.5),
                        width: 2,
                      ),
                      color: theme.colorScheme.primary.withValues(alpha: 0.05),
                    ),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primaryContainer,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '释放以移至根目录',
                          style: TextStyle(
                            color: theme.colorScheme.onPrimaryContainer,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _editNote(Note note) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => NoteEditorView(note: note)));
  }

  void _toggleFolder(Folder folder) {
    ref
        .read(folderListProvider.notifier)
        .toggleExpanded(folder.id, !folder.isExpanded);
  }

  void _showMoveToFolderDialog(BuildContext context, {Note? note, Folder? folder}) {
    assert(note != null || folder != null);
    final isFolder = folder != null;
    final title = isFolder ? '移动文件夹 "${folder!.name}"' : '移动笔记 "${note!.title}"';

    final folderListAsync = ref.read(folderListProvider);
    final allFolders = folderListAsync.value ?? [];

    final invalidIds = <String>{};
    if (isFolder) {
      invalidIds.add(folder!.id);
      void addDescendants(String parentId) {
        for (final f in allFolders) {
          if (f.parentId == parentId) {
            invalidIds.add(f.id);
            addDescendants(f.id);
          }
        }
      }
      addDescendants(folder!.id);
    }

    final flattened = <Map<String, dynamic>>[];
    void traverse(String? parentId, int depth) {
      final children = allFolders.where((f) => f.parentId == parentId).toList()
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
      for (final child in children) {
        flattened.add({'folder': child, 'depth': depth});
        traverse(child.id, depth + 1);
      }
    }
    traverse(null, 0);

    final theme = Theme.of(context);

    showDialog(
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
                  color: (isFolder ? folder!.parentId == null : note!.folderId == null)
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
                title: Text(
                  '根目录',
                  style: TextStyle(
                    fontWeight: (isFolder ? folder!.parentId == null : note!.folderId == null)
                        ? FontWeight.bold
                        : FontWeight.normal,
                  ),
                ),
                onTap: () {
                  if (isFolder) {
                    ref.read(folderListProvider.notifier).moveFolderToParent(folder!.id, null);
                  } else {
                    ref.read(noteListProvider.notifier).moveNoteToFolder(note!.id, null);
                  }
                  Navigator.pop(ctx);
                },
              ),
              const Divider(),
              ...flattened.map((item) {
                final Folder f = item['folder'];
                final int depth = item['depth'];
                final isInvalid = invalidIds.contains(f.id);
                final isCurrentParent = isFolder ? folder!.parentId == f.id : note!.folderId == f.id;

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
                    if (isFolder) {
                      ref.read(folderListProvider.notifier).moveFolderToParent(folder!.id, f.id);
                    } else {
                      ref.read(noteListProvider.notifier).moveNoteToFolder(note!.id, f.id);
                    }
                    Navigator.pop(ctx);
                  },
                );
              }),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  void _showNoteMenu(Note note, GlobalKey key) {
    ActionMenu.show(
      context: context,
      key: key,
      items: [
        ActionMenuItem(
          icon: Icons.edit_outlined,
          label: '编辑笔记',
          onTap: () => _editNote(note),
        ),
        ActionMenuItem(
          icon: Icons.drive_file_move_outlined,
          label: '移动到文件夹',
          onTap: () => _showMoveToFolderDialog(context, note: note),
        ),
        ActionMenuItem(icon: Icons.share_outlined, label: '分享笔记', onTap: () {}),
        ActionMenuItem(
          icon: Icons.delete_outline,
          label: '删除笔记',
          isDestructive: true,
          onTap: () => ref.read(noteListProvider.notifier).deleteNote(note.id),
        ),
      ],
    );
  }

  void _showFolderMenu(Folder folder, GlobalKey key) {
    ActionMenu.show(
      context: context,
      key: key,
      items: [
        ActionMenuItem(
          icon: Icons.edit_outlined,
          label: '重命名文件夹',
          onTap: () => _renameFolder(folder),
        ),
        ActionMenuItem(
          icon: Icons.create_new_folder_outlined,
          label: '新建子文件夹',
          onTap: () => _showCreateFolderDialog(folder.id),
        ),
        ActionMenuItem(
          icon: Icons.add,
          label: '新建笔记',
          onTap: () => _createNote(folder.id),
        ),
        ActionMenuItem(
          icon: Icons.drive_file_move_outlined,
          label: '移动文件夹',
          onTap: () => _showMoveToFolderDialog(context, folder: folder),
        ),
        ActionMenuItem(
          icon: Icons.delete_outline,
          label: '删除文件夹',
          isDestructive: true,
          onTap: () =>
              ref.read(folderListProvider.notifier).deleteFolder(folder.id),
        ),
      ],
    );
  }

  void _renameFolder(Folder folder) {
    final controller = TextEditingController(text: folder.name);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '文件夹名称'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                ref
                    .read(folderListProvider.notifier)
                    .updateFolder(folder.copyWith(name: controller.text));
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

class FlattenedItem {
  final String id;
  final bool isFolder;
  final Note? note;
  final Folder? folder;
  final int depth;
  final String? parentId;
  final bool isPinned;

  FlattenedItem({
    required this.id,
    required this.isFolder,
    this.note,
    this.folder,
    required this.depth,
    this.parentId,
    required this.isPinned,
  });
}

class _FlattenedTile extends ConsumerStatefulWidget {
  final FlattenedItem item;
  final int index;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onToggleSelection;
  final VoidCallback onEnterSelectionMode;
  final void Function(Note) onEditNote;
  final void Function(Note, GlobalKey) onShowNoteMenu;
  final void Function(Folder) onToggleFolder;
  final void Function(Folder, GlobalKey) onShowFolderMenu;
  final void Function(String?) onCreateNote;
  final void Function(String?) onCreateFolder;
  final Future<void> Function({
    required FlattenedItem draggedItem,
    required FlattenedItem targetItem,
    required String dropPosition,
  }) onDrop;

  const _FlattenedTile({
    super.key,
    required this.item,
    required this.index,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
    required this.onEditNote,
    required this.onShowNoteMenu,
    required this.onToggleFolder,
    required this.onShowFolderMenu,
    required this.onCreateNote,
    required this.onCreateFolder,
    required this.onDrop,
  });

  @override
  ConsumerState<_FlattenedTile> createState() => _FlattenedTileState();
}

class _FlattenedTileState extends ConsumerState<_FlattenedTile> {
  final _menuKey = GlobalKey();
  String? _hoverPosition; // 'before' | 'inside' | 'after' | null

  void _setHoverPosition(String? position) {
    if (_hoverPosition != position) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _hoverPosition = position;
          });
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFolder = widget.item.isFolder;

    Widget tileContent = Container(
      padding: EdgeInsets.only(
        left: 12.0 + widget.item.depth * 16.0,
        right: 12,
        top: isFolder ? 6 : 4,
        bottom: isFolder ? 6 : 4,
      ),
      color: _hoverPosition == 'inside'
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
          : Colors.transparent,
      child: Row(
        children: [
          if (widget.isSelectionMode)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: widget.isSelected,
                  onChanged: (_) => widget.onToggleSelection(),
                  activeColor: theme.colorScheme.primary,
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(
                Icons.drag_indicator,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: widget.item.isPinned ? 0.1 : 0.35,
                ),
              ),
            ),

          if (isFolder)
            GestureDetector(
              onTap: () => widget.onToggleFolder(widget.item.folder!),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(
                  widget.item.folder!.isExpanded
                      ? Icons.keyboard_arrow_down
                      : Icons.keyboard_arrow_right,
                  size: 16,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                ),
              ),
            )
          else
            const SizedBox(width: 8),

          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(
                alpha: isFolder ? 0.08 : 0.1,
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(
              isFolder
                  ? (widget.item.folder!.isExpanded ? Icons.folder_open : Icons.folder)
                  : Icons.description,
              size: 18,
              color: theme.colorScheme.primary,
            ),
          ),
          const SizedBox(width: 12),

          if (!isFolder && widget.item.isPinned) ...[
            Icon(
              Icons.push_pin,
              size: 14,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 4),
          ],

          Expanded(
            child: GestureDetector(
              onTap: widget.isSelectionMode
                  ? widget.onToggleSelection
                  : (isFolder
                      ? () => widget.onToggleFolder(widget.item.folder!)
                      : () => widget.onEditNote(widget.item.note!)),
              onLongPress: widget.isSelectionMode ? null : widget.onEnterSelectionMode,
              behavior: HitTestBehavior.opaque,
              child: Text(
                isFolder ? widget.item.folder!.name : widget.item.note!.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: isFolder ? FontWeight.bold : FontWeight.w500,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),

          if (!widget.isSelectionMode) ...[
            const SizedBox(width: 4),
            SizedBox(
              key: _menuKey,
              width: 32,
              height: 32,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 20,
                icon: Icon(
                  Icons.more_vert,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.5,
                  ),
                ),
                onPressed: () => isFolder
                    ? widget.onShowFolderMenu(widget.item.folder!, _menuKey)
                    : widget.onShowNoteMenu(widget.item.note!, _menuKey),
              ),
            ),
          ],
        ],
      ),
    );

    Widget tileWithDraggable = LongPressDraggable<FlattenedItem>(
      data: widget.item,
      maxSimultaneousDrags: widget.isSelectionMode ? 0 : 1,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: MediaQuery.of(context).size.width - 32,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(12),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isFolder ? Icons.folder : Icons.description,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 12),
              Text(
                isFolder ? widget.item.folder!.name : widget.item.note!.title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: tileContent,
      ),
      child: tileContent,
    );

    return Stack(
      children: [
        tileWithDraggable,

        if (_hoverPosition == 'before')
          Positioned(
            top: 0,
            left: 12.0 + widget.item.depth * 16.0,
            right: 12,
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        if (_hoverPosition == 'after')
          Positioned(
            bottom: 0,
            left: 12.0 + widget.item.depth * 16.0,
            right: 12,
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),

        Positioned.fill(
          child: Column(
            children: [
              Expanded(
                flex: 1,
                child: DragTarget<FlattenedItem>(
                  onWillAcceptWithDetails: (details) {
                    if (details.data.id == widget.item.id) return false;
                    _setHoverPosition('before');
                    return true;
                  },
                  onLeave: (data) => _setHoverPosition(null),
                  onAcceptWithDetails: (details) {
                    _setHoverPosition(null);
                    widget.onDrop(
                      draggedItem: details.data,
                      targetItem: widget.item,
                      dropPosition: 'before',
                    );
                  },
                  builder: (context, candidateData, rejectedData) => const SizedBox.expand(),
                ),
              ),

              if (isFolder)
                Expanded(
                  flex: 2,
                  child: DragTarget<FlattenedItem>(
                    onWillAcceptWithDetails: (details) {
                      if (details.data.id == widget.item.id) return false;
                      if (details.data.isFolder) {
                        final allFolders = ref.read(folderListProvider).value ?? [];
                        if (_checkIsDescendant(widget.item.id, details.data.id, allFolders)) {
                          return false;
                        }
                      }
                      _setHoverPosition('inside');
                      return true;
                    },
                    onLeave: (data) => _setHoverPosition(null),
                    onAcceptWithDetails: (details) {
                      _setHoverPosition(null);
                      widget.onDrop(
                        draggedItem: details.data,
                        targetItem: widget.item,
                        dropPosition: 'inside',
                      );
                    },
                    builder: (context, candidateData, rejectedData) => const SizedBox.expand(),
                  ),
                )
              else
                const SizedBox.shrink(),

              Expanded(
                flex: 1,
                child: DragTarget<FlattenedItem>(
                  onWillAcceptWithDetails: (details) {
                    if (details.data.id == widget.item.id) return false;
                    _setHoverPosition('after');
                    return true;
                  },
                  onLeave: (data) => _setHoverPosition(null),
                  onAcceptWithDetails: (details) {
                    _setHoverPosition(null);
                    widget.onDrop(
                      draggedItem: details.data,
                      targetItem: widget.item,
                      dropPosition: 'after',
                    );
                  },
                  builder: (context, candidateData, rejectedData) => const SizedBox.expand(),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

bool _checkIsDescendant(String? parentId, String folderId, List<Folder> allFolders) {
  if (parentId == null) return false;
  if (parentId == folderId) return true;
  final parentFolder = allFolders.where((f) => f.id == parentId).firstOrNull;
  if (parentFolder == null) return false;
  return _checkIsDescendant(parentFolder.parentId, folderId, allFolders);
}

