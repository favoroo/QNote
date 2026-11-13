part of 'todo_page.dart';
// 从 todo_page.dart 拆分：待办分类标签栏与待办条目展示组件。

/// 动态横向分类标签栏
class _TodoFolderTabBar extends StatelessWidget {
  final List<Folder> folders;
  final String selectedFolderId;

  /// 与 [folders] 下标一一对应的未完成数量，由页面按待办列表引用缓存后传入，
  /// 避免每个 Chip 在 build 里各自扫描一遍全量待办。
  final List<int> pendingCounts;
  final ValueChanged<String> onSelect;

  const _TodoFolderTabBar({
    required this.folders,
    required this.selectedFolderId,
    required this.pendingCounts,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      height: 46,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      // 分类栏不再提供快捷新建入口，避免与右下角新增待办混淆；新建分类请走右上角分类管理
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: folders.length,
        separatorBuilder: (context, index) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final folder = folders[index];
          final isSelected = folder.id == selectedFolderId;
          // 未完成数量由页面统一缓存，这里直接取对应下标，避免重复全量扫描。
          final count = pendingCounts[index];

          return PressableScale(
            pressedScale: 0.96,
            onTap: () => onSelect(folder.id),
            child: AnimatedContainer(
              // 分类 Chip 的选中反馈属于「小范围状态切换」，用 fast 档更跟手；
              // 原来固定 normal + easeInOut，点下去会有约 200ms 的黏滞感
              duration: AppMotion.duration(context, AppDurations.fast),
              curve: AppCurves.standard,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? colorScheme.primary : colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(AppRadius.large),
                border: Border.all(
                  color: isSelected ? colorScheme.primary : colorScheme.outlineVariant.withValues(alpha: 0.3),
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
                      color: isSelected ? colorScheme.onPrimary : colorScheme.onSurfaceVariant.withValues(alpha: 0.8),
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
    );
  }
}

/// 仿小米待办卡片组件
class _TodoItem extends StatefulWidget {
  final Todo todo;
  final int index;
  final bool isDraggable;
  final bool isSelectionMode;
  final bool isSelected;

  /// 是否播放「从 0 高度展开」的入场动画。已完成区分批展开时关闭，
  /// 避免外层高度过渡与每行入场动画叠加。
  final bool animateIn;
  final VoidCallback onTap;
  final VoidCallback onToggleComplete;
  final void Function(GlobalKey key) onLongPress;
  final VoidCallback? onDelete;
  final VoidCallback? onSelectToggle;

  const _TodoItem({
    super.key,
    required this.todo,
    required this.index,
    this.isDraggable = true,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.animateIn = true,
    required this.onTap,
    required this.onToggleComplete,
    required this.onLongPress,
    this.onDelete,
    this.onSelectToggle,
  });

  @override
  State<_TodoItem> createState() => _TodoItemState();
}

class _TodoItemState extends State<_TodoItem> with TickerProviderStateMixin {
  final GlobalKey _cardKey = GlobalKey();
  late AnimationController _animController;
  late Animation<double> _scaleAnimation;
  late Animation<double> _heightFactor;
  late Animation<double> _opacityAnimation;

  /// 从已完成区撤回时的「自下而上」归位位移；普通入场保持零位移。
  late Animation<Offset> _riseAnimation;

  /// 控制左滑位移动画
  late AnimationController _slideAnimController;
  late Animation<double> _slideAnimation;

  /// 最大左滑距离（露出圆形删除按钮）
  static const double _kMaxSlideExtent = 72.0;

  bool _localCompleted = false;
  bool _isCompleting = false;

  /// 正在从已完成区撤回：先本地取消勾选并收起卡片，动画结束后再提交状态。
  bool _isUncompleting = false;

  /// 入场动画是否已结束。结束后可以摘掉三层过渡包装，只保留卡片本体；
  /// 完成勾选时的收缩动画会先把该标志置回 false，避免动画失去渲染载体。
  bool _entranceFinished = false;

  /// 卡片当前是否处于「左滑露出删除钮」状态。
  ///
  /// 直接读控制器值：卡片主体被 [AnimatedBuilder] 复用为 child 后，主体不再
  /// 随动画每帧重建，所以不能依赖 build 时的局部变量判断。
  bool get _isSlidOpen => _slideAnimController.value > 0.01;

  /// 已播放过入场动画的待办 id。ListView 懒构建、PageView 切页都会重新
  /// initState，若每次都从 0 播入场，滚动时条目会不停「弹进来」。
  static final Set<String> _entrancePlayed = <String>{};

  /// 刚从已完成区撤回、等待重新出现在未完成列表的待办 id。
  /// 首次构建时据此改用「从下方滑入」的入场，形成向上归位的连续感。
  static final Set<String> _resurfacingIds = <String>{};

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(vsync: this, duration: AppDurations.medium);

    // 入场用令牌曲线：spring 对应「打勾/轻按」这类带触感的点缀，emphasized 对应
    // 新元素进入视口，exit 对应快速离场——三者语义与 AppCurves 的约定一致
    _scaleAnimation = CurvedAnimation(parent: _animController, curve: AppCurves.spring, reverseCurve: AppCurves.exit);

    // 入参会话中「取消完成」的条目回到列表时不再走普通弹入，而是从下方滑入
    // 并展开，补上与勾选完成对称的归位动效。收起/展开用快开曲线，
    // 避免高度从 0 缓慢起步导致前半段看不到卡片。
    final resurfaced = _resurfacingIds.remove(widget.todo.id);
    _heightFactor = CurvedAnimation(
      parent: _animController,
      curve: resurfaced ? AppCurves.emphasized : AppCurves.standard,
    );

    _opacityAnimation = CurvedAnimation(
      parent: _animController,
      curve: AppCurves.exit,
      reverseCurve: AppCurves.emphasized,
    );

    _slideAnimController = AnimationController(vsync: this, duration: AppDurations.fast);
    _slideAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _slideAnimController, curve: AppCurves.emphasized));

    if (_entrancePlayed.length > 800) {
      _entrancePlayed.clear();
      _resurfacingIds.clear();
    }
    _riseAnimation = resurfaced
        ? Tween<Offset>(
            begin: const Offset(0, 0.45),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: _animController, curve: AppCurves.emphasized))
        : const AlwaysStoppedAnimation<Offset>(Offset.zero);
    _animController.addStatusListener(_handleEntranceStatus);
    if (widget.animateIn && (_entrancePlayed.add(widget.todo.id) || resurfaced)) {
      _animController.forward();
    } else {
      // 不播入场时直接标记结束，首次 build 就走静态分支。
      _entranceFinished = true;
      _animController.value = 1.0;
    }
  }

  /// 入场动画完成后触发一次重建，把三层过渡包装从树上摘掉。
  void _handleEntranceStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed || _entranceFinished || !mounted) {
      return;
    }
    setState(() => _entranceFinished = true);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 减弱动效时直接落在终态，并且把左滑吸附改成瞬时。
    if (AppMotion.reduce(context)) {
      _entranceFinished = true;
      _animController.value = 1.0;
      _slideAnimController.duration = Duration.zero;
    } else {
      _slideAnimController.duration = AppDurations.fast;
    }
  }

  @override
  void didUpdateWidget(covariant _TodoItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isSelectionMode && !oldWidget.isSelectionMode) {
      _closeSlide();
    }
    if (oldWidget.todo.isCompleted != widget.todo.isCompleted) {
      setState(() {
        _localCompleted = widget.todo.isCompleted;
        if (widget.todo.isCompleted) {
          // 直接落到完成终态，避免过渡层被中途摘掉造成跳变。
          _entranceFinished = true;
          _animController.value = 1.0;
        } else if (_animController.value >= 1.0) {
          // 控制器已在终态时 forward 不会产生动画，保持静态分支即可。
          _entranceFinished = true;
        } else {
          // 恢复为未完成时沿用原有 forward 重播语义，需要重新挂回过渡层。
          _entranceFinished = false;
          _animController.forward();
        }
      });
    }
  }

  @override
  void dispose() {
    _animController.dispose();
    _slideAnimController.dispose();
    super.dispose();
  }

  void _openSlide() {
    _slideAnimController.animateTo(1.0, curve: AppCurves.emphasized);
  }

  void _closeSlide() {
    _slideAnimController.animateTo(0.0, curve: AppCurves.emphasized);
  }

  void _handleToggleComplete() {
    HapticFeedback.mediumImpact();
    if (_slideAnimController.value > 0) {
      _closeSlide();
      return;
    }
    if (widget.todo.isCompleted) {
      _uncompleteAndCommit();
      return;
    }
    if (_isCompleting) return;

    // 减弱动效下不播放 300ms 收缩，直接提交完成状态。
    if (AppMotion.reduce(context)) {
      widget.onToggleComplete();
      return;
    }

    _isCompleting = true;
    setState(() {
      _localCompleted = true;
      // 收缩动画依赖 Size/Fade/Scale 过渡层，先退出静态分支再 reverse。
      _entranceFinished = false;
    });

    _animController.reverse().then((_) {
      if (mounted) {
        _isCompleting = false;
      }
      widget.onToggleComplete();
    });
  }

  /// 取消完成：先去掉勾选、让卡片原地收起，随后提交状态。
  ///
  /// 条目回到未完成列表时由 [initState] 依据 [_resurfacingIds] 播放
  /// 「自下而上」的入场，避免像原来那样瞬间跳到上方列表。
  void _uncompleteAndCommit() {
    if (_isCompleting) return;

    // 减弱动效时不做两段过渡，直接提交状态。
    if (AppMotion.reduce(context)) {
      widget.onToggleComplete();
      return;
    }

    // 入场标记按 id 记忆，先移除，回到未完成列表时才允许重新播放。
    _entrancePlayed.remove(widget.todo.id);
    _resurfacingIds.add(widget.todo.id);
    _isCompleting = true;
    setState(() {
      _isUncompleting = true;
      // 收缩动画依赖过渡层，先退出静态分支再 reverse。
      _entranceFinished = false;
    });

    _animController.reverse().then((_) {
      if (mounted) {
        _isCompleting = false;
      }
      widget.onToggleComplete();
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final isSelectionMode = widget.isSelectionMode;

    final Widget slideableCard = AnimatedBuilder(
      animation: _slideAnimation,
      // 卡片主体作为 child 传入：左滑动画每帧只重建这层 Stack / Transform /
      // 删除钮，卡片本体（复选框、标题、辅助信息、拖拽把手）复用同一份
      // Element，不跟着每帧重跑一遍整卡布局。之前 builder 里内联重建整卡，
      // 滑动时等于每帧把一张待办卡完整重排一次，条目一多就明显掉帧。
      child: _buildCardBody(theme, colorScheme, isDark),
      builder: (context, child) {
        final slideProgress = _slideAnimation.value;
        final currentOffset = -_kMaxSlideExtent * slideProgress;
        final isSlidOpen = slideProgress > 0.01;

        return Container(
          margin: const EdgeInsets.only(bottom: 8),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.centerRight,
            children: [
              // 右侧暴露的圆形删除按钮背景层（多选模式下隐藏）
              if (isSlidOpen && !isSelectionMode)
                Positioned(
                  right: 8,
                  child: Opacity(
                    opacity: (slideProgress * 1.5).clamp(0.0, 1.0),
                    child: Transform.scale(
                      scale: (0.5 + 0.5 * slideProgress).clamp(0.5, 1.0),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            _closeSlide();
                            widget.onDelete?.call();
                          },
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 48,
                            height: 48,
                            decoration: const BoxDecoration(
                              color: Color(0xFFE54B3C),
                              shape: BoxShape.circle,
                              boxShadow: [BoxShadow(color: Color(0x33E54B3C), blurRadius: 8, offset: Offset(0, 3))],
                            ),
                            alignment: Alignment.center,
                            child: const Icon(Icons.delete_outline, color: Colors.white, size: 24),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              // 前景待办卡片主体（多选模式下禁止左滑）
              GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: isSelectionMode
                    ? null
                    : (details) {
                        final deltaProgress = -details.primaryDelta! / _kMaxSlideExtent;
                        final newProgress = (_slideAnimController.value + deltaProgress).clamp(0.0, 1.0);
                        _slideAnimController.value = newProgress;
                      },
                onHorizontalDragEnd: isSelectionMode
                    ? null
                    : (details) {
                        final velocity = details.primaryVelocity ?? 0.0;
                        if (velocity < -300) {
                          // 快速左滑：直接展开
                          _openSlide();
                        } else if (velocity > 300) {
                          // 快速右滑：直接收起
                          _closeSlide();
                        } else {
                          // 根据当前拖拽位置阈值决定吸附
                          if (_slideAnimController.value >= 0.4) {
                            _openSlide();
                          } else {
                            _closeSlide();
                          }
                        }
                      },
                child: Transform.translate(offset: Offset(isSelectionMode ? 0 : currentOffset, 0), child: child),
              ),
            ],
          ),
        );
      },
    );

    // 入场动画结束后三层过渡都落在恒等值（1.0），继续挂着只会让每帧多走
    // 三层 RenderObject；此时直接挂卡片本体，左滑仍由 AnimatedBuilder 驱动。
    final Widget card = _entranceFinished
        ? slideableCard
        : SizeTransition(
            sizeFactor: _heightFactor,
            alignment: const Alignment(-1.0, -1.0),
            child: SlideTransition(
              position: _riseAnimation,
              child: FadeTransition(
                opacity: _opacityAnimation,
                child: ScaleTransition(scale: _scaleAnimation, child: slideableCard),
              ),
            ),
          );

    // 移动端：整行长按拾起即可拖拽排序，拇指不必再瞄准行尾的小图标。
    // 桌面/Web 仍走行尾手柄（鼠标按下即拖，见 _buildCardBody），故不包这一层。
    if (widget.isDraggable && !isSelectionMode && !useDragHandleFor(theme.platform)) {
      return ReorderableDelayedDragStartListener(index: widget.index, child: card);
    }
    return card;
  }

  /// 待办卡片本体（不含左滑位移与删除钮）。
  ///
  /// 单独拆出来是为了能作为 [AnimatedBuilder] 的 `child` 复用：左滑动画期间
  /// 卡片内容本身不随进度变化，没必要每帧重排。判断「是否已滑开」改成读控制器
  /// 当前值（[_isSlidOpen]），不再依赖 build 时算出来的局部变量。
  Widget _buildCardBody(ThemeData theme, ColorScheme colorScheme, bool isDark) {
    final todo = widget.todo;
    final isDone = (todo.isCompleted && !_isUncompleting) || _localCompleted;
    final isSelectionMode = widget.isSelectionMode;
    final isSelected = widget.isSelected;

    return Container(
      decoration: BoxDecoration(
        color: isSelectionMode && isSelected
            ? colorScheme.primary.withValues(alpha: isDark ? 0.18 : 0.08)
            : (isDark ? colorScheme.surfaceContainer : colorScheme.surfaceContainerLow),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isSelectionMode && isSelected
              ? colorScheme.primary
              : colorScheme.outlineVariant.withValues(alpha: isDark ? 0.25 : 0.4),
          width: isSelectionMode && isSelected ? 1.8 : 1.0,
        ),
        boxShadow: [
          BoxShadow(color: colorScheme.shadow.withValues(alpha: 0.02), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        child: Row(
          children: [
            // 多选复选框 vs 小米风格圆形复选框
            if (isSelectionMode)
              GestureDetector(
                key: const ValueKey('todo_select_detector'),
                onTap: () {
                  HapticFeedback.selectionClick();
                  widget.onSelectToggle?.call();
                },
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  key: const ValueKey('todo_select_checkbox'),
                  duration: AppMotion.duration(context, AppDurations.fast),
                  curve: AppCurves.standard,
                  width: 22,
                  height: 22,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(11),
                    color: isSelected ? colorScheme.primary : Colors.transparent,
                    border: Border.all(
                      color: isSelected ? colorScheme.primary : colorScheme.outline.withValues(alpha: 0.6),
                      width: 2.0,
                    ),
                  ),
                  child: isSelected ? Icon(Icons.check, size: 15, color: colorScheme.onPrimary) : null,
                ),
              )
            else
              GestureDetector(
                key: const ValueKey('todo_done_detector'),
                onTap: _handleToggleComplete,
                behavior: HitTestBehavior.opaque,
                child: AnimatedContainer(
                  key: const ValueKey('todo_done_checkbox'),
                  duration: AppMotion.duration(context, AppDurations.medium),
                  curve: AppCurves.standard,
                  width: 20,
                  height: 20,
                  margin: const EdgeInsets.only(right: 10),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    // 完成态做成实心主题色勾选框（与主题 checkbox 一致），
                    // 淡底 + 同色勾在荧光黄绿下几乎看不见
                    border: Border.all(
                      color: isDone ? colorScheme.primary : colorScheme.outline.withValues(alpha: 0.5),
                      width: 1.8,
                    ),
                    color: isDone ? colorScheme.primary : Colors.transparent,
                  ),
                  child: isDone
                      ? TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: AppMotion.duration(context, AppDurations.medium),
                          curve: AppCurves.spring,
                          builder: (context, value, child) {
                            return Transform.scale(scale: value, child: child);
                          },
                          child: Icon(Icons.check, size: 14, color: colorScheme.onPrimary),
                        )
                      : null,
                ),
              ),
            // 待办标题与辅助状态（选择模式下点击整张卡片切换选中，正常模式下点击唤出编辑弹窗，长按唤出操作菜单）
            Expanded(
              child: GestureDetector(
                key: _cardKey,
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  if (isSelectionMode) {
                    HapticFeedback.selectionClick();
                    widget.onSelectToggle?.call();
                  } else if (_isSlidOpen) {
                    _closeSlide();
                  } else {
                    widget.onTap();
                  }
                },
                // 移动端整行长按已交给「拾起拖拽」识别器；这里再挂长按识别器，
                // 两者都在 500ms 判定并互相把对方踢出竞技场，菜单与拖拽只能随机生效。
                onLongPress: (!useDragHandleFor(theme.platform) && !isSelectionMode)
                    ? null
                    : () {
                        if (isSelectionMode) {
                          HapticFeedback.selectionClick();
                          widget.onSelectToggle?.call();
                        } else if (_isSlidOpen) {
                          _closeSlide();
                        } else {
                          widget.onLongPress(_cardKey);
                        }
                      },
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
                        color: isDone ? colorScheme.onSurfaceVariant.withValues(alpha: 0.5) : colorScheme.onSurface,
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
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.repeat, size: 11, color: colorScheme.onSurfaceVariant),
                                  const SizedBox(width: 3),
                                  Text(
                                    todo.repeatRuleLabel,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      fontWeight: FontWeight.bold,
                                      color: colorScheme.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (todo.reminderTime != null) ...[
                            Icon(Icons.alarm, size: 12, color: colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
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
            // 桌面/Web 保留行尾手柄：鼠标按下即拖，比按住 500ms 顺手
            if (widget.isDraggable && !isSelectionMode && useDragHandleFor(theme.platform))
              ReorderableDragStartListener(
                index: widget.index,
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: Center(
                      child: Icon(
                        Icons.drag_indicator,
                        size: 18,
                        color: colorScheme.onSurfaceVariant.withValues(alpha: 0.35),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
