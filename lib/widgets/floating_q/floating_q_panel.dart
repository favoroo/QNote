part of 'floating_q_overlay.dart';

// 快捷对话弹窗内容：头部、消息区、撤回横幅、引用卡、图片附件、输入行。
// 所有类型保持私有，统一由 floating_q_overlay.dart 这个 library 组装。

/// 居中弹窗内容。
///
/// 弹窗尺寸由外层 [SizedBox] 决定，内部用 [Expanded] 把消息区撑满，
/// 比旧版 380 高的底部面板能显示更多对话内容。
class _FloatingQPanel extends ConsumerStatefulWidget {
  const _FloatingQPanel({
    super.key,
    required this.surfaceKey,
    required this.entrance,
    required this.panelSelection,
    required this.onUndo,
    required this.onMinimize,
    required this.onClose,
    required this.onExpand,
  });

  /// 量弹窗卡片最终 Rect 用的 Key（容器变形）。
  final GlobalKey surfaceKey;

  /// 打开/最小化共用的变形进度：头部/消息/输入错峰淡入，反向时先收口。
  final Animation<double> entrance;

  /// 面板内 SelectionArea 当前选中文本（供「给小Q」引用）。
  final ValueNotifier<String?> panelSelection;

  /// 撤回本会话小Q的全部修改。
  final Future<void> Function() onUndo;

  /// 最小化成气泡。
  final VoidCallback onMinimize;

  /// × 彻底关闭。
  final Future<void> Function() onClose;

  /// 展开到 /ai 全页面。
  final Future<void> Function() onExpand;

  @override
  ConsumerState<_FloatingQPanel> createState() => _FloatingQPanelState();
}

class _FloatingQPanelState extends ConsumerState<_FloatingQPanel> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 精确订阅上下文徽章文案：流式刷新（约 60ms 一次）不重建面板外壳，
    // 输入行 TextField 因此保持稳定（Web 端中文 IME 组合态不被打断）
    final contextLabel = ref.watch(
      floatingQProvider.select((s) => s.contextLabel ?? s.effectiveContext?.displayLabel ?? '当前页面'),
    );
    // 外部分享场景：内容来自第三方应用，与当前页面无关，不展示位置徽章
    final externalShareMode = ref.watch(floatingQProvider.select((s) => s.externalShareMode));
    // 草稿只在面板挂载时读一次：输入过程不能反向触发整块面板重建
    final draftText = ref.read(floatingQProvider).draftText;

    return SizedBox(
      key: widget.surfaceKey,
      width: double.infinity,
      height: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(_kDialogRadius),
          boxShadow: [_dialogShadow(theme.colorScheme)],
        ),
        child: Material(
          key: const ValueKey('panel'),
          color: theme.colorScheme.surface,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(_kDialogRadius),
            side: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.8),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              _PanelReveal(
                controller: widget.entrance,
                begin: 0,
                child: _buildHeader(theme, externalShareMode ? '小Q' : '小Q · $contextLabel'),
              ),
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
              Expanded(
                child: _PanelReveal(
                  controller: widget.entrance,
                  begin: 0.08,
                  child: _PanelMessages(panelSelection: widget.panelSelection),
                ),
              ),
              // 撤回横幅 / 引用卡片 / 图片附件都自管显隐，无内容时零高不占位
              _PanelReveal(
                controller: widget.entrance,
                begin: 0.16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PanelUndoBanner(onUndo: widget.onUndo),
                    const _PanelQuoteCard(),
                    const _PanelImageAttachments(),
                  ],
                ),
              ),
              Divider(height: 1, color: theme.colorScheme.outlineVariant),
              _PanelReveal(
                controller: widget.entrance,
                begin: 0.24,
                child: _PanelInputRow(initialText: draftText, entrance: widget.entrance),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme, String title) {
    final isDark = theme.brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 10, 8),
      child: Row(
        children: [
          const QAvatar(size: 24, withBackground: true),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              title,
              style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // 展开到 /ai 全页面：把当前临时对话迁移成正式会话再继续
          _headerButton(
            key: const ValueKey('floating-q-expand'),
            icon: Icons.open_in_full_rounded,
            tooltip: '展开全页面',
            backgroundColor: theme.colorScheme.primaryContainer,
            foregroundColor: theme.colorScheme.onPrimaryContainer,
            onPressed: () => widget.onExpand(),
          ),
          // 减号：临时收成气泡，会话和草稿都保留。黄色表示「可恢复」，与红色关闭区分
          _headerButton(
            key: const ValueKey('floating-q-minimize'),
            icon: Icons.remove_rounded,
            tooltip: '最小化成气泡',
            backgroundColor: AppPalette.warning(isDark),
            onPressed: widget.onMinimize,
          ),
          // ×：彻底结束本次对话
          _headerButton(
            key: const ValueKey('floating-q-close'),
            icon: Icons.close_rounded,
            tooltip: '结束对话',
            backgroundColor: theme.colorScheme.error,
            foregroundColor: theme.colorScheme.onError,
            onPressed: () => widget.onClose(),
          ),
        ],
      ),
    );
  }

  /// 头部圆形操作按钮。
  ///
  /// 底色统一走 [AppIconBadge] 的实心圆形样式：任意主题色下前景自动取黑/白，
  /// 与左侧小Q头像的视觉语言一致；圆角窗口式的黄/红语义让「暂存」和「销毁」
  /// 一眼可辨，不用读 tooltip 也不会点错。
  Widget _headerButton({
    required Key key,
    required IconData icon,
    required String tooltip,
    required Color backgroundColor,
    required VoidCallback onPressed,
    Color? foregroundColor,
  }) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: AppIconBadge(
        key: key,
        icon: icon,
        size: 32,
        iconSize: 18,
        tooltip: tooltip,
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        onTap: onPressed,
      ),
    );
  }
}

