part of 'notes_page.dart';

/// 日记体系节点图标底座色：统一用 EEF736 荧光黄绿，与普通节点的主题色底座区分。
///
/// 该色亮度极高（对纯黑约 18:1，对纯白仅约 1.2:1），因此日记图标固定取深色前景，
/// 不跟随普通节点那套 `AppContrast.onColor(colorScheme.primary)` 的黑/白档位
/// （见 [_FlattenedTile._buildLeadingIconBox]）——否则换了主题后白图标会糊在亮底上。
const Color _journalBadgeColor = Color(0xFFEEF736);

class FlattenedItem {
  final String id;
  final bool isFolder;
  final Note? note;
  final Folder? folder;
  final int depth;
  final String? parentId;
  final bool isPinned;

  /// 是否为日记体系节点（日记根文件夹/月份子文件夹/日记笔记）
  /// 此类节点不可拖拽、不可删除、不可作为拖拽目标
  final bool isJournal;

  /// 空文件夹展开时的"空"占位行，仅作视觉提示，无交互
  final bool isEmptyPlaceholder;

  FlattenedItem({
    required this.id,
    required this.isFolder,
    this.note,
    this.folder,
    required this.depth,
    this.parentId,
    required this.isPinned,
    this.isJournal = false,
    this.isEmptyPlaceholder = false,
  });
}

/// 渲染用树节点：item 自带深度信息，children 保留完整子级（含折叠隐藏的部分），
/// 展开/收起动画由 [_FolderBody] 负责显隐。
class _TreeNode {
  _TreeNode(this.item, {this.children = const []});

  final FlattenedItem item;
  final List<_TreeNode> children;
}

class _FlattenedTile extends ConsumerStatefulWidget {
  final FlattenedItem item;
  final bool isSelectionMode;
  final bool isSelected;

  /// 页面级拖拽协调器算出的本行悬停落点；null 表示本行未被悬停
  final ReorderDropPosition? hoverPosition;
  final void Function(String id, GlobalKey key) onRegisterRow;
  final void Function(String id, GlobalKey key) onUnregisterRow;
  final VoidCallback onToggleSelection;
  final void Function(Note) onEditNote;
  final void Function(Note, GlobalKey) onShowNoteMenu;
  final void Function(Folder) onToggleFolder;
  final void Function(Folder, GlobalKey) onShowFolderMenu;
  final void Function(String?) onCreateNote;
  final void Function(String?) onCreateFolder;
  final void Function(FlattenedItem) onDragStarted;
  final void Function(Offset globalPosition) onDragPosition;
  final VoidCallback onDragEnded;

  const _FlattenedTile({
    super.key,
    required this.item,
    required this.isSelectionMode,
    required this.isSelected,
    required this.hoverPosition,
    required this.onRegisterRow,
    required this.onUnregisterRow,
    required this.onToggleSelection,
    required this.onEditNote,
    required this.onShowNoteMenu,
    required this.onToggleFolder,
    required this.onShowFolderMenu,
    required this.onCreateNote,
    required this.onCreateFolder,
    required this.onDragStarted,
    required this.onDragPosition,
    required this.onDragEnded,
  });

  @override
  ConsumerState<_FlattenedTile> createState() => _FlattenedTileState();
}

class _FlattenedTileState extends ConsumerState<_FlattenedTile> {
  final _tileKey = GlobalKey();
  bool _isDragging = false;
  bool _isPressed = false;

  /// 本次拖拽期间手指是否真的移动过。
  ///
  /// 「长按拾起→原地松手」要按长按手势弹菜单；位移一旦超过阈值，就说明用户
  /// 是在拖拽排序（含拖出去又拖回原位），松手后不该再弹菜单。
  bool _pointerMoved = false;
  Offset? _pointerDownPosition;

  @override
  void initState() {
    super.initState();
    // 空占位行不参与拖拽，无需注册命中盒
    if (!widget.item.isEmptyPlaceholder) {
      widget.onRegisterRow(widget.item.id, _tileKey);
    }
  }

  @override
  void dispose() {
    if (!widget.item.isEmptyPlaceholder) {
      widget.onUnregisterRow(widget.item.id, _tileKey);
    }
    super.dispose();
  }

