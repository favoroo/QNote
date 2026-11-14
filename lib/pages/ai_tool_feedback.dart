part of 'ai_page.dart';
// 从 ai_page_widgets.dart 拆分：工具结果反馈卡片、工具链分组与折叠内容区。

/// 目录列表折叠反馈组件：条目较多时默认折叠，显示前 3 项与总计，支持平滑展开和内滚动
/// 通用工具结果反馈组件（未被专属卡片覆盖的工具兜底）：
/// 成功结果默认折叠成单行标签条（如「识别图片 · 路径」），点击展开查看正文，
/// 避免识图、联网搜索等长结果直接铺满聊天流；错误信息不折叠，保持立即可见。
class _GenericToolFeedbackWidget extends StatefulWidget {
  final ChatMessage message;
  final ThemeData theme;

  /// 嵌入工作流折叠时间线时去掉外层卡片边框底色，避免多层嵌套框
  final bool flat;

  const _GenericToolFeedbackWidget({required this.message, required this.theme, this.flat = false});

  @override
  State<_GenericToolFeedbackWidget> createState() => _GenericToolFeedbackWidgetState();
}

class _GenericToolFeedbackWidgetState extends State<_GenericToolFeedbackWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final message = widget.message;
    final isError = message.isError == true;
    final hasBody = message.content.trim().isNotEmpty;
    final label = AgentToolLabels.resultLabel(message.toolName ?? '', message.uiDetails);

    final markdownSheet = MarkdownStyleSheet(
      p: TextStyle(color: theme.colorScheme.onSurface, fontSize: 14, height: 1.5),
      h1: TextStyle(color: theme.colorScheme.onSurface, fontSize: 18, fontWeight: FontWeight.bold, height: 1.6),
      h2: TextStyle(color: theme.colorScheme.onSurface, fontSize: 16, fontWeight: FontWeight.bold, height: 1.5),
      h3: TextStyle(color: theme.colorScheme.onSurface, fontSize: 14, fontWeight: FontWeight.bold, height: 1.4),
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
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      blockquoteDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(left: BorderSide(color: theme.accentInk, width: 4)),
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(6)),
      ),
      blockquotePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      listBullet: TextStyle(color: theme.colorScheme.onSurface),
    );

    Widget buildBody() => ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 220),
      child: SingleChildScrollView(
        child: MarkdownBody(data: message.content, selectable: false, styleSheet: markdownSheet),
      ),
    );

    // 错误信息直接展示：失败原因需要立即可见，不参与折叠
    if (isError) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.error_outline, size: 14, color: theme.colorScheme.error),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: theme.colorScheme.error),
                ),
              ],
            ),
          ),
          if (hasBody) buildBody(),
        ],
      );
    }

    final header = InkWell(
      onTap: hasBody ? () => setState(() => _isExpanded = !_isExpanded) : null,
      borderRadius: BorderRadius.circular(widget.flat ? 8 : 10),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.flat ? 2 : 10, vertical: widget.flat ? 4 : 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 15, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (hasBody) ...[
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _isExpanded ? 0.5 : 0,
                duration: AppMotion.duration(context, AppDurations.normal),
                curve: AppCurves.emphasized,
                child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );

    final body = _CollapsibleToolBody(
      expanded: _isExpanded,
      hasBody: hasBody,
      showDivider: !widget.flat,
      bodyBuilder: (context) => widget.flat
          ? Container(
              margin: const EdgeInsets.only(left: 20, top: 2, bottom: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35)),
              ),
              child: buildBody(),
            )
          : Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8), child: buildBody()),
    );

    if (widget.flat) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [header, body],
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部折叠条：工具标签 + 关键信息摘要，点击展开/收起正文
          header,
          // 展开内容区：长结果带滚动上限，与目录/检索折叠卡一致
          body,
        ],
      ),
    );
  }
}

class _DirectoryFeedbackWidget extends StatefulWidget {
  final ChatMessage message;
  final ThemeData theme;

  /// 嵌入工作流折叠时间线时去掉外层卡片边框底色
  final bool flat;

  const _DirectoryFeedbackWidget({required this.message, required this.theme, this.flat = false});

  @override
  State<_DirectoryFeedbackWidget> createState() => _DirectoryFeedbackWidgetState();
}

