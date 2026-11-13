part of 'ai_page.dart';
// 从 ai_page_widgets.dart 拆分：聊天气泡、输入胶囊与流式状态相关组件。

class _StreamingBubble extends ConsumerStatefulWidget {
  final bool isFirstInGroup;
  final bool isLastInGroup;

  /// 与 `ChatBubble` 同义：流式正文同样需要按生图卡片去重
  final Set<String> generatedImageKeys;
  final ValueChanged<String>? onSendToQ;

  const _StreamingBubble({
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.generatedImageKeys = const {},
    this.onSendToQ,
  });

  @override
  ConsumerState<_StreamingBubble> createState() => _StreamingBubbleState();
}

class _StreamingBubbleState extends ConsumerState<_StreamingBubble> {
  /// 已渲染到气泡的正文。Markdown 全量重解析的成本随正文长度线性增长，
  /// 而流式 provider 约 60ms flush 一次，正文越长逐帧解析越贵，
  /// 因此按「增量达阈值立即渲染 + 超时兜底补渲染」降低重建频率。
  String _renderedContent = '';
  String _pendingContent = '';
  Timer? _flushTimer;

  /// 约 8 个汉字的增量才触发一次重渲染，正文越长省下的解析越多
  static const int _minFlushDelta = 24;

  /// 未达增量阈值时最长等待多久补渲染一次，保证尾部内容最终跟上
  static const Duration _flushInterval = Duration(milliseconds: 200);

  void _scheduleFlush(String latest) {
    // 内容没有实际增长时不要挂定时器：否则 200ms 后 setState 又会走到同一
    // 分支，形成整段流式期间永不停止的 5Hz 空转重建。
    if (latest == _renderedContent) return;
    _pendingContent = latest;
    _flushTimer ??= Timer(_flushInterval, () {
      _flushTimer = null;
      if (!mounted || _pendingContent == _renderedContent) return;
      setState(() => _renderedContent = _pendingContent);
    });
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final streamingContent = ref.watch(aiStreamingMessageProvider);
    // 正文与阶段性状态互斥展示：优先正文；正文未到时展示状态行（思考中/准备中…）
    final hasContent = streamingContent != null && streamingContent.trim().isNotEmpty;
    final statusText = hasContent ? null : ref.watch(aiStreamingStatusProvider);
    // 正文流式输出时本身在持续增长，无需已用时计时
    final statusStartedAt = hasContent ? null : ref.watch(aiStreamingStartedAtProvider);

    String content = '';
    if (hasContent) {
      if (_renderedContent.isEmpty) {
        // 首块正文立即渲染：节流只用于压制长正文的高频重解析，
        // 不该让状态卡在首个 token 到达后再多停 200ms。
        _flushTimer?.cancel();
        _flushTimer = null;
        _renderedContent = streamingContent;
      } else if (streamingContent != _renderedContent) {
        if (streamingContent.length - _renderedContent.length >= _minFlushDelta ||
            !streamingContent.startsWith(_renderedContent)) {
          // 增量达阈值，或内容被整体替换（重发/重试），立即跟上
          _flushTimer?.cancel();
          _flushTimer = null;
          _renderedContent = streamingContent;
        } else {
          _scheduleFlush(streamingContent);
        }
      }
      content = _renderedContent;
    } else {
      // 状态行模式：清掉残留正文与挂起的补渲染
      _flushTimer?.cancel();
      _flushTimer = null;
      _renderedContent = '';
    }

    // 独立重绘边界：流式气泡逐帧刷新时不连带整条列表重绘
    final liveThought = ref.watch(aiStreamingThoughtProvider)?.trim() ?? '';
    // 正文开始流式后，把本轮思考以独立步骤行留在正文上方（对齐 ZCode 的时间线：
    // 思考 → 回答），状态卡阶段则由气泡内部的实时思考区承担
    final showThoughtRow = hasContent && liveThought.isNotEmpty;
    final bubble = ChatBubble(
      // 固定 Key：思考行在首字到达后插入到气泡上方，若气泡没有 Key
      // 会因 Column 第 0 个子节点变化而被卸载重建，入场动画和气泡状态都会重来。
      key: const ValueKey('streaming_chat_bubble'),
      message: ChatMessage(role: 'assistant', content: content, timestamp: DateTime.now()),
      statusText: statusText,
      statusStartedAt: statusStartedAt,
      isFirstInGroup: widget.isFirstInGroup && !showThoughtRow,
      isLastInGroup: widget.isLastInGroup,
      generatedImageKeys: widget.generatedImageKeys,
      onSendToQ: widget.onSendToQ,
    );
    return RepaintBoundary(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showThoughtRow) ...[
            if (widget.isFirstInGroup)
              Padding(
                padding: const EdgeInsets.only(bottom: 2, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const QAvatar(size: 24, withBackground: true),
                    const SizedBox(width: 6),
                    Text(
                      '小Q',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              key: const ValueKey('streaming_thought_row'),
              padding: const EdgeInsets.only(left: 4, right: 4, bottom: 2),
              child: ThinkingProcessView(
                thought: liveThought,
                isStreaming: true,
                startedAt: ref.watch(aiStreamingTurnStartedAtProvider),
              ),
            ),
          ],
          bubble,
        ],
      ),
    );
  }
}