/// 面板内容错峰入场：从同一个变形控制器上切一段窗口出来（尾部与下一段重叠）。
///
/// Fade/Slide 都是把 child 透传的过渡件，入场期间逐帧重建的只有这两个节点，
/// 区块内容本身不会跟着重建。动画对象在 State 里建好、dispose 释放。
class _PanelReveal extends StatefulWidget {
  const _PanelReveal({required this.controller, required this.begin, required this.child});

  final Animation<double> controller;
  final double begin;
  final Widget child;

  @override
  State<_PanelReveal> createState() => _PanelRevealState();
}

class _PanelRevealState extends State<_PanelReveal> {
  late final CurvedAnimation _animation;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _animation = CurvedAnimation(
      parent: widget.controller,
      curve: Interval(widget.begin, math.min(1.0, widget.begin + 0.64), curve: AppCurves.emphasized),
    );
    _slide = Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero).animate(_animation);
  }

  @override
  void dispose() {
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 稳态也保留同一层过渡包装，不能改成直接返回 child。
    //
    // 一旦在动画完成时把 FadeTransition 换成裸 child，同一位置的 widget 类型
    // 变化会让整棵子树重挂载：输入框连同 FocusNode 一起销毁，键盘先收起、
    // 新挂载的输入框再按定时器重新抢焦点——表现就是弹窗「缩回去又展开」。
    // 稳态下 opacity=1、位移=0，不会建立离屏层，保留包装的代价可以忽略。
    return FadeTransition(
      opacity: _animation,
      child: SlideTransition(position: _slide, child: widget.child),
    );
  }
}

/// 消息区：会话消息 + 流式占位（状态文案与流式正文互斥展示）。
///
/// 独立订阅 provider：流式期间（约 60ms 一次）只有本组件重建，
/// 面板外壳与输入行保持稳定，输入框 IME 组合态不被打断。
class _PanelMessages extends ConsumerStatefulWidget {
  final ValueNotifier<String?> panelSelection;

  const _PanelMessages({required this.panelSelection});

  @override
  ConsumerState<_PanelMessages> createState() => _PanelMessagesState();
}

class _PanelMessagesState extends ConsumerState<_PanelMessages> {
  final _listController = ScrollController();

  /// 是否自动贴底跟随；流式期间用户向上拖动查看历史后暂停，
  /// 拖回底部附近自动恢复（与 ThoughtTailScrollView 同一套约定）
  bool _follow = true;