class _DirectoryFeedbackWidgetState extends State<_DirectoryFeedbackWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final message = widget.message;
    final isError = message.isError == true;
    final uiDetails = message.uiDetails;
    final path = uiDetails?['path'] as String? ?? '';
    final rawItems = uiDetails?['items'];
    final items = rawItems is List ? rawItems.map((e) => e.toString()).toList() : null;

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
                message.content.trim().isNotEmpty ? message.content.trim() : '查看目录失败',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final totalCount = items?.length ?? message.content.split('\n').where((l) => l.trim().isNotEmpty).length;
    final displayList = items ?? message.content.split('\n').where((l) => l.trim().isNotEmpty).toList();

    final pathHint = path.isNotEmpty ? path : '/';

    final header = InkWell(
      onTap: totalCount == 0 ? null : () => setState(() => _isExpanded = !_isExpanded),
      borderRadius: BorderRadius.circular(widget.flat ? 8 : 10),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.flat ? 2 : 10, vertical: widget.flat ? 4 : 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open_outlined, size: 15, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                totalCount == 0 ? '已查看目录 $pathHint（空）' : '已查看目录 $pathHint（$totalCount 项）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (totalCount > 0) ...[
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _isExpanded ? 0.5 : 0,
                duration: AppMotion.duration(context, AppDurations.normal),
                curve: AppCurves.emphasized,
                child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );

    final listContent = Container(
      constraints: const BoxConstraints(maxHeight: 180),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: displayList.map((item) {
            final isDir = item.endsWith('/');
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Icon(
                    isDir ? Icons.folder_outlined : Icons.insert_drive_file_outlined,
                    size: 13,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      item,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.8),
                      ),
                    ),
                  ),
                ],
              ),
            );
          }).toList(),
        ),
      ),
    );

    final body = _CollapsibleToolBody(
      expanded: _isExpanded,
      hasBody: displayList.isNotEmpty,
      showDivider: !widget.flat,
      bodyBuilder: (context) => widget.flat
          ? Container(
              margin: const EdgeInsets.only(left: 20, top: 2, bottom: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35)),
              ),
              child: listContent,
            )
          : listContent,
    );

    if (widget.flat) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [header, body],
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 头部胶囊：目录路径 + 条目总数 + 展开/收起按钮
          header,
          // 展开内容区：当条目数较多时提供带滚动的列表
          body,
        ],
      ),
    );
  }
}

/// 全局 grep 检索折叠反馈组件：命中条目过多时折叠
class _GrepFeedbackWidget extends StatefulWidget {
  final ChatMessage message;
  final ThemeData theme;

  /// 嵌入工作流折叠时间线时去掉外层卡片边框底色
  final bool flat;

  const _GrepFeedbackWidget({required this.message, required this.theme, this.flat = false});

  @override
  State<_GrepFeedbackWidget> createState() => _GrepFeedbackWidgetState();
}

class _GrepFeedbackWidgetState extends State<_GrepFeedbackWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final message = widget.message;
    final isError = message.isError == true;
    final uiDetails = message.uiDetails;
    final query = uiDetails?['query'] as String? ?? '';
    final total = uiDetails?['total'] as int? ?? 0;

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
                message.content.trim().isNotEmpty ? message.content.trim() : '搜索失败',
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final queryHint = query.isNotEmpty ? '「$query」' : '';

    final header = InkWell(
      onTap: total == 0 ? null : () => setState(() => _isExpanded = !_isExpanded),
      borderRadius: BorderRadius.circular(widget.flat ? 8 : 10),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: widget.flat ? 2 : 10, vertical: widget.flat ? 4 : 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_rounded, size: 15, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                total == 0 ? '搜索笔记 $queryHint（未找到）' : '搜索笔记 $queryHint（$total 条）',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                ),
              ),
            ),
            if (total > 0) ...[
              const SizedBox(width: 4),
              AnimatedRotation(
                turns: _isExpanded ? 0.5 : 0,
                duration: AppMotion.duration(context, AppDurations.normal),
                curve: AppCurves.emphasized,
                child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: theme.colorScheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );

    final bodyContent = Container(
      constraints: const BoxConstraints(maxHeight: 200),
      padding: const EdgeInsets.all(10),
      child: SingleChildScrollView(child: MarkdownBody(data: message.content, selectable: true)),
    );

    final body = _CollapsibleToolBody(
      expanded: _isExpanded,
      hasBody: message.content.trim().isNotEmpty,
      showDivider: !widget.flat,
      bodyBuilder: (context) => widget.flat
          ? Container(
              margin: const EdgeInsets.only(left: 20, top: 2, bottom: 4),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35)),
              ),
              child: bodyContent,
            )
          : bodyContent,
    );

    if (widget.flat) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [header, body],
      );
    }

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [header, body],
      ),
    );
  }
}