class ChatBubble extends ConsumerWidget {
  final ChatMessage message;

  /// 流式占位的阶段性状态文案（非 null 即占位模式），与正文互斥展示
  final String? statusText;

  /// 本轮任务的开始时间，状态行尾部显示「已用时」递增计数
  final DateTime? statusStartedAt;
  final bool isFirstInGroup;
  final bool isLastInGroup;

  /// 步数上限消息的操作回调（非 null 且待处理时在气泡下方渲染「继续/暂停」按钮）
  final VoidCallback? onContinue;
  final VoidCallback? onPause;

  /// 按钮是否可点（Agent 执行中禁用，防止并发任务）
  final bool actionsEnabled;

  /// 本会话内已由生图卡片展示过的图片键，用于跳过正文里重复的内联图
  final Set<String> generatedImageKeys;

  /// 「给小Q」回调（把图片挂到输入框）；为 null 时图片菜单不出现该项
  final ValueChanged<String>? onSendToQ;

  /// 重新生成本轮（气泡下方操作条入口）；为 null 时不显示该按钮
  final VoidCallback? onRegenerate;

  /// 重新生成是否可点（流式输出中禁用，避免与进行中的任务并发）
  final bool regenerateEnabled;

  const ChatBubble({
    super.key,
    required this.message,
    this.statusText,
    this.statusStartedAt,
    this.isFirstInGroup = true,
    this.isLastInGroup = true,
    this.onContinue,
    this.onPause,
    this.actionsEnabled = false,
    this.generatedImageKeys = const <String>{},
    this.onSendToQ,
    this.onRegenerate,
    this.regenerateEnabled = true,
  });

  /// 是否为待处理的步数上限消息（渲染「继续/暂停」按钮）
  bool get _isTurnLimitPending => message.uiDetails?['type'] == 'turn_limit' && message.uiDetails?['handled'] != true;