  bool get _isNearBottom =>
      !_listController.hasClients || _listController.position.maxScrollExtent - _listController.offset < 24;

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  /// 贴底仅在跟随态执行：jumpTo 会先终止当前滚动活动，流式期间每 60ms
  /// 一次的无条件贴底会持续打断用户拖拽，表现为回复时列表滑不动
  void _scrollToBottom({bool force = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_listController.hasClients) return;
      if (!force && !_follow) return;
      _listController.jumpTo(_listController.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // 只订阅「历史消息」真正依赖的字段。
    //
    // 流式正文 / 状态文案 / 实时思考是 60ms 级的高频字段；若像以前那样整体
    // `ref.watch(floatingQProvider)`，每来一个增量都会把面板里全部历史气泡
    // （连同 Opacity、入场动画、每个气泡的 Container 装饰）重建一遍 —— 面板
    // 开着聊长对话时，这就是持续的掉帧来源。高频部分单独交给下面的
    // _buildStreamingTail 自己订阅，历史气泡只在 messages 真的变化时重建。
    //
    // copyWith 在未改动消息时原样透传同一个 List 引用，而 select 用的是默认
    // 的 `==`（List 走标识比较），所以这里天然按「消息是否换过」触发。
    final messages = ref.watch(floatingQProvider.select((s) => s.messages));
    final phase = ref.watch(floatingQProvider.select((s) => s.phase));
    final hasStreamingTail = ref.watch(floatingQProvider.select(hasPanelStreamingTail));

    // 消息流或流式状态变化（正文、状态文案、实时思考内容）时滚到底部：
    // 新消息落地是离散事件，强制恢复跟随并贴底；流式增量仅在跟随态贴底
    ref.listen<FloatingQState>(floatingQProvider, (prev, next) {
      final newMessage = prev?.messages.length != next.messages.length;
      if (newMessage ||
          prev?.streamingText != next.streamingText ||
          prev?.statusText != next.statusText ||
          prev?.streamingThought != next.streamingThought) {
        if (newMessage) _follow = true;
        _scrollToBottom(force: newMessage);
      }
    });

    final children = <Widget>[];

    // 生图卡片已展示过的图片键：面板气泡用纯 Text 渲染正文，模型回显的
    // `![image](<路径>)` 需要按同一套规则剥离，否则会把原始标记文本露出来
    final generatedImageKeys = collectGeneratedImageKeys(messages);

    for (final message in messages) {
      // 生图结果直接以图片卡预览；其余工具中间消息不在快捷面板展示
      //（进行中的操作由状态行实时表达）
      if (message.role == 'tool') {
        final imageCard = _buildGeneratedImageCard(theme, message);
        if (imageCard != null) children.add(_buildEntrance(imageCard));
        continue;
      }
      final displayContent = message.role == 'assistant'
          ? stripRedundantImageMarkdown(message.content, generatedImageKeys)
          : message.content;
      // Agent 每轮发起工具调用前会生成「正文为空、仅承载 tool_calls」的 assistant
      // 中转消息（与 AI 主页面 isChatTimelineVisibleMessage 过滤的是同一类消息），
      // 快捷面板不渲染思考胶囊，这类消息只会渲染成空白胶囊卡片，直接跳过
      if (displayContent.trim().isEmpty) continue;
      children.add(_buildEntrance(_buildBubble(theme, message, displayContent)));
      // 步数上限提示：待处理时在气泡下方渲染「继续/暂停」按钮
      if (message.role == 'assistant' &&
          message.uiDetails?['type'] == 'turn_limit' &&
          message.uiDetails?['handled'] != true) {
        children.add(
          AgentTurnLimitActions(
            enabled: phase != FloatingQPhase.working,
            onContinue: () => ref.read(floatingQProvider.notifier).continueTask(),
            onPause: () => ref.read(floatingQProvider.notifier).pauseTask(),
          ),
        );
      }
    }

    // 流式区独立订阅，高频重建只落在这一块
    if (hasStreamingTail) {
      children.add(_buildStreamingTail(generatedImageKeys));
    }

    if (children.isEmpty) {
      final externalShareMode = ref.watch(floatingQProvider.select((s) => s.externalShareMode));
      final effectiveContext = ref.watch(floatingQProvider.select((s) => s.effectiveContext));
      final emptyPrompt = externalShareMode
          ? '让小Q整理或提炼这段内容。'
          : (effectiveContext?.emptyPromptHint ?? QPageContext.fallback.emptyPromptHint);

      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const QAvatar(size: 44, withBackground: true),
              const SizedBox(height: 10),
              Text(
                emptyPrompt,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
              ),
            ],
          ),
        ),
      );
    }

    return SelectionArea(
      // 跟踪面板内选中文本，供面板内「给小Q」工具栏引用
      onSelectionChanged: (selection) {
        widget.panelSelection.value = selection?.plainText;
      },
      contextMenuBuilder: (context, selectableRegionState) {
        final selectedText = widget.panelSelection.value;
        final hasSelection = selectedText != null && selectedText.isNotEmpty;
        return QTextSelectionToolbar(
          anchors: selectableRegionState.contextMenuAnchors,
          buttonItems: [
            ...selectableRegionState.contextMenuButtonItems.where((item) => item.type != ContextMenuButtonType.custom),
            if (hasSelection)
              ContextMenuButtonItem(
                label: '给小Q',
                onPressed: () {
                  selectableRegionState.hideToolbar();
                  ref
                      .read(floatingQProvider.notifier)
                      .openWithQuote(
                        QTextQuote(
                          source: QQuoteSource.chat,
                          sourceId: '',
                          sourceTitle: '对话内容',
                          quotedText: selectedText,
                        ),
                      );
                },
              ),
          ],
        );
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollUpdateNotification && notification.dragDetails != null) {
            _follow = false; // 用户主动拖动即暂停贴底跟随
          }
          if (_isNearBottom) _follow = true; // 拖回底部附近自动恢复
          return false;
        },
        child: ListView(
          controller: _listController,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          children: children,
        ),
      ),
    );
  }

  /// 面板是否还有流式尾部（状态行或正文增量）。
  ///
  /// 抽成顶层纯函数给 `select` 用：它只返回一个 bool，于是「从无到有 / 从有到无」
  /// 才会让历史气泡重建，而正文逐字增长只重建 [_PanelStreamingTail] 这一块。
  static bool hasPanelStreamingTail(FloatingQState s) =>
      s.statusText != null || (s.streamingText != null && s.streamingText!.isNotEmpty);

  Widget _buildStreamingTail(Set<String> generatedImageKeys) {
    return _PanelStreamingTail(generatedImageKeys: generatedImageKeys);
  }

  /// 新内容入场微动画：见 [_PanelEntrance]。
  Widget _buildEntrance(Widget child) => _PanelEntrance(child: child);

  /// 生图工具结果卡：在快捷面板中直接预览生成的图片
  ///
  /// 仅渲染 generate_image 成功且带路径的结果，其余工具消息返回 null 由调用方跳过。
  Widget? _buildGeneratedImageCard(ThemeData theme, ChatMessage message) {
    if (message.toolName != 'generate_image' || message.isError == true) {
      return null;
    }
    final paths = (message.uiDetails?['paths'] as List?)?.whereType<String>().toList() ?? const [];
    if (paths.isEmpty) return null;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8, right: 48),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(AppRadius.medium),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (index, path) in paths.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 180),
                  child: ChatImageView(
                    imagePath: path,
                    galleryImages: paths,
                    galleryIndex: index,
                    borderRadius: const BorderRadius.all(Radius.circular(6)),
                    onSendToQ: _sendImageToQ,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 「给小Q」：把面板里的图片挂到附件区，供用户就这张图继续追问
  void _sendImageToQ(String path) {
    HapticFeedback.lightImpact();
    ref.read(floatingQProvider.notifier).addAttachedImage(path);
    Toast.info(context, '已添加到附件');
  }

  Widget _buildBubble(ThemeData theme, ChatMessage message, String displayContent) {
    if (message.role == 'user') {
      return Align(
        alignment: Alignment.centerRight,
        child: Container(
          margin: const EdgeInsets.only(bottom: 8, left: 48),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primary,
            borderRadius: BorderRadius.circular(AppRadius.medium),
          ),
          child: Text(displayContent, style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimary)),
        ),
      );
    }
    return _buildAssistantBubble(theme, displayContent);
  }

  Widget _buildAssistantBubble(ThemeData theme, String content) => _panelAssistantBubble(theme, content);
}