  /// 节点图标：日记体系用书本/日历图标并统一日记黄底座，普通节点维持原样式
  IconData _leadingIconData(bool isFolder, bool isJournal) {
    if (isJournal) {
      if (!isFolder) {
        return Icons.menu_book;
      }
      final isRoot = widget.item.folder!.type == JournalService.rootFolderType;
      final isExpanded = widget.item.folder!.isExpanded;
      return isRoot
          ? (isExpanded ? Icons.auto_stories : Icons.auto_stories_outlined)
          : (isExpanded ? Icons.calendar_month : Icons.calendar_month_outlined);
    }
    if (isFolder) {
      return widget.item.folder!.isExpanded ? Icons.folder_open : Icons.folder;
    }
    // 按文件类型显示图标，便于识别小Q生成的网页/数据文件
    return _noteTypeIconData() ?? Icons.description;
  }

  /// 依据标题后缀返回文件类型图标；普通 Markdown 笔记返回 null 走默认图标
  IconData? _noteTypeIconData() {
    final note = widget.item.note;
    if (note == null) return null;
    switch (NoteFileTypeHelper.fromTitle(note.title)) {
      case NoteFileType.html:
        return Icons.language;
      case NoteFileType.svg:
        return Icons.palette_outlined;
      case NoteFileType.json:
        return Icons.data_object;
      case NoteFileType.code:
        return Icons.code;
      case NoteFileType.markdown:
        return null;
    }
  }