  /// 点击助手气泡：本条正在合成/播放时中断朗读，否则沿用收起键盘行为。
  ///
  /// 子级命中后外层聊天区域的点击监听不再触发，故非播放态需自行 unfocus，
  /// 保持「点气泡也能收起软键盘」的原有手感。
  void _onBubbleTap(WidgetRef ref) {
    final playback = ref.read(ttsPlaybackProvider);
    final isVoiceOn =
        playback.messageId == TtsPlayer.messageKeyOf(message) && playback.status != TtsPlaybackStatus.idle;
    if (!isVoiceOn) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    ref.read(ttsPlaybackProvider.notifier).stop();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isUser = message.role == 'user';
    // 用户侧头部展示个人信息页设置的昵称与头像：昵称优先、其次姓名，都空兜底「You」
    final profile = ref.watch(userProfileNotifierProvider);
    final nickname = profile?.nickname;
    final realName = profile?.name;
    final userName = (nickname?.isNotEmpty ?? false)
        ? nickname!
        : (realName?.isNotEmpty ?? false)
        ? realName!
        : 'You';
    final avatarPath = profile?.avatarPath ?? '';
    // 实例字段的空安全提升不跨闭包生效，局部变量化供下方 builder 内使用
    final statusText = this.statusText;

    // 助手正文气泡下挂连体操作条（复制/朗读/重新生成）；
    // 流式占位、错误气泡与工具卡片不给入口
    final showActionBar =
        !isUser &&
        message.role == 'assistant' &&
        statusText == null &&
        message.uiDetails == null &&
        (message.isError ?? false) != true &&
        message.content.trim().isNotEmpty;

    // 该消息是否还有可渲染的主体（正文 / 思考过程 / 工具卡片）
    final hasRenderableBody =
        message.content.trim().isNotEmpty ||
        (message.thought?.trim().isNotEmpty ?? false) ||
        message.role == 'tool' ||
        message.role == 'tool_group' ||
        message.uiDetails != null;

    // 正文为空的助手消息属于工具调用中转（列表层已过滤），这里再兜一层；
    // 只有流式占位气泡（statusText 阶段）才允许退化成「正在输入」动画。
    if (!isUser && statusText == null && !hasRenderableBody) {
      return const SizedBox.shrink();
    }

    // 思考段：扁平时间线行，不套气泡壳（对齐 ZCode 的「思考 · 3 秒」步骤行）
    if (message.role == 'thought') {
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: AppMotion.duration(context, AppDurations.medium),
        curve: AppCurves.emphasized,
        builder: (context, value, child) {
          return Opacity(
            opacity: value,
            child: Transform.translate(offset: Offset(0, (1 - value) * 12), child: child),
          );
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // 思考行也承担「小Q」抬头：它是本轮回复的第一行，
            // 若不给抬头，紧随其后的正文气泡会因「同组」判定不再显示头像
            if (isFirstInGroup)
              Padding(
                padding: const EdgeInsets.only(bottom: 2, left: 4, right: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const QAvatar(size: 24, withBackground: true),
                    const SizedBox(width: 6),
                    Text(
                      '小Q',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: EdgeInsets.only(left: 4, right: 4, bottom: isLastInGroup ? 12 : 2),
              child: ThinkingProcessView(thought: message.content, durationSeconds: message.thoughtSeconds),
            ),
          ],
        ),
      );
    }

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AppMotion.duration(context, AppDurations.medium),
      curve: AppCurves.emphasized,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, (1 - value) * 20), child: child),
        );
      },
      child: Column(
        crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          // Avatar and sender name header - 仅当同组第一条消息时显示，同一回复多条消息避免重复显示头像
          if (isFirstInGroup)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4, right: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!isUser) ...[
                    const QAvatar(size: 24, withBackground: true),
                    const SizedBox(width: 6),
                    Text(
                      '小Q',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ] else ...[
                    Text(
                      userName,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (avatarPath.isNotEmpty)
                      UnifiedImage(
                        imagePath: avatarPath,
                        width: 24,
                        height: 24,
                        borderRadius: BorderRadius.circular(12),
                        fit: BoxFit.cover,
                      )
                    else
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: Icon(Icons.person_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                  ],
                ],
              ),
            ),
          // Bubble container
          // 朗读/合成中点击本条气泡即中断播放（与豆包一致）；其余气泡不接管点击，
          // 交给外层聊天区域的收起键盘逻辑
          GestureDetector(
            // opaque：整张卡片（含内边距）都是中断区域，避免点留白处没反应
            behavior: HitTestBehavior.opaque,
            onTap: showActionBar ? () => _onBubbleTap(ref) : null,
            child: Align(
              alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: isUser ? null : double.infinity,
                // 下挂操作条时收紧间距，让两段读起来是同一张卡
                margin: EdgeInsets.only(bottom: showActionBar ? 6 : (isLastInGroup ? 16 : 4)),
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: isUser ? 10 : 12),
                constraints: BoxConstraints(
                  maxWidth: isUser ? MediaQuery.of(context).size.width * 0.82 : double.infinity,
                ),
                decoration: BoxDecoration(
                  color: isUser ? theme.colorScheme.primary : theme.colorScheme.surfaceContainer,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(16),
                    topRight: const Radius.circular(16),
                    bottomLeft: isUser ? const Radius.circular(16) : const Radius.circular(4),
                    bottomRight: isUser ? const Radius.circular(4) : const Radius.circular(16),
                  ),
                  border: isUser
                      ? null
                      : Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5), width: 1),
                  boxShadow: isUser
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.03),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                ),
                child: isUser
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (message.images != null && message.images!.isNotEmpty) _buildImagesGrid(message.images!),
                          if (message.content.isNotEmpty)
                            Text(message.content, style: TextStyle(color: theme.colorScheme.onPrimary, fontSize: 14)),
                        ],
                      )
                    : AnimatedSwitcher(
                        duration: AppMotion.duration(context, AppDurations.normal),
                        switchInCurve: AppCurves.emphasized,
                        switchOutCurve: AppCurves.exit,
                        layoutBuilder: (currentChild, previousChildren) {
                          return Stack(alignment: Alignment.topLeft, children: [...previousChildren, ?currentChild]);
                        },
                        child: statusText != null
                            ? _StreamingStatusCard(
                                key: const ValueKey('streaming_status'),
                                statusText: statusText,
                                startedAt: statusStartedAt,
                              )
                            : !hasRenderableBody
                            ? const MorphingInfinity(key: ValueKey('streaming_loading'))
                            : Column(
                                key: const ValueKey('streaming_body'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // 思考过程展示（若有，折叠在单行流水中滚动展示，点击可展开完整内容）
                                  // 连续工具聚合卡片或单工具执行反馈卡片
                                  if (message.role == 'tool_group')
                                    ToolChainGroupWidget(
                                      toolMessages: (message.uiDetails?['messages'] as List<ChatMessage>?) ?? const [],
                                      theme: theme,
                                    )
                                  else if (message.role == 'tool')
                                    buildToolFeedback(context, message, theme, onSendToQ: onSendToQ)
                                  else ...[
                                    MarkdownBody(
                                      data: message.content,
                                      selectable: false,
                                      // 拦截正文内联图：生图卡片已展示过的不再重复渲染，
                                      // 其余图片渲染为可点击放大/长按的统一视图而非默认裸 Image
                                      sizedImageBuilder: (config) => ChatBodyImage(
                                        src: config.uri.toString(),
                                        generatedImageKeys: generatedImageKeys,
                                        onSendToQ: onSendToQ,
                                      ),
                                      styleSheet: MarkdownStyleSheet(
                                        p: TextStyle(color: theme.colorScheme.onSurface, fontSize: 14, height: 1.5),
                                        h1: TextStyle(
                                          color: theme.colorScheme.onSurface,
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          height: 1.6,
                                        ),
                                        h2: TextStyle(
                                          color: theme.colorScheme.onSurface,
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          height: 1.5,
                                        ),
                                        h3: TextStyle(
                                          color: theme.colorScheme.onSurface,
                                          fontSize: 14,
                                          fontWeight: FontWeight.bold,
                                          height: 1.4,
                                        ),
                                        code: TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 13,
                                          // 行内代码贴浅色底，亮主题色原字会看不清，改中性墨色
                                          color: theme.colorScheme.onSurface,
                                          backgroundColor: Colors.transparent,
                                        ),
                                        codeblockDecoration: BoxDecoration(
                                          color: theme.colorScheme.surfaceContainerLow,
                                          borderRadius: BorderRadius.circular(8),
                                          border: Border.all(
                                            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
                                          ),
                                        ),
                                        blockquoteDecoration: BoxDecoration(
                                          color: theme.colorScheme.surfaceContainerLow,
                                          border: Border(left: BorderSide(color: theme.colorScheme.primary, width: 4)),
                                          borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
                                        ),
                                        blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                        listBullet: TextStyle(color: theme.colorScheme.onSurface),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                      ),
              ),
            ),
          ),
          // 助手正文气泡下方的连体操作条（复制/朗读/重新生成）
          if (showActionBar)
            Padding(
              padding: EdgeInsets.only(bottom: isLastInGroup ? 10 : 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: BubbleActionBar(
                  message: message,
                  onRegenerate: onRegenerate,
                  regenerateEnabled: regenerateEnabled,
                ),
              ),
            ),
          // 步数上限提示：待处理时在气泡下方渲染「继续/暂停」按钮
          if (!isUser && _isTurnLimitPending)
            AgentTurnLimitActions(onContinue: onContinue, onPause: onPause, enabled: actionsEnabled),
        ],
      ),
    );
  }

  /// 构建工具调用执行反馈与小Q确认交互卡片
  ///
  /// [onSendToQ] 供图片卡片的长按菜单「给小Q」使用，工具链折叠面板等无该语义的场景可不传。
  static Widget buildToolFeedback(
    BuildContext context,
    ChatMessage message,
    ThemeData theme, {
    ValueChanged<String>? onSendToQ,
  }) {
    final uiDetails = message.uiDetails;
    final isAskUser = message.toolName == 'ask_user' || uiDetails?['type'] == 'ask_user';

    if (isAskUser) {
      final question = uiDetails?['question'] as String? ?? message.content;
      final status = uiDetails?['status'] as String?;
      final choice = uiDetails?['choice'] as String?;
      final isConfirmed = status == 'confirmed';
      final isCancelled = status == 'cancelled';

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCancelled
                ? theme.colorScheme.outlineVariant.withValues(alpha: 0.5)
                : theme.colorScheme.primary.withValues(alpha: 0.25),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  '小Q询问',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                ),
                const Spacer(),
                if (isConfirmed)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.green.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.check, size: 12, color: Colors.green),
                        const SizedBox(width: 4),
                        Text(
                          choice != null ? '已选：$choice' : '已确认',
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.green),
                        ),
                      ],
                    ),
                  )
                else if (isCancelled)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.close, size: 12, color: theme.colorScheme.error),
                        const SizedBox(width: 4),
                        Text(
                          '已取消',
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: theme.colorScheme.error),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            MarkdownBody(
              data: question,
              selectable: false,
              styleSheet: MarkdownStyleSheet(
                p: TextStyle(color: theme.colorScheme.onSurface, fontSize: 13, height: 1.4),
              ),
            ),
          ],
        ),
      );
    }

    // generate_image 生图完成：气泡内直接大图预览，附模型与提示词摘要
    if (message.toolName == 'generate_image' && message.isError != true) {
      final paths = (uiDetails?['paths'] as List?)?.whereType<String>().toList() ?? const [];
      final model = uiDetails?['model'] as String? ?? '';
      final prompt = uiDetails?['prompt'] as String? ?? '';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(Icons.auto_awesome_rounded, size: 14, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 6),
                Text(
                  model.isEmpty ? '生图完成' : '生图完成 · $model',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: theme.colorScheme.onSurface),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final (index, path) in paths.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ChatImageView(
                    imagePath: path,
                    galleryImages: paths,
                    galleryIndex: index,
                    onSendToQ: onSendToQ,
                  ),
                ),
              ),
            if (prompt.isNotEmpty)
              Text(
                prompt,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface.withValues(alpha: 0.6)),
              ),
          ],
        ),
      );
    }

    // view_image 成功时图片已注入模型上下文，气泡里显示缩略图与路径摘要；失败走通用错误卡片
    if (message.toolName == 'view_image' && message.isError != true) {
      final path = uiDetails?['path'] as String? ?? '';
      final sizeKB = uiDetails?['sizeKB'];
      final sizeHint = sizeKB is int && sizeKB > 0 ? '（约 $sizeKB KB）' : '';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (path.isEmpty)
              const SizedBox(width: 40, height: 40)
            else
              ChatImageView(
                imagePath: path,
                width: 40,
                height: 40,
                borderRadius: const BorderRadius.all(Radius.circular(6)),
                onSendToQ: onSendToQ,
              ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                '已查看图片 $path$sizeHint',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.8)),
              ),
            ),
          ],
        ),
      );
    }

    // skill 工具加载手册过长，只显示调用的技能名与章节胶囊，支持点击查看完整手册，不占主消息流空间
    if (message.toolName == 'skill') {
      final isError = message.isError == true;
      final name = uiDetails?['name'] as String? ?? '';
      final section = uiDetails?['section'] as String?;
      final rawSkills = uiDetails?['skills'];
      final skillsList = rawSkills is List ? rawSkills.map((e) => e.toString()).toList() : null;

      if (isError) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message.content.trim().isNotEmpty ? message.content.trim() : '调用技能失败',
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        );
      }

      // 查看所有可用技能列表时的紧凑条
      if (skillsList != null) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome, size: 14, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '已查看技能列表 · ${skillsList.length} 个',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.85)),
                ),
              ),
              if (message.content.trim().isNotEmpty) ...[
                const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => _showSkillHandbookDialog(context, '技能列表', message.content),
                  child: Text(
                    '查看',
                    style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ],
          ),
        );
      }

      final skillTitle = name.isEmpty ? '技能手册' : name;
      final sectionHint = (section != null && section.trim().isNotEmpty) ? ' · $section' : '';

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.auto_awesome, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '已加载技能 · $skillTitle$sectionHint',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            if (message.content.trim().isNotEmpty) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _showSkillHandbookDialog(context, skillTitle, message.content),
                child: Text(
                  '查看',
                  style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // skill_market 的搜索/安装结果：搜索卡片可展开候选列表，安装结果只展示名称与来源
    if (message.toolName == 'skill_market') {
      final isError = message.isError == true;
      final action = uiDetails?['action'] as String? ?? '';
      final isInstall = action == 'install';
      final name = uiDetails?['name'] as String? ?? '';
      final source = uiDetails?['source'] as String? ?? '';
      final results = uiDetails?['results'];
      final count = results is List ? results.length : 0;

      final containerColor = isError
          ? theme.colorScheme.errorContainer.withValues(alpha: 0.3)
          : theme.colorScheme.primaryContainer.withValues(alpha: 0.2);
      final borderColor = isError
          ? theme.colorScheme.error.withValues(alpha: 0.3)
          : theme.colorScheme.outlineVariant.withValues(alpha: 0.4);
      final icon = isError
          ? Icons.error_outline
          : (isInstall ? Icons.download_done_rounded : Icons.travel_explore_rounded);
      final iconColor = isError ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant;
      final textColor = isError ? theme.colorScheme.error : theme.colorScheme.onSurface.withValues(alpha: 0.85);
      final title = isError
          ? (message.content.trim().isNotEmpty ? message.content.trim() : '技能市场操作失败')
          : switch (action) {
              'install' => '已安装技能 · $name${source.isEmpty ? '' : '（$source）'}',
              _ => '已搜索技能市场 · $count 个结果',
            };

      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: containerColor,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: iconColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: textColor),
              ),
            ),
            if (!isError && !isInstall && message.content.trim().isNotEmpty) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _showSkillHandbookDialog(context, '技能市场搜索结果', message.content),
                child: Text(
                  '查看',
                  style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // read_file 返回的文件正文过长，气泡里只显示路径摘要与预览按钮，错误时展示错误卡片
    if (message.toolName == 'read_file') {
      final isError = message.isError == true;
      final path = uiDetails?['path'] as String? ?? '';
      if (isError) {
        return Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: theme.colorScheme.error.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  message.content.trim().isNotEmpty
                      ? message.content.trim()
                      : (path.isNotEmpty ? '读取文件失败：$path' : '读取文件失败'),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
                ),
              ),
            ],
          ),
        );
      }

      final displayPath = path.isNotEmpty ? path : '文件';
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.description_outlined, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '已读取文件 $displayPath',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.8)),
              ),
            ),
            if (message.content.trim().isNotEmpty) ...[
              const SizedBox(width: 6),
              GestureDetector(
                onTap: () => _showFilePreviewDialog(context, displayPath, message.content),
                child: Text(
                  '预览',
                  style: TextStyle(fontSize: 11, color: theme.colorScheme.onSurface, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ],
        ),
      );
    }

    // list_dir 目录遍历结果折叠展示，防止几十条条目拉长屏幕
    if (message.toolName == 'list_dir') {
      return _DirectoryFeedbackWidget(message: message, theme: theme);
    }

    // grep 全局检索结果折叠展示
    if (message.toolName == 'grep') {
      return _GrepFeedbackWidget(message: message, theme: theme);
    }

    // fetch_url 返回的网页正文过长，气泡里只显示标题摘要，点击可打开原网页
    if (message.toolName == 'fetch_url') {
      final url = uiDetails?['url'] as String? ?? '';
      final title = (uiDetails?['title'] as String? ?? '').trim();
      final hasError = message.isError == true;
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              hasError ? Icons.link_off : Icons.language,
              size: 14,
              color: hasError ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                title.isEmpty ? '已读取网页 $url' : '已读取网页：$title',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurface.withValues(alpha: 0.8)),
              ),
            ),
            // 点击卡片用系统浏览器打开原网页，方便用户核对来源
            if (!hasError && url.isNotEmpty)
              GestureDetector(
                onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
                child: Icon(Icons.open_in_new, size: 14, color: theme.colorScheme.onSurfaceVariant),
              ),
          ],
        ),
      );
    }

    return _GenericToolFeedbackWidget(message: message, theme: theme);
  }

  /// 用户消息里的附件图片网格：单图大图展示，多图九宫格缩略，均可点击放大与长按操作
  Widget _buildImagesGrid(List<String> images) {
    if (images.length == 1) {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 200, maxHeight: 200),
          child: ChatImageView(
            imagePath: images.first,
            galleryImages: images,
            borderRadius: const BorderRadius.all(Radius.circular(10)),
            onSendToQ: onSendToQ,
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          for (final (index, imgPath) in images.indexed)
            ChatImageView(
              imagePath: imgPath,
              galleryImages: images,
              galleryIndex: index,
              width: 68,
              height: 68,
              onSendToQ: onSendToQ,
            ),
        ],
      ),
    );
  }

  /// 技能手册查看弹窗：避免大段 Markdown 技能说明直接在主对话流刷屏
  static void _showSkillHandbookDialog(BuildContext context, String skillName, String content) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.of(context).size.height * 0.75),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.auto_awesome, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '技能手册 · $skillName',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const Divider(height: 20),
                Flexible(
                  child: SingleChildScrollView(child: MarkdownBody(data: content, selectable: true)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 文件内容预览弹窗：点击「预览」按钮按需查看，避免正文长篇大论挤占对话空间
  static void _showFilePreviewDialog(BuildContext context, String filePath, String content) {
    final theme = Theme.of(context);
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: 600, maxHeight: MediaQuery.of(context).size.height * 0.75),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.description_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '文件预览 · $filePath',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(ctx),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ],
                ),
                const Divider(height: 20),
                Flexible(
                  child: SingleChildScrollView(
                    child: SelectableText(
                      content,
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                        color: theme.colorScheme.onSurface,
                        height: 1.45,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _TypingBubble extends StatelessWidget {
  final bool isFirstInGroup;
  final bool isLastInGroup;

  const _TypingBubble({this.isFirstInGroup = true, this.isLastInGroup = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0.0, end: 1.0),
      duration: AppMotion.duration(context, AppDurations.fast),
      curve: AppCurves.emphasized,
      builder: (context, value, child) {
        return Opacity(
          opacity: value,
          child: Transform.translate(offset: Offset(0, (1 - value) * 8), child: child),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (isFirstInGroup)
            Padding(
              padding: const EdgeInsets.only(bottom: 6, left: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const QAvatar(size: 24, withBackground: true),
                  const SizedBox(width: 6),
                  Text(
                    '小Q',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Container(
              margin: EdgeInsets.only(bottom: isLastInGroup ? 16 : 4),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainer,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(16),
                ),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5), width: 1),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.03), blurRadius: 8, offset: const Offset(0, 2)),
                ],
              ),
              child: MorphingInfinity(size: 26, strokeWidth: 1.6, color: theme.colorScheme.primary),
            ),
          ),
        ],
      ),
    );
  }
}