/// 面板里一条助手正文气泡（流式与历史共用同一套外观）。
Widget _panelAssistantBubble(ThemeData theme, String content) {
  return Align(
    alignment: Alignment.centerLeft,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8, right: 48),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Text(content, style: theme.textTheme.bodyMedium),
    ),
  );
}

/// 等待态状态行：状态文案 + 思考形变无限符号动画 + 已用时递增计数。
Widget _panelStatusLine(ThemeData theme, String statusText, DateTime? startedAt) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Flexible(
          child: Text(
            statusText,
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7),
          child: MorphingInfinity(size: 20, strokeWidth: 1.5, color: theme.colorScheme.primary),
        ),
        StreamingElapsedText(
          startedAt: startedAt,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    ),
  );
}

/// 实时思考尾随区：裸文本不加容器，限高 2 行自动贴底滚动。
Widget _panelThoughtTail(ThemeData theme, String thought) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: ThoughtTailScrollView(
      text: thought,
      maxHeight: 40,
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      textStyle: theme.textTheme.bodySmall?.copyWith(
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
        fontStyle: FontStyle.italic,
        height: 1.4,
      ),
    ),
  );
}

/// 面板流式尾部：状态行（含实时思考）或流式正文。
///
/// 必须是独立 widget，不能是 [_PanelMessagesState] 里的一个方法：`ref.watch`
/// 挂在哪个 Element 上，就重建哪个 Element。放在面板 State 的 build 里，正文
/// 每 60ms 增长一次就会把面板里全部历史气泡一起重建；拆出来后高频重建只落在
/// 这一个节点上，历史消息完全不受影响。
class _PanelStreamingTail extends ConsumerWidget {
  const _PanelStreamingTail({required this.generatedImageKeys});

