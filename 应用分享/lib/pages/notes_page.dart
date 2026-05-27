import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/providers/navigation_provider.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';

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
                  elevation: 4,
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
                    color: Colors.black.withValues(alpha: 0.05),
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
                              ? Colors.amber.shade700
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

  Widget _buildTree(
    BuildContext context,
    List<Folder> folders,
    List<Note> notes,
  ) {
    if (folders.isEmpty && notes.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.note_add_outlined,
              size: 64,
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
            const SizedBox(height: 16),
            Text(
              '暂无笔记',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
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
      );
    }

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.only(bottom: 120),
      child: _SortableLevel(
        folders: folders,
        notes: notes,
        parentId: null,
        depth: 0,
        onEditNote: (note) => _editNote(note),
        onShowNoteMenu: (note, key) => _showNoteMenu(note, key),
        onToggleFolder: (folder) => _toggleFolder(folder),
        onShowFolderMenu: (folder, key) => _showFolderMenu(folder, key),
        onCreateNote: (folderId) => _createNote(folderId),
        onCreateFolder: (parentId) => _showCreateFolderDialog(parentId),
        isSelectionMode: _isSelectionMode,
        selectedNoteIds: _selectedNoteIds,
        selectedFolderIds: _selectedFolderIds,
        onToggleNoteSelection: (note) {
          setState(() {
            if (_selectedNoteIds.contains(note.id)) {
              _selectedNoteIds.remove(note.id);
            } else {
              _selectedNoteIds.add(note.id);
            }
            if (_selectedNoteIds.isEmpty && _selectedFolderIds.isEmpty) {
              _isSelectionMode = false;
            }
          });
        },
        onToggleFolderSelection: (folder) {
          setState(() {
            if (_selectedFolderIds.contains(folder.id)) {
              _selectedFolderIds.remove(folder.id);
            } else {
              _selectedFolderIds.add(folder.id);
            }
            if (_selectedNoteIds.isEmpty && _selectedFolderIds.isEmpty) {
              _isSelectionMode = false;
            }
          });
        },
        onEnterSelectionMode: (item, type) {
          setState(() {
            _isSelectionMode = true;
            if (type == 'note') {
              _selectedNoteIds.add(item.id);
            } else if (type == 'folder') {
              _selectedFolderIds.add(item.id);
            }
          });
        },
      ),
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
                            ? Colors.orange
                            : Colors.orange.withValues(alpha: 0.5)),
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

class _SortableLevel extends StatefulWidget {
  final List<Folder> folders;
  final List<Note> notes;
  final String? parentId;
  final int depth;
  final void Function(Note) onEditNote;
  final void Function(Note, GlobalKey) onShowNoteMenu;
  final void Function(Folder) onToggleFolder;
  final void Function(Folder, GlobalKey) onShowFolderMenu;
  final void Function(String?) onCreateNote;
  final void Function(String?) onCreateFolder;
  final bool isSelectionMode;
  final Set<String> selectedNoteIds;
  final Set<String> selectedFolderIds;
  final void Function(Note) onToggleNoteSelection;
  final void Function(Folder) onToggleFolderSelection;
  final void Function(dynamic item, String type) onEnterSelectionMode;

  const _SortableLevel({
    required this.folders,
    required this.notes,
    required this.parentId,
    required this.depth,
    required this.onEditNote,
    required this.onShowNoteMenu,
    required this.onToggleFolder,
    required this.onShowFolderMenu,
    required this.onCreateNote,
    required this.onCreateFolder,
    required this.isSelectionMode,
    required this.selectedNoteIds,
    required this.selectedFolderIds,
    required this.onToggleNoteSelection,
    required this.onToggleFolderSelection,
    required this.onEnterSelectionMode,
  });

  @override
  State<_SortableLevel> createState() => _SortableLevelState();
}

class _SortableLevelState extends State<_SortableLevel> {
  @override
  Widget build(BuildContext context) {
    final childFolders = widget.folders
        .where((f) => f.parentId == widget.parentId)
        .toList();
    final childNotes = widget.notes
        .where((n) => n.folderId == widget.parentId)
        .toList();

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

    final List<dynamic> combined = [...pinnedNotes, ...sortableItems];

    if (combined.isEmpty && widget.parentId == null) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);