/// 输入区功能胶囊：图标 + 文案 + 可选尾部箭头，点击触发对应设置
class _InputPill extends StatelessWidget {
  final IconData icon;
  final String label;

  /// 尾部固定展示的次要文案（如思考强度档位）
  ///
  /// 与 [label] 分开是因为 [label] 会被省略号截断：模型名再长也不能把档位挤没，
  /// 否则用户看不到当前思考强度。
  final String? suffix;
  final IconData? trailing;
  final VoidCallback onTap;

  const _InputPill({required this.icon, required this.label, this.suffix, this.trailing, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.onSurfaceVariant;
    return Material(
      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: color),
                ),
              ),
              if (suffix != null)
                Text(' · $suffix', maxLines: 1, style: theme.textTheme.bodySmall?.copyWith(color: color)),
              if (trailing != null) ...[const SizedBox(width: 2), Icon(trailing, size: 14, color: color)],
            ],
          ),
        ),
      ),
    );
  }
}

/// 流式占位卡：思考步骤行在上，进行中的动作/排队状态行在下
///
/// 顺序与落库后的时间线一致（思考 → 工具/正文）。早期把状态行排在思考上方，
/// 工具调用状态一出现，思考行就被挤到下面，落库后又跳回上方，看起来像顺序颠倒。
class _StreamingStatusCard extends ConsumerWidget {
  final String statusText;