  final Set<String> generatedImageKeys;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final statusText = ref.watch(floatingQProvider.select((s) => s.statusText));
    final Widget child;
    if (statusText != null) {
      final startedAt = ref.watch(floatingQProvider.select((s) => s.streamingStartedAt));
      final liveThought = ref.watch(floatingQProvider.select((s) => s.streamingThought))?.trim() ?? '';
      child = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _PanelEntrance(child: _panelStatusLine(theme, statusText, startedAt)),
          // 思考中状态行下方挂实时思考尾随区（模型返回思考增量时才出现）
          if (liveThought.isNotEmpty) _PanelEntrance(child: _panelThoughtTail(theme, liveThought)),
        ],
      );
    } else {
      final streamingText = ref.watch(floatingQProvider.select((s) => s.streamingText)) ?? '';
      child = _PanelEntrance(
        child: _panelAssistantBubble(theme, stripRedundantImageMarkdown(streamingText, generatedImageKeys)),
      );
    }
    // 状态行 ↔ 正文气泡交叉淡化，避免流式结束时整棵子树硬替
    return AnimatedSwitcher(
      duration: AppMotion.duration(context, AppDurations.fast),
      switchInCurve: AppCurves.emphasized,
      switchOutCurve: AppCurves.exit,
      child: KeyedSubtree(key: ValueKey(statusText != null ? 'status' : 'text'), child: child),
    );
  }
}

/// 新内容入场微动画：淡入 + 轻微上移归位。
///
/// 只在首次挂载时从 0 播到 1；之后父级重建只要 tween 终值不变，
/// [TweenAnimationBuilder] 就不会重启动画，因此无需在完成时把过渡层摘掉。
/// 反过来，完成时换成裸 child 会让同一位置的 widget 类型变化、子树重挂载，
/// 消息气泡里的滚动位置与图片状态都会跟着丢一次。
class _PanelEntrance extends StatelessWidget {
  const _PanelEntrance({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0.0, end: 1.0),
      duration: AppMotion.duration(context, AppDurations.fast),
      curve: AppCurves.emphasized,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          // 位移只作用于绘制阶段，不影响布局，避免列表抖动
          offset: Offset(0, 8 * (1 - t)),
          child: child,
        ),
      ),
      child: child,
    );
  }
}

/// 撤回横幅：有待撤回变更时常驻展示，不再自动过期——
/// 直到撤回执行（phase 回 idle）或发起新任务（变更跨任务累加）
class _PanelUndoBanner extends ConsumerWidget {
  final Future<void> Function() onUndo;