    return Container(
      margin: EdgeInsets.symmetric(
        vertical: 2,
        horizontal: widget.depth == 0 ? 8 : 0,
      ),
      padding: const EdgeInsets.symmetric(vertical: 0),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (combined.isEmpty && widget.parentId != null)
            Padding(
              padding: EdgeInsets.only(
                left: 16.0 + widget.depth * 8.0,
                top: 8,
                bottom: 8,
              ),
              child: Text(
                '  空文件夹',
                style: TextStyle(color: theme.colorScheme.outlineVariant),
              ),
            ),
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: combined.length,
            onReorder: (oldIndex, newIndex) {
              if (newIndex > oldIndex) newIndex -= 1;

              final pinnedCount = pinnedNotes.length;
              if (oldIndex < pinnedCount || newIndex < pinnedCount) {
                return;
              }

              final oldSortableIndex = oldIndex - pinnedCount;
              final newSortableIndex = newIndex - pinnedCount;

              setState(() {
                final item = sortableItems.removeAt(oldSortableIndex);
                sortableItems.insert(newSortableIndex, item);
              });

              final now = DateTime.now();
              final updatedNotes = <Note>[];
              final updatedFolders = <Folder>[];

              for (int i = 0; i < sortableItems.length; i++) {
                final item = sortableItems[i];
                if (item is Note) {
                  updatedNotes.add(item.copyWith(sortOrder: i, updatedAt: now));
                } else if (item is Folder) {
                  updatedFolders.add(item.copyWith(sortOrder: i, updatedAt: now));
                }
              }

              if (updatedNotes.isNotEmpty) {
                final container = ProviderScope.containerOf(context, listen: false);
                container.read(noteListProvider.notifier).reorderNotes(updatedNotes);
              }
              if (updatedFolders.isNotEmpty) {
                final container = ProviderScope.containerOf(context, listen: false);
                container.read(folderListProvider.notifier).reorderFolders(updatedFolders);
              }
            },
            itemBuilder: (context, index) {
              final item = combined[index];
              if (item is Note) {
                return _NoteTile(
                  key: ValueKey('note_${item.id}'),
                  note: item,
                  depth: widget.depth,
                  index: index,
                  onEdit: () => widget.onEditNote(item),
                  onMenu: (key) => widget.onShowNoteMenu(item, key),
                  isSelectionMode: widget.isSelectionMode,
                  isSelected: widget.selectedNoteIds.contains(item.id),
                  onToggleSelection: () => widget.onToggleNoteSelection(item),
                  onEnterSelectionMode: () => widget.onEnterSelectionMode(item, 'note'),
                );
              } else {
                final folder = item as Folder;
                return _FolderTile(
                  key: ValueKey('folder_${folder.id}'),
                  folder: folder,
                  depth: widget.depth,
                  index: index,
                  onToggle: () => widget.onToggleFolder(folder),
                  onMenu: (key) => widget.onShowFolderMenu(folder, key),
                  onBuildChildLevel: ({required int depth}) => _SortableLevel(
                    folders: widget.folders,
                    notes: widget.notes,
                    parentId: folder.id,
                    depth: depth,
                    onEditNote: widget.onEditNote,
                    onShowNoteMenu: widget.onShowNoteMenu,
                    onToggleFolder: widget.onToggleFolder,
                    onShowFolderMenu: widget.onShowFolderMenu,
                    onCreateNote: widget.onCreateNote,
                    onCreateFolder: widget.onCreateFolder,
                    isSelectionMode: widget.isSelectionMode,
                    selectedNoteIds: widget.selectedNoteIds,
                    selectedFolderIds: widget.selectedFolderIds,
                    onToggleNoteSelection: widget.onToggleNoteSelection,
                    onToggleFolderSelection: widget.onToggleFolderSelection,
                    onEnterSelectionMode: widget.onEnterSelectionMode,
                  ),
                  onCreateNote: () => widget.onCreateNote(folder.id),
                  onCreateFolder: () => widget.onCreateFolder(folder.id),
                  isSelectionMode: widget.isSelectionMode,
                  isSelected: widget.selectedFolderIds.contains(folder.id),
                  onToggleSelection: () => widget.onToggleFolderSelection(folder),
                  onEnterSelectionMode: () => widget.onEnterSelectionMode(folder, 'folder'),
                );
              }
            },
          ),
        ],
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  final Note note;
  final int depth;
  final int index;
  final VoidCallback onEdit;
  final void Function(GlobalKey key) onMenu;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onToggleSelection;
  final VoidCallback onEnterSelectionMode;

  const _NoteTile({
    super.key,
    required this.note,
    required this.depth,
    required this.index,
    required this.onEdit,
    required this.onMenu,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final menuKey = GlobalKey();

    return Container(
      padding: EdgeInsets.only(
        left: 16.0 + depth * 8.0,
        right: 12,
        top: 6,
        bottom: 6,
      ),
      child: Row(
        children: [
          if (isSelectionMode)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: isSelected,
                  onChanged: (_) => onToggleSelection(),
                  activeColor: theme.colorScheme.primary,
                ),
              ),
            )
          else if (note.isPinned)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(
                Icons.drag_indicator,
                size: 18,
                color: theme.colorScheme.onSurfaceVariant.withValues(
                  alpha: 0.1,
                ),
              ),
            )
          else
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.drag_indicator,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant.withValues(
                    alpha: 0.35,
                  ),
                ),
              ),
            ),
          Expanded(
            child: GestureDetector(
              onTap: isSelectionMode ? onToggleSelection : onEdit,
              onLongPress: isSelectionMode ? null : onEnterSelectionMode,
              behavior: HitTestBehavior.opaque,
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.description,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (note.isPinned) ...[
                    Icon(
                      Icons.push_pin,
                      size: 14,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      note.title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (!isSelectionMode) ...[
            const SizedBox(width: 4),
            SizedBox(
              key: menuKey,
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
                onPressed: () => onMenu(menuKey),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  final Folder folder;
  final int depth;
  final int index;
  final VoidCallback onToggle;
  final void Function(GlobalKey key) onMenu;
  final Widget Function({required int depth}) onBuildChildLevel;
  final VoidCallback onCreateNote;
  final VoidCallback onCreateFolder;
  final bool isSelectionMode;
  final bool isSelected;
  final VoidCallback onToggleSelection;
  final VoidCallback onEnterSelectionMode;

  const _FolderTile({
    super.key,
    required this.folder,
    required this.depth,
    required this.index,
    required this.onToggle,
    required this.onMenu,
    required this.onBuildChildLevel,
    required this.onCreateNote,
    required this.onCreateFolder,
    required this.isSelectionMode,
    required this.isSelected,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final menuKey = GlobalKey();

    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      decoration: BoxDecoration(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.transparent,
          width: 1.5,
        ),
      ),
      margin: const EdgeInsets.symmetric(vertical: 1, horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            decoration: BoxDecoration(
              color: Colors.transparent,
              borderRadius: BorderRadius.circular(12),
            ),
            child: GestureDetector(
              onTap: isSelectionMode ? onToggleSelection : onToggle,
              onLongPress: isSelectionMode ? null : onEnterSelectionMode,
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: EdgeInsets.only(
                  left: 12.0 + depth * 8.0,
                  right: 12,
                  top: 8,
                  bottom: 4,
                ),
                child: Row(
                  children: [
                    if (isSelectionMode)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: isSelected,
                            onChanged: (_) => onToggleSelection(),
                            activeColor: Colors.orange,
                          ),
                        ),
                      )
                    else
                      ReorderableDragStartListener(
                        index: index,
                        child: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Icon(
                            Icons.drag_indicator,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.35),
                          ),
                        ),
                      ),
                    GestureDetector(
                      onTap: onToggle,
                      behavior: HitTestBehavior.opaque,
                      child: SizedBox(
                        width: 32,
                        height: 32,
                        child: Icon(
                          folder.isExpanded
                              ? Icons.keyboard_arrow_down
                              : Icons.keyboard_arrow_right,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        folder.isExpanded
                            ? Icons.folder_open
                            : Icons.folder,
                        size: 18,
                        color: Colors.orange,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        folder.name,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!isSelectionMode) ...[
                      const SizedBox(width: 4),
                      SizedBox(
                        key: menuKey,
                        width: 32,
                        height: 32,
                        child: IconButton(
                          padding: EdgeInsets.zero,
                          iconSize: 20,
                          icon: Icon(
                            Icons.more_vert,
                            color: theme.colorScheme.onSurfaceVariant
                                .withValues(alpha: 0.5),
                          ),
                          onPressed: () => onMenu(menuKey),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (folder.isExpanded)
            onBuildChildLevel(
              depth: depth + 1,
            ),
        ],
      ),
    );
  }
}

