import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/folder.dart';
import 'package:qnote_flutter/providers/note_provider.dart';
import 'package:qnote_flutter/providers/folder_provider.dart';
import 'package:qnote_flutter/widgets/action_menu.dart';
import 'package:qnote_flutter/widgets/search_view.dart';
import 'package:qnote_flutter/widgets/side_drawer.dart';
import 'package:qnote_flutter/widgets/notes/note_editor_view.dart';

class _DragData {
  final dynamic item;
  final String type;
  _DragData(this.item, this.type);
}

class NotesPage extends ConsumerStatefulWidget {
  const NotesPage({super.key});

  @override
  ConsumerState<NotesPage> createState() => _NotesPageState();
}

class _NotesPageState extends ConsumerState<NotesPage> {
  @override
  Widget build(BuildContext context) {
    final noteListAsync = ref.watch(noteListProvider);
    final folderListAsync = ref.watch(folderListProvider);

    return Scaffold(
      drawer: const SideDrawer(),
      appBar: AppBar(
        leading: Builder(
          builder: (context) => IconButton(
            icon: const Icon(Icons.menu),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
        ),
        title: const Text('笔记'),
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: '搜索',
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SearchView()),
              );
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
      floatingActionButton: Column(
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
            elevation: 4,
            onPressed: () => _createNote(),
            child: const Icon(Icons.add, size: 28),
          ),
        ],
      ),
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
    final note = await ref.read(noteListProvider.notifier).addNote(
          title: '新笔记',
          folderId: folderId,
        );
    if (mounted) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => NoteEditorView(note: note),
        ),
      );
    }
  }

  Widget _buildTree(BuildContext context, List<Folder> folders, List<Note> notes) {
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
      padding: const EdgeInsets.only(bottom: 80),
      child: _SortableLevel(
        folders: folders,
        notes: notes,
        parentId: null,
        depth: 0,
        onMoveNoteToFolder: (noteId, folderId) {
          ref.read(noteListProvider.notifier).moveNoteToFolder(noteId, folderId);
        },
        onMoveFolderToParent: (folderId, newParentId) {
          ref.read(folderListProvider.notifier).moveFolderToParent(folderId, newParentId);
        },
        onEditNote: (note) => _editNote(note),
        onShowNoteMenu: (note, key) => _showNoteMenu(note, key),
        onToggleFolder: (folder) => _toggleFolder(folder),
        onShowFolderMenu: (folder, key) => _showFolderMenu(folder, key),
        onCreateNote: (folderId) => _createNote(folderId),
        onCreateFolder: (parentId) => _showCreateFolderDialog(parentId),
      ),
    );
  }

  void _editNote(Note note) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => NoteEditorView(note: note),
      ),
    );
  }

  void _toggleFolder(Folder folder) {
      ref
          .read(folderListProvider.notifier)
          .toggleExpanded(folder.id, !folder.isExpanded);
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
          icon: Icons.share_outlined,
          label: '分享笔记',
          onTap: () {},
        ),
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
                ref.read(folderListProvider.notifier).updateFolder(
                      folder.copyWith(name: controller.text),
                    );
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
  final void Function(String noteId, String? folderId) onMoveNoteToFolder;
  final void Function(String folderId, String? newParentId) onMoveFolderToParent;
  final void Function(Note) onEditNote;
  final void Function(Note, GlobalKey) onShowNoteMenu;
  final void Function(Folder) onToggleFolder;
  final void Function(Folder, GlobalKey) onShowFolderMenu;
  final void Function(String?) onCreateNote;
  final void Function(String?) onCreateFolder;

  const _SortableLevel({
    required this.folders,
    required this.notes,
    required this.parentId,
    required this.depth,
    required this.onMoveNoteToFolder,
    required this.onMoveFolderToParent,
    required this.onEditNote,
    required this.onShowNoteMenu,
    required this.onToggleFolder,
    required this.onShowFolderMenu,
    required this.onCreateNote,
    required this.onCreateFolder,
  });

  @override
  State<_SortableLevel> createState() => _SortableLevelState();
}

class _SortableLevelState extends State<_SortableLevel> {
  int? _dragOverIndex;
  bool _isHovering = false;