  const _PanelUndoBanner({required this.onUndo});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    // 记录按结构相等比较：仅撤回相关状态变化时才重建横幅
    final (showBanner, undoCount, isUndoing) = ref.watch(
      floatingQProvider.select((s) => (s.phase == FloatingQPhase.countdown, s.pendingUndoCount, s.isUndoing)),
    );
    // 统一用 AppCollapsible 幕布式收放：收起时保留横幅内容先淡出后收拢，不再空框收缩
    return AppCollapsible(
      expanded: showBanner,
      rise: 0,
      child: showBanner
          ? Container(
              key: const ValueKey('undo-banner'),
              width: double.infinity,
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(AppRadius.medium),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.history_rounded, size: 16, color: theme.colorScheme.tertiary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '可撤回 $undoCount 处修改',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onTertiaryContainer),
                    ),
                  ),
                  TextButton(
                    onPressed: isUndoing ? null : onUndo,
                    child: isUndoing
                        ? LoadingRing(size: 14, strokeWidth: 1.8, color: theme.colorScheme.primary)
                        : const Text('撤回'),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

/// 引用卡片：展示用户通过「给小Q」挂起的引用内容（来源 + 位置 + 文本摘录），
/// 发送时随任务注入给小Q；× 可随时移除。null 时不渲染、不占位，
/// 且只精确订阅 pendingQuote，流式刷新不重建本卡片外的面板结构
class _PanelQuoteCard extends ConsumerWidget {
  const _PanelQuoteCard();

  IconData _sourceIcon(QQuoteSource source) => switch (source) {
    QQuoteSource.note => Icons.sticky_note_2_outlined,
    QQuoteSource.diary => Icons.schedule_rounded,
    QQuoteSource.journal => Icons.menu_book_outlined,
    QQuoteSource.todo => Icons.task_alt_outlined,
    QQuoteSource.external => Icons.share_outlined,
    QQuoteSource.chat => Icons.chat_bubble_outline_rounded,
  };

  String _sourceLabel(QQuoteSource source) => switch (source) {
    QQuoteSource.note => '笔记',
    QQuoteSource.diary => '流水记录',
    QQuoteSource.journal => '每日日记',
    QQuoteSource.todo => '待办',
    QQuoteSource.external => '外部分享',
    QQuoteSource.chat => '对话内容',
  };

  /// 标题行：日记来源为日期字符串不加书名号，其余《标题》+ 位置；
  /// 外部分享无实体标题，只展示来源标签
  String _titleLine(QTextQuote quote) {
    final label = _sourceLabel(quote.source);
    // 外部分享与对话内容无实体标题，只展示来源标签
    if (quote.source == QQuoteSource.external || quote.source == QQuoteSource.chat) {
      return label;
    }
    final title = quote.source == QQuoteSource.journal ? '$label ${quote.sourceTitle}' : '$label《${quote.sourceTitle}》';
    final location = quote.locationDesc;
    return location == null ? title : '$title · $location';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final quote = ref.watch(floatingQProvider.select((s) => s.pendingQuote));
    if (quote == null) {
      return const SizedBox.shrink(key: ValueKey('quote-card-hidden'));
    }
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('quote-card'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(10, 8, 2, 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(AppRadius.medium),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(_sourceIcon(quote.source), size: 16, color: theme.accentInk),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _titleLine(quote),
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  quote.quotedText.isEmpty
                      ? (quote.locationDesc?.contains('光标') == true ? '（光标处，可让小Q续写或编辑）' : '（引用完整内容）')
                      : quote.quotedText,
                  style: theme.textTheme.bodySmall,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          SizedBox(
            width: 28,
            height: 28,
            child: IconButton(
              padding: EdgeInsets.zero,
              iconSize: 16,
              tooltip: '移除引用',
              icon: const Icon(Icons.close_rounded),
              color: theme.colorScheme.onSurfaceVariant,
              onPressed: () => ref.read(floatingQProvider.notifier).clearPendingQuote(),
            ),
          ),
        ],
      ),
    );
  }
}

/// 分享图片附件条：外部分享图片唤起时展示待发送缩略图，× 可移除，
/// 发送时随消息一次性携带。无附件时不占位；挂载与 pendingImages 变化
/// 两个时机消费挂起图片（面板未开时收到分享走前者，面板开着再分享走后者）
class _PanelImageAttachments extends ConsumerStatefulWidget {
  const _PanelImageAttachments();

  @override
  ConsumerState<_PanelImageAttachments> createState() => _PanelImageAttachmentsState();
}