  /// 本轮任务开始时间，状态行尾部显示「已用时」递增计数
  final DateTime? startedAt;

  const _StreamingStatusCard({super.key, required this.statusText, this.startedAt});

  /// 「思考中/准备中」只表示任务在跑，思考步骤行（含计时与呼吸动画）
  /// 已经表达同一信息，不再重复占一行
  static bool _isThinkingStatus(String text) => text.startsWith('小Q思考中') || text.startsWith('小Q准备中');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final hasThought = ref.watch(aiStreamingThoughtProvider)?.trim().isNotEmpty ?? false;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const _LiveThoughtView(),
        if (!hasThought || !_isThinkingStatus(statusText))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Flexible(
                  child: Text(
                    statusText,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 14, height: 1.5),
                  ),
                ),
                // 思考中采用形变无限符号动画，流动生命力替代三个跳动圆点
                Padding(
                  padding: const EdgeInsets.only(left: 8, right: 6),
                  child: MorphingInfinity(size: 21, strokeWidth: 1.5, color: theme.colorScheme.primary),
                ),
                // 已用时递增计数：长任务期间传达"仍在推进，没有卡住"
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: StreamingElapsedText(
                    startedAt: startedAt,
                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// 「思考中」状态卡内的实时思考区：折叠态单行滚动展示最新思考，展开看全文
class _LiveThoughtView extends ConsumerWidget {
  const _LiveThoughtView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final thought = ref.watch(aiStreamingThoughtProvider);
    if (thought == null || thought.trim().isEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ThinkingProcessView(
        thought: thought.trim(),
        isStreaming: true,
        startedAt: ref.watch(aiStreamingTurnStartedAtProvider),
      ),
    );
  }
}