  void _updateDragIndex(Offset globalPosition, int totalItems) {
    if (!mounted) return;
    final RenderBox? box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final localPosition = box.globalToLocal(globalPosition);
    int index = (localPosition.dy / 44).floor();
    if (index < 0) index = 0;
    if (index > totalItems) index = totalItems;
    if (_dragOverIndex != index) {
      setState(() => _dragOverIndex = index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final childFolders = widget.folders.where((f) => f.parentId == widget.parentId).toList();
    final childNotes = widget.notes.where((n) => n.folderId == widget.parentId).toList();

    final List<dynamic> combined = [...childNotes, ...childFolders];

    if (combined.isEmpty && widget.parentId == null) return const SizedBox.shrink();

    return DragTarget<_DragData>(
      onWillAcceptWithDetails: (details) {
        final d = details.data;
        if (d.type == 'note' && (d.item as Note).folderId == widget.parentId) {
           // Allow for visual reordering
        } else if (d.type == 'folder') {
          final source = d.item as Folder;
          if (source.id == widget.parentId) return false;
          var currentId = widget.parentId;
          while (currentId != null) {
            if (currentId == source.id) return false;
            final parent = widget.folders.where((f) => f.id == currentId).firstOrNull;
            currentId = parent?.parentId;
          }
        }
        setState(() => _isHovering = true);
        _updateDragIndex(details.offset, combined.length);
        return true;
      },
      onMove: (details) {
        _updateDragIndex(details.offset, combined.length);
      },
      onLeave: (_) {
        setState(() {
          _isHovering = false;
          _dragOverIndex = null;
        });
      },
      onAcceptWithDetails: (details) {
        setState(() {
          _isHovering = false;
          _dragOverIndex = null;
        });
        final d = details.data;
        if (d.type == 'note') {
          widget.onMoveNoteToFolder((d.item as Note).id, widget.parentId);
        } else if (d.type == 'folder') {
          widget.onMoveFolderToParent((d.item as Folder).id, widget.parentId);
        }
      },
      builder: (context, candidateData, rejectedData) {
        final theme = Theme.of(context);
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: _isHovering ? theme.colorScheme.primary.withValues(alpha: 0.1) : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
            border: _isHovering 
                ? Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.3), width: 2)
                : Border.all(color: Colors.transparent, width: 2),
          ),
          margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 8),
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (combined.isEmpty && widget.parentId != null)
                Padding(
                  padding: EdgeInsets.only(left: 16.0 + widget.depth * 12.0, top: 8, bottom: 8),
                  child: Text('  空文件夹', style: TextStyle(color: theme.colorScheme.outlineVariant)),
                ),
              ...combined.asMap().entries.map((entry) {
                final index = entry.key;
                final item = entry.value;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isHovering && _dragOverIndex == index)
                      _DropGapPlaceholder(),
                    if (item is Note)
                      _NoteTile(
                        key: ValueKey('note_${item.id}'),
                        note: item,
                        depth: widget.depth,
                        isDragging: false,
                        onDragStarted: () {},
                        onEdit: () => widget.onEditNote(item),
                        onMenu: (key) => widget.onShowNoteMenu(item, key),
                        onDragUpdate: (_) {},
                        onDragEnd: () {},
                      )
                    else
                      _FolderTile(
                        key: ValueKey('folder_${(item as Folder).id}'),
                        folder: item as Folder,
                        depth: widget.depth,
                        folders: widget.folders,
                        notes: widget.notes,
                        isOver: false,
                        onToggle: () => widget.onToggleFolder(item as Folder),
                        onMenu: (key) => widget.onShowFolderMenu(item as Folder, key),
                        onMoveNoteToFolder: (note) => widget.onMoveNoteToFolder(note.id, (item as Folder).id),
                        onMoveFolderToParent: (sourceId) => widget.onMoveFolderToParent(sourceId, (item as Folder).id),
                        onBuildChildLevel: ({required int depth}) => _SortableLevel(
                          folders: widget.folders,
                          notes: widget.notes,
                          parentId: (item as Folder).id,
                          depth: depth,
                          onMoveNoteToFolder: widget.onMoveNoteToFolder,
                          onMoveFolderToParent: widget.onMoveFolderToParent,
                          onEditNote: widget.onEditNote,
                          onShowNoteMenu: widget.onShowNoteMenu,
                          onToggleFolder: widget.onToggleFolder,
                          onShowFolderMenu: widget.onShowFolderMenu,
                          onCreateNote: widget.onCreateNote,
                          onCreateFolder: widget.onCreateFolder,
                        ),
                        onDragUpdate: (_) {},
                        onDragEnd: () {},
                        onCreateNote: () => widget.onCreateNote((item as Folder).id),
                        onCreateFolder: () => widget.onCreateFolder((item as Folder).id),
                      ),
                    if (index == combined.length - 1 && _isHovering && _dragOverIndex != null && _dragOverIndex! > index)
                      _DropGapPlaceholder(),
                  ],
                );
              }),
            ],
          ),
        );
      },
    );
  }
}