class _PanelImageAttachmentsState extends ConsumerState<_PanelImageAttachments> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _consumePending();
    });
  }

  void _consumePending() => ref.read(floatingQProvider.notifier).consumePendingImages();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final images = ref.watch(floatingQProvider.select((s) => s.attachedImages));

    ref.listen<List<String>?>(floatingQProvider.select((s) => s.pendingImages), (prev, next) {
      if (next != null && next.isNotEmpty) _consumePending();
    });

    if (images.isEmpty) {
      return const SizedBox.shrink(key: ValueKey('image-attachments-hidden'));
    }

    return Container(
      key: const ValueKey('image-attachments'),
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SizedBox(
        height: 64,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          itemCount: images.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final path = images[index];
            return Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.medium),
                  child: UnifiedImage(imagePath: path, width: 64, height: 64, fit: BoxFit.cover),
                ),
                // 移除按钮叠在缩略图右上角内侧（外溢负偏移会被 ListView 裁剪）
                Positioned(
                  top: 2,
                  right: 2,
                  child: GestureDetector(
                    onTap: () => ref.read(floatingQProvider.notifier).removeAttachedImage(path),
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surface.withValues(alpha: 0.85),
                        shape: BoxShape.circle,
                      ),
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.close_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 输入行：输入框 + 发送/停止按钮。
///
/// 输入控制器在本组件内持有，且只订阅"是否工作中"：
/// 流式刷新不重建 TextField，保证光标位置与 IME 组合态稳定
/// （修复"删除文字后再打字，刚删的字又出现"的 Web 端输入异常）。
/// 未发送草稿同步到 provider，面板最小化成气泡后重新打开仍能回填。
class _PanelInputRow extends ConsumerStatefulWidget {
  const _PanelInputRow({required this.initialText, required this.entrance});

  /// 面板挂载时的草稿（最小化/切页回来后恢复）
  final String initialText;

  /// 打开/最小化的变形进度：聚焦要等它落定，避免键盘改写变形目标。
  final Animation<double> entrance;

  @override
  ConsumerState<_PanelInputRow> createState() => _PanelInputRowState();
}

class _PanelInputRowState extends ConsumerState<_PanelInputRow> {
  late final TextEditingController _inputController;
  final _focusNode = FocusNode();
  Timer? _focusTimer;

  @override
  void initState() {
    super.initState();
    _inputController = TextEditingController(text: widget.initialText);
    // 光标落到草稿末尾，重新打开时可以直接继续输入。
    _inputController.selection = TextSelection.collapsed(offset: widget.initialText.length);
    _scheduleFocusAfterEntrance();
  }

  /// 等容器变形落定后再把焦点交给输入框。
  ///
  /// 键盘一旦在变形途中弹起，`viewInsets` 会一路改动弹窗的目标 Rect：
  /// 正在飞行的容器被反复推着改尺寸，看起来忽大忽小；Android 上输入法
  /// 还可能在布局变动时重连一次，进一步触发收放循环。
  /// 先让卡片完整长出来，再晚一小拍聚焦，键盘只会弹一次。
  void _scheduleFocusAfterEntrance() {
    widget.entrance.addStatusListener(_handleEntranceStatus);
    if (!widget.entrance.isAnimating) {
      // 已经处于稳态（减弱动效 / 外部分享直接落位 / 从后台恢复）
      _focusTimer = Timer(const Duration(milliseconds: 60), _requestInputFocus);
    }
  }

  void _handleEntranceStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // 监听不摘除：面板在「最小化途中又被点开」时不会重挂载，
    // 需要第二次 completed 再把焦点交回来。
    _focusTimer?.cancel();
    _focusTimer = Timer(const Duration(milliseconds: 60), _requestInputFocus);
  }

  void _requestInputFocus() {
    if (!mounted) return;
    // 延时期间用户又开始最小化：不要在这次变形里抢焦点，等回到稳态再说
    if (widget.entrance.value < 1 || widget.entrance.isAnimating) return;
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    widget.entrance.removeStatusListener(_handleEntranceStatus);
    _focusTimer?.cancel();
    _inputController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  /// 物理键盘 Enter 拦截：无 Shift 即发送，Shift+Enter 放行默认换行。
  /// 软键盘行为由 textInputAction:newline 交给 IME（移动端发送一律点按钮）；
  /// 返回 handled 后 engine 不再把 Enter 送入文本输入通道，避免发送与换行叠加
  KeyEventResult _handleEnterKey(FocusNode node, KeyEvent event) {
    final isEnter = event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter || event is KeyRepeatEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isShiftPressed) return KeyEventResult.ignored;
    if (event is KeyDownEvent) _handleSend();
    return KeyEventResult.handled;
  }

  Future<void> _handleSend() async {
    final fq = ref.read(floatingQProvider);
    final text = _inputController.text.trim();
    // 工作中由发送按钮转为停止按钮，键盘发送路径直接忽略（不清空已输入内容）
    if (fq.runActive) return;
    if (text.isEmpty && fq.attachedImages.isEmpty) return;
    // 未配置模型：先弹引导，不清空输入
    if (!await AiRoleService.instance.hasUsableConfigForRole('assistant')) {
      if (mounted) {
        await showNoModelConfiguredDialog(context, scene: '小Q 对话');
      }
      return;
    }
    HapticFeedback.lightImpact();
    _inputController.clear();
    ref.read(floatingQProvider.notifier).updateDraft('');
    // 发送后无需手动滚动：消息区的 listen 监听到消息数变化会自动滚到底部
    await ref.read(floatingQProvider.notifier).send(text);
  }

  void _handleStop() {
    HapticFeedback.mediumImpact();
    ref.read(floatingQProvider.notifier).stop();
  }

  /// 长按发送按钮切换小Q模型：与 AI 主页面共用同一 assistant 角色绑定，
  /// 切换为全局生效（主页面同步更新）
  Future<void> _handleModelSelect() async {
    HapticFeedback.mediumImpact();
    final selected = await showAssistantModelSelector(context, ref);
    if (selected == null || !mounted) return;
    Toast.success(context, '小Q模型已切换为 ${selected.name}');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isWorking = ref.watch(floatingQProvider.select((s) => s.runActive));
    final externalShareMode = ref.watch(floatingQProvider.select((s) => s.externalShareMode));
    final effectiveContext = ref.watch(floatingQProvider.select((s) => s.effectiveContext));
    final inputHint = externalShareMode
        ? '告诉小Q如何处理这段内容…'
        : (effectiveContext?.inputHintText ?? QPageContext.fallback.inputHintText);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 常用提示词按钮（点击弹出列表，选中即覆盖输入框）
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              onTap: () => showQuickPromptDialog(context, ref, (text) {
                _inputController.text = text;
                _inputController.selection = TextSelection.fromPosition(TextPosition(offset: text.length));
                ref.read(floatingQProvider.notifier).updateDraft(text);
                _focusNode.requestFocus();
              }),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bolt_rounded, size: 15, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 4),
                    Text(
                      '常用提示词',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: Focus(
                  onKeyEvent: _handleEnterKey,
                  child: TextField(
                    controller: _inputController,
                    focusNode: _focusNode,
                    minLines: 1,
                    maxLines: 4,
                    // 软键盘回车键为「换行」，发送一律点右侧按钮；
                    // 桌面/Web 物理回车在 _handleEnterKey 拦截发送，Shift+Enter 换行
                    textInputAction: TextInputAction.newline,
                    style: theme.textTheme.bodyMedium,
                    onChanged: (text) => ref.read(floatingQProvider.notifier).updateDraft(text),
                    decoration: InputDecoration(
                      hintText: inputHint,
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.medium),
                        borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.medium),
                        borderSide: BorderSide(color: theme.colorScheme.outlineVariant),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AppRadius.medium),
                        borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.5),
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // 小Q工作中：发送按钮变为中断/停止按钮（与 AI 主页面交互一致）；
              // 空闲态长按可切换模型（工作中为停止按钮，不响应长按）。
              // 工作态外圈环绕极简细线 LoadingRing 缺口圆环旋转动画，中央为精致圆角停止方块
              isWorking
                  ? Tooltip(
                      message: '中止当前操作',
                      child: InkWell(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _handleStop();
                        },
                        borderRadius: BorderRadius.circular(20),
                        child: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: theme.colorScheme.primary.withValues(
                              alpha: theme.brightness == Brightness.dark ? 0.14 : 0.08,
                            ),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: theme.colorScheme.primary.withValues(
                                alpha: theme.brightness == Brightness.dark ? 0.22 : 0.14,
                              ),
                              width: 0.8,
                            ),
                          ),
                          child: Stack(
                            alignment: Alignment.center,
                            children: [
                              LoadingRing(size: 30, strokeWidth: 1.3, color: theme.colorScheme.primary),
                              Container(
                                width: 9.5,
                                height: 9.5,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.primary,
                                  borderRadius: BorderRadius.circular(2.0),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    )
                  : IconButton.filled(
                      onPressed: _handleSend,
                      onLongPress: _handleModelSelect,
                      tooltip: '发送（长按切换模型）',
                      style: IconButton.styleFrom(
                        backgroundColor: theme.colorScheme.primary,
                        foregroundColor: theme.colorScheme.onPrimary,
                      ),
                      icon: const Icon(Icons.arrow_upward_rounded, size: 22),
                    ),
            ],
          ),
        ],
      ),
    );
  }
}