/// 连续工具调用链（多步操作）聚合折叠组件：
/// 当 Agent 连续执行多项工具操作（如连续 read_file、list_dir 等）时，
/// 聚合成一个「执行步骤」折叠面板，折叠态只占一行，展开后呈现紧凑步骤清单。
class ToolChainGroupWidget extends StatefulWidget {
  final List<ChatMessage> toolMessages;
  final ThemeData theme;

  const ToolChainGroupWidget({super.key, required this.toolMessages, required this.theme});

  @override
  State<ToolChainGroupWidget> createState() => _ToolChainGroupWidgetState();
}

class _ToolChainGroupWidgetState extends State<ToolChainGroupWidget> {
  bool _isExpanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = widget.theme;
    final messages = widget.toolMessages;
    final totalCount = messages.length;
    final hasError = messages.any((m) => m.isError == true);

    // 统计工具类型分布，如「读取文件 3 个、查看目录 1 次」
    final countsByType = <String, int>{};
    for (final m in messages) {
      final name = m.toolName ?? '操作';
      countsByType[name] = (countsByType[name] ?? 0) + 1;
    }

    final summarySegments = <String>[];
    countsByType.forEach((toolName, count) {
      final label = AgentToolLabels.resultLabel(toolName);
      summarySegments.add('$label $count 项');
    });
    final summaryText = summarySegments.join('、');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // 头部总览条：扁平步骤行，点击展开/折叠全部步骤。
        // 不再包一层带底色的卡片：外层已经是消息时间线，再套一层会出现
        // 「气泡底 + 工具链底」的双层背景，并把上下间距撑得很大。
        InkWell(
          onTap: () => setState(() => _isExpanded = !_isExpanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            // 与思考行的标题行同高：扁平时间线里两行节奏一致，也保留可点区域
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
            child: Row(
              children: [
                Icon(
                  hasError ? Icons.error_outline : Icons.task_alt_rounded,
                  size: 15,
                  color: hasError ? theme.colorScheme.error : theme.accentInk,
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    '已连续完成 $totalCount 步 · $summaryText',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: hasError ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                AnimatedRotation(
                  turns: _isExpanded ? 0.5 : 0,
                  duration: AppMotion.duration(context, AppDurations.normal),
                  curve: AppCurves.emphasized,
                  child: Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: theme.colorScheme.outline),
                ),
              ],
            ),
          ),
        ),
        // 展开状态：逐条紧凑渲染每一个工具的专属反馈卡。
        // 左侧缩进对齐头部文案，形成时间线层级；内容过长仍限高内滚。
        _CollapsibleToolBody(
          expanded: _isExpanded,
          hasBody: messages.isNotEmpty,
          showDivider: false,
          bodyBuilder: (context) => Container(
            constraints: const BoxConstraints(maxHeight: 280),
            padding: const EdgeInsets.only(left: 21, top: 1, bottom: 2),
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (int i = 0; i < messages.length; i++) ...[
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsets.only(top: 7, right: 6),
                            child: Container(
                              width: 16,
                              height: 16,
                              // 步骤序号改实心主题色小圆，淡底配同色数字看不清
                              decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                              child: Center(
                                child: Text(
                                  '${i + 1}',
                                  style: TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.bold,
                                    color: theme.colorScheme.onPrimary,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          Expanded(child: ChatBubble.buildToolFeedback(context, messages[i], theme)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 工具卡片的折叠内容区。
///
/// 展开时高度随内容增长，收起时先淡出内容再收拢高度，避免 `if (expanded)`
/// 直接插入/移除导致的整行瞬跳。内容通过 [bodyBuilder] 懒构建，折叠态不解析
/// 文件正文或目录列表。
class _CollapsibleToolBody extends StatelessWidget {
  final bool expanded;
  final bool hasBody;
  final WidgetBuilder bodyBuilder;

  /// 是否在内容上方画分隔线；扁平工具链头部不需要，带底色的工具卡需要
  final bool showDivider;

  const _CollapsibleToolBody({
    required this.expanded,
    required this.hasBody,
    required this.bodyBuilder,
    this.showDivider = true,
  });

  @override
  Widget build(BuildContext context) {
    final active = expanded && hasBody;
    // 复用统一 AppCollapsible：收起时保留内容同步淡出并收拢高度，避免先前先等 150ms 再缩空白的两段脱节
    return AppCollapsible(
      expanded: active,
      rise: 0,
      child: active
          ? Column(
              key: const ValueKey('tool_body'),
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [if (showDivider) const Divider(height: 1), bodyBuilder(context)],
            )
          : const SizedBox.shrink(),
    );
  }
}