class _DropGapPlaceholder extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      height: 44,
      margin: const EdgeInsets.symmetric(vertical: 2, horizontal: 16),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.3), width: 1),
      ),
    );
  }
}

class _NoteTile extends StatelessWidget {
  final Note note;
  final int depth;
  final bool isDragging;
  final VoidCallback onDragStarted;
  final VoidCallback onEdit;
  final void Function(GlobalKey key) onMenu;
  final void Function(int index) onDragUpdate;
  final VoidCallback onDragEnd;

  const _NoteTile({
    super.key,
    required this.note,
    required this.depth,
    required this.isDragging,
    required this.onDragStarted,
    required this.onEdit,
    required this.onMenu,
    required this.onDragUpdate,
    required this.onDragEnd,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final menuKey = GlobalKey();

    return Opacity(
      opacity: isDragging ? 0.35 : 1.0,
      child: Container(
        padding: EdgeInsets.only(
          left: 16.0 + depth * 12.0,
          right: 12,
          top: 12,
          bottom: 12,
        ),
        child: Row(
          children: [
            _DragHandle<_DragData>(
              data: _DragData(note, 'note'),
              feedbackBuilder: (context) => Material(
                elevation: 4,
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.description, size: 15, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(
                        note.title,
                        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ),
              onDragStarted: onDragStarted,
              onDragEnd: onDragEnd,
              handleChild: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  Icons.drag_indicator,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                onTap: onEdit,
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
                      Icon(Icons.push_pin, size: 14, color: theme.colorScheme.primary),
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
            const SizedBox(width: 4),
            SizedBox(
              key: menuKey,
              width: 32,
              height: 32,
              child: IconButton(
                padding: EdgeInsets.zero,
                iconSize: 20,
                icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                onPressed: () => onMenu(menuKey),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FolderTile extends StatefulWidget {
  final Folder folder;
  final int depth;
  final List<Folder> folders;
  final List<Note> notes;
  final bool isOver;
  final VoidCallback onToggle;
  final void Function(GlobalKey key) onMenu;
  final void Function(Note) onMoveNoteToFolder;
  final void Function(String) onMoveFolderToParent;
  final Widget Function({required int depth}) onBuildChildLevel;
  final void Function(int index) onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onCreateNote;
  final VoidCallback onCreateFolder;

  const _FolderTile({
    super.key,
    required this.folder,
    required this.depth,
    required this.folders,
    required this.notes,
    required this.isOver,
    required this.onToggle,
    required this.onMenu,
    required this.onMoveNoteToFolder,
    required this.onMoveFolderToParent,
    required this.onBuildChildLevel,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onCreateNote,
    required this.onCreateFolder,
  });

  @override
  State<_FolderTile> createState() => _FolderTileState();
}

class _FolderTileState extends State<_FolderTile> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final menuKey = GlobalKey();
    final isHighlight = widget.isOver || _isHovering;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        DragTarget<_DragData>(
          onWillAcceptWithDetails: (details) {
            final d = details.data;
            if (d.type == 'note') {
              if ((d.item as Note).folderId == widget.folder.id) return false;
            } else if (d.type == 'folder') {
              final source = d.item as Folder;
              if (source.id == widget.folder.id) return false;
              var current = widget.folder;
              while (current.parentId != null) {
                if (current.parentId == source.id) return false;
                final parent = widget.folders.where((f) => f.id == current.parentId).firstOrNull;
                if (parent == null) break;
                current = parent;
              }
            }
            setState(() => _isHovering = true);
            return true;
          },
          onLeave: (_) => setState(() => _isHovering = false),
          onAcceptWithDetails: (details) {
            setState(() => _isHovering = false);
            final d = details.data;
            if (d.type == 'note') {
              widget.onMoveNoteToFolder(d.item as Note);
            } else if (d.type == 'folder') {
              widget.onMoveFolderToParent((d.item as Folder).id);
            }
          },
          builder: (context, candidateData, rejectedData) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              decoration: BoxDecoration(
                color: isHighlight ? Colors.orange.withValues(alpha: 0.08) : Colors.transparent,
                borderRadius: BorderRadius.circular(12),
                border: isHighlight
                    ? Border.all(color: Colors.orange.withValues(alpha: 0.3), width: 2)
                    : null,
              ),
              child: Opacity(
                opacity: widget.isOver ? 0.35 : 1.0,
                child: GestureDetector(
                  onTap: widget.onToggle,
                  behavior: HitTestBehavior.opaque,
                  child: Padding(
                    padding: EdgeInsets.only(
                      left: 12.0 + widget.depth * 12.0,
                      right: 12,
                      top: 12,
                      bottom: 12,
                    ),
                    child: Row(
                      children: [
                        _DragHandle<_DragData>(
                          data: _DragData(widget.folder, 'folder'),
                          feedbackBuilder: (ctx) => Material(
                            elevation: 4,
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.surface,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.folder, size: 15, color: Colors.orange),
                                  const SizedBox(width: 6),
                                  Text(
                                    widget.folder.name,
                                    style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.bold),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          onDragStarted: () {},
                          onDragEnd: widget.onDragEnd,
                          handleChild: Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Icon(
                              Icons.drag_indicator,
                              size: 16,
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 20,
                          child: Icon(
                            widget.folder.isExpanded
                                ? Icons.keyboard_arrow_down
                                : Icons.keyboard_arrow_right,
                            size: 16,
                            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
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
                            widget.folder.isExpanded ? Icons.folder_open : Icons.folder,
                            size: 18,
                            color: Colors.orange,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            widget.folder.name,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              letterSpacing: 0.2,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 4),
                        SizedBox(
                          key: menuKey,
                          width: 32,
                          height: 32,
                          child: IconButton(
                            padding: EdgeInsets.zero,
                            iconSize: 20,
                            icon: Icon(Icons.more_vert, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
                            onPressed: () => widget.onMenu(menuKey),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        if (widget.folder.isExpanded) widget.onBuildChildLevel(depth: widget.depth + 1),
      ],
    );
  }
}

class _DragHandle<T extends Object> extends StatefulWidget {
  final T data;
  final Widget Function(BuildContext) feedbackBuilder;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnd;
  final Widget handleChild;

  const _DragHandle({
    required this.data,
    required this.feedbackBuilder,
    required this.onDragStarted,
    required this.onDragEnd,
    required this.handleChild,
  });

  @override
  State<_DragHandle<T>> createState() => _DragHandleState<T>();
}

class _DragHandleState<T extends Object> extends State<_DragHandle<T>> {
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    return Draggable<T>(
      data: widget.data,
      feedback: widget.feedbackBuilder(context),
      childWhenDragging: Opacity(opacity: 0.15, child: widget.handleChild),
      onDragStarted: () {
        setState(() => _isDragging = true);
        widget.onDragStarted();
      },
      onDragEnd: (_) {
        if (_isDragging) {
          setState(() => _isDragging = false);
          widget.onDragEnd();
        }
      },
      onDragCompleted: () {
        if (_isDragging) {
          setState(() => _isDragging = false);
          widget.onDragEnd();
        }
      },
      onDraggableCanceled: (_, __) {
        if (_isDragging) {
          setState(() => _isDragging = false);
          widget.onDragEnd();
        }
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.grab,
        child: widget.handleChild,
      ),
    );
  }
}