  /// 前置图标底座：32×32 实心底座 + 黑/白图标（日记体系用专用 EEF736 亮底配深色图标，
  /// 普通节点用主题色底座、前景按 `onColor(primary)` 取黑/白）。
  /// 文件夹在右下角叠加迷你展开箭头（原独立箭头并入此处，节省行首宽度）
  Widget _buildLeadingIconBox(ThemeData theme, bool isFolder, bool isJournal) {
    final icon = _leadingIconData(isFolder, isJournal);
    // 普通节点的前景档位仍与主题色同源；日记体系固定深色图标（EEF736 亮底承白图标不可读）
    final foreground = isJournal ? AppContrast.darkInk : AppContrast.onColor(theme.colorScheme.primary);
    return SizedBox(
      width: 32,
      height: 32,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AppIconBadge(
            icon: icon,
            size: 32,
            iconSize: 18,
            backgroundColor: isJournal ? _journalBadgeColor : theme.colorScheme.primary,
            foregroundColor: foreground,
            borderRadius: BorderRadius.circular(8),
            // 展开/收起时 folder ↔ folder_open 做淡入缩放，避免图标硬跳一下
            customIcon: AnimatedSwitcher(
              duration: AppMotion.duration(context, AppDurations.fast),
              switchInCurve: AppCurves.emphasized,
              switchOutCurve: AppCurves.exit,
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: ScaleTransition(scale: Tween<double>(begin: 0.72, end: 1).animate(animation), child: child),
              ),
              child: Icon(icon, key: ValueKey(icon), size: 18, color: foreground),
            ),
          ),
          if (isFolder)
            Positioned(
              right: -3,
              bottom: -3,
              child: Container(
                width: 14,
                height: 14,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: theme.colorScheme.surface,
                  border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7), width: 0.8),
                ),
                child: AnimatedRotation(
                  // 展开朝下，收起朝右（-0.25 圈 = 逆时针 90°）
                  turns: widget.item.folder!.isExpanded ? 0 : -0.25,
                  duration: AppMotion.duration(context, AppDurations.normal),
                  curve: AppCurves.emphasized,
                  child: Icon(
                    Icons.keyboard_arrow_down,
                    size: 11,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  /// 拖拽时跟随手指的浮层卡片
  Widget _buildDragFeedback(ThemeData theme, bool isFolder) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: MediaQuery.of(context).size.width - 32,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.95),
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 10, offset: const Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 复用行内图标底座：拖拽浮层与列表行保持同一主题色/日记黄底色，
            // 避免浮层里出现一枚脱色的灰色默认图标
            _buildLeadingIconBox(theme, isFolder, widget.item.isJournal),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isFolder ? widget.item.folder!.name : widget.item.note!.title,
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 桌面/Web 的行尾拖动手柄：按住手柄滑动即刻开启拖拽。
  ///
  /// 这两个平台以鼠标为主，按下即拖比「按住 500ms 再拖」顺手，所以不走整行长按。
  Widget _buildDragHandle(ThemeData theme, bool isFolder) {
    return Draggable<FlattenedItem>(
      data: widget.item,
      dragAnchorStrategy: (draggable, context, position) {
        // 记录起拖时的真实指针位置，供页面级命中测试使用
        widget.onDragPosition(position);
        final screenWidth = MediaQuery.of(context).size.width;
        final feedbackWidth = screenWidth - 32;
        // 手指按在右侧手柄上（距屏幕右边缘约 28px），
        // 对应 feedback 卡片右侧边缘内约 20px 处，
        // 使得拖拽时 feedback 整体水平位置与屏幕两侧边距（16px）保持完美重合居中
        return Offset(feedbackWidth - 20, 24);
      },
      onDragUpdate: (details) => widget.onDragPosition(details.globalPosition),
      onDragStarted: () {
        HapticFeedback.lightImpact();
        widget.onDragStarted(widget.item);
        setState(() => _isDragging = true);
      },
      // onDragEnd 覆盖落位与取消两种结局，不必再挂 canceled/completed
      onDragEnd: (_) {
        widget.onDragEnded();
        if (mounted) setState(() => _isDragging = false);
      },
      feedback: _buildDragFeedback(theme, isFolder),
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Icon(
            Icons.drag_indicator,
            size: 18,
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }

  /// 移动端整行长按拾起：长按成立即浮起卡片，移动手指即可拖拽排序；
  /// 原地松手则弹操作菜单，与原来的「长按弹菜单」习惯保持一致。
  Widget _buildLongPressDraggable(ThemeData theme, bool isFolder, Widget child) {
    return LongPressDraggable<FlattenedItem>(
      data: widget.item,
      // 触感统一由 onDragStarted 里的 lightImpact 负责，关掉默认的 selectionClick
      hapticFeedbackOnStart: false,
      dragAnchorStrategy: (draggable, context, position) {
        // 记录起拖时的真实指针位置，供页面级命中测试使用
        widget.onDragPosition(position);
        // 反馈卡片固定贴住屏幕左右 16px 边距，纵向跟着手指走：
        // 长按落点在行内任意位置，卡片都不会被推出屏幕。
        return Offset(position.dx - 16, 24);
      },
      onDragUpdate: (details) => widget.onDragPosition(details.globalPosition),
      onDragStarted: () {
        HapticFeedback.lightImpact();
        widget.onDragStarted(widget.item);
        setState(() => _isDragging = true);
      },
      onDragEnd: (details) {
        widget.onDragEnded();
        // 页面级 DragTarget 始终接受，用 wasAccepted 区分不出「原地松手」；
        // 这里以原始指针是否移动过为准：没移动 = 长按弹菜单，移动过 = 拖拽。
        final showMenu = isLongPressRelease(pointerMoved: _pointerMoved, landedElsewhere: false);
        if (mounted) setState(() => _isDragging = false);
        if (!showMenu) return;
        if (isFolder) {
          widget.onShowFolderMenu(widget.item.folder!, _tileKey);
        } else {
          widget.onShowNoteMenu(widget.item.note!, _tileKey);
        }
      },
      feedback: _buildDragFeedback(theme, isFolder),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isFolder = widget.item.isFolder;
    final isJournal = widget.item.isJournal;
    // 桌面/Web 走行尾手柄（鼠标按下即拖）；移动端走整行长按拾起
    final useHandle = useDragHandleFor(theme.platform);
    final canDrag = !widget.isSelectionMode && !isJournal;
    final hoverPosition = widget.hoverPosition;

    // 空文件夹展开占位：仅显示"空"提示，文字与子级内容对齐，无交互
    if (widget.item.isEmptyPlaceholder) {
      return Padding(
        padding: EdgeInsets.only(
          // 12 + depth*16 为行左缘，+60 对齐子级图标后的文字起点
          left: 12.0 + widget.item.depth * 16.0 + 60,
          right: 12,
          top: 2,
          bottom: 6,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '空',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5)),
          ),
        ),
      );
    }

    // 统一点击事件：文件夹触发展开/收起，笔记打开编辑，多选模式切换选中
    final VoidCallback? onItemTap = widget.isSelectionMode
        ? (isJournal ? null : widget.onToggleSelection)
        : (isFolder ? () => widget.onToggleFolder(widget.item.folder!) : () => widget.onEditNote(widget.item.note!));

    final Widget tileContent = AnimatedOpacity(
      opacity: _isDragging ? 0.35 : 1.0,
      duration: AppMotion.duration(context, AppDurations.press),
      curve: AppCurves.standard,
      child: AnimatedContainer(
        key: _tileKey,
        duration: AppMotion.duration(context, AppDurations.fast),
        curve: AppCurves.standard,
        padding: EdgeInsets.only(
          left: 12.0 + widget.item.depth * 16.0,
          right: 12,
          top: isFolder ? 6 : 4,
          bottom: isFolder ? 6 : 4,
        ),
        decoration: BoxDecoration(
          color: hoverPosition == ReorderDropPosition.inside
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.32)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: hoverPosition == ReorderDropPosition.inside
              ? Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.55))
              : null,
        ),
        child: Row(
          children: [
            // 日记体系节点不参与批量选择，不渲染复选框
            if (widget.isSelectionMode && !isJournal)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: AppCheckbox(
                    value: widget.isSelected,
                    activeColor: theme.colorScheme.primary,
                    inactiveColor: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),

            // 展开箭头已并入前置图标（图标容器右下角徽标），此处统一留 16px，
            // 使同层级文件夹与笔记的左边界对齐
            const SizedBox(width: 16),

            Expanded(
              child: GestureDetector(
                onTap: onItemTap,
                onTapDown: onItemTap == null ? null : (_) => setState(() => _isPressed = true),
                onTapUp: onItemTap == null ? null : (_) => setState(() => _isPressed = false),
                onTapCancel: onItemTap == null ? null : () => setState(() => _isPressed = false),
                // 移动端整行长按已交给「拾起拖拽」；两个长按识别器都在 500ms 判定，
                // 同时挂会互相把对方踢出竞技场，菜单与拖拽只能随机生效。
                onLongPress: canDrag && useHandle
                    ? () {
                        HapticFeedback.lightImpact();
                        if (isFolder) {
                          widget.onShowFolderMenu(widget.item.folder!, _tileKey);
                        } else {
                          widget.onShowNoteMenu(widget.item.note!, _tileKey);
                        }
                      }
                    : null,
                behavior: HitTestBehavior.opaque,
                child: AnimatedScale(
                  scale: _isPressed ? 0.985 : 1.0,
                  duration: AppMotion.duration(context, AppDurations.press),
                  curve: AppCurves.standard,
                  child: Row(
                    children: [
                      _buildLeadingIconBox(theme, isFolder, isJournal),
                      const SizedBox(width: 12),
                      if (!isFolder && widget.item.isPinned) ...[
                        Icon(Icons.push_pin, size: 14, color: theme.colorScheme.primary),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          isFolder ? widget.item.folder!.name : widget.item.note!.title,
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: isFolder ? FontWeight.bold : FontWeight.w500,
                            letterSpacing: 0.2,
                            // 日记体系标题用纯黑，与 EEF736 亮底图标形成强对比；
                            // 深色主题下纯黑会糊进深底，退回 onSurface 保证可读
                            color: isJournal
                                ? (theme.brightness == Brightness.dark
                                      ? theme.colorScheme.onSurface
                                      : AppContrast.darkInk)
                                : null,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 日记体系节点为系统管理结构，不提供拖动手柄与操作菜单；
            // 移动端不画手柄，改为整行长按拾起（见 _buildLongPressDraggable）
            if (canDrag && useHandle) ...[const SizedBox(width: 4), _buildDragHandle(theme, isFolder)],
          ],
        ),
      ),
    );

    // 移动端整行可长按拾起：先记下按压起点，用原始指针轨迹判断手指是否移动过。
    // Listener 不参与手势竞技场，拖拽识别器赢下手势后仍能拿到全程位移。
    final Widget draggableContent = canDrag && !useHandle
        ? Listener(
            onPointerDown: (event) {
              _pointerDownPosition = event.position;
              _pointerMoved = false;
            },
            onPointerMove: (event) {
              final origin = _pointerDownPosition;
              if (origin == null || _pointerMoved) return;
              if ((event.position - origin).distance > kReorderMoveThreshold) {
                _pointerMoved = true;
              }
            },
            child: _buildLongPressDraggable(theme, isFolder, tileContent),
          )
        : tileContent;

    return Stack(
      children: [
        draggableContent,

        // 插入位置指示线常驻但默认透明：拖拽进出时淡入淡出，避免瞬现瞬消。
        Positioned(
          top: 0,
          left: 12.0 + widget.item.depth * 16.0,
          right: 12,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: hoverPosition == ReorderDropPosition.before ? 1.0 : 0.0,
              duration: AppMotion.duration(context, AppDurations.fast),
              curve: AppCurves.standard,
              child: Container(
                height: 3,
                decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(1.5)),
              ),
            ),
          ),
        ),
        Positioned(
          bottom: 0,
          left: 12.0 + widget.item.depth * 16.0,
          right: 12,
          child: IgnorePointer(
            child: AnimatedOpacity(
              opacity: hoverPosition == ReorderDropPosition.after ? 1.0 : 0.0,
              duration: AppMotion.duration(context, AppDurations.fast),
              curve: AppCurves.standard,
              child: Container(
                height: 3,
                decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(1.5)),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 文件夹子级的展开/收起容器。
///
/// 视觉上做「幕布式展开」：高度由 [SizeTransition] 裁剪驱动，内容同步淡入并从
/// 文件夹行下方轻微落位；收起时反向播放并加速收拢。子级在折叠动画结束后才从
/// widget 树移除，因此不会出现「内容先瞬消、留白再慢慢收起」的断层。
class _FolderBody extends StatefulWidget {
  const _FolderBody({required this.expanded, required this.child});

  final bool expanded;

  /// 折叠时仍保留完整子级，供收起动画继续绘制
  final Widget child;

  @override
  State<_FolderBody> createState() => _FolderBodyState();
}

class _FolderBodyState extends State<_FolderBody> with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _sizeFactor;
  late final Animation<double> _opacity;
  late final Animation<double> _rise;

  /// 折叠动画期间子级仍需挂载，动画结束后才卸载
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _visible = widget.expanded;
    _controller = AnimationController(
      vsync: this,
      // 展开略慢让层级变化被看清，收起更快，避免拖住下一步操作
      duration: AppDurations.normal,
      reverseDuration: AppDurations.fast,
      value: widget.expanded ? 1 : 0,
    );
    _sizeFactor = CurvedAnimation(
      parent: _controller,
      curve: AppCurves.emphasizedSpatial,
      reverseCurve: AppCurves.exit,
    );
    // 内容比高度略早完成淡入；收起时先淡出再收拢，不会留下一条悬空的内容
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.1, 0.72, curve: Curves.easeOut),
      reverseCurve: const Interval(0.32, 1, curve: Curves.easeIn),
    );
    _rise = CurvedAnimation(parent: _controller, curve: AppCurves.emphasized, reverseCurve: AppCurves.exit);
  }

  @override
  void didUpdateWidget(covariant _FolderBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded == oldWidget.expanded) return;

    // 系统「减弱动态效果」开启时直接落到终态
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.stop();
      _controller.value = widget.expanded ? 1 : 0;
      _visible = widget.expanded;
      return;
    }

    if (widget.expanded) {
      // 收起中途再次点开：子级可能已卸载，先重新挂载再从当前进度继续展开
      _visible = true;
      _controller.forward();
    } else {
      _controller.reverse().whenComplete(() {
        // 反向被新的展开打断时 value 不会归零，此时不能卸载子级
        if (!mounted || widget.expanded || _controller.value > 0) return;
        setState(() => _visible = false);
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) {
      return const SizedBox.shrink();
    }

    return SizeTransition(
      sizeFactor: _sizeFactor,
      alignment: Alignment.topCenter,
      child: FadeTransition(
        opacity: _opacity,
        child: AnimatedBuilder(
          animation: _rise,
          builder: (context, child) {
            // 固定 6px 位移而不是按高度百分比：深层大子树也不会被放大成夸张滑动
            return Transform.translate(offset: Offset(0, -6 * (1 - _rise.value)), child: child);
          },
          child: widget.child,
        ),
      ),
    );
  }
}
