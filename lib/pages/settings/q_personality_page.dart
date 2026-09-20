import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/agent/prompts/q_personalities.dart';
import 'package:qnote_flutter/core/agent/services/q_personality_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 小Q个性设置页
///
/// 对齐 Hermes SOUL.md 语义：个性只改变身份与语气，能力规范保持内置不变；
/// 切换后下轮对话生效（对齐记忆的冻结快照注入时机）。
/// 与小Q经 VFS `/settings/personality.json` 的自我调整为同一份数据，双向同步。
///
/// 顶部「当前生效」卡片直接展示运行时真正注入系统提示词的那段人格文本（[QPersonality.prompt]），
/// 包括「自定义但内容为空 → 实际回退经典管家」这类静默降级，避免用户设置了却看不出生效没有。
class QPersonalityPage extends StatefulWidget {
  const QPersonalityPage({super.key, this.embedded = false});

  /// 嵌入模式：由综合设置页承载时为 true，不重复生成外层 Scaffold 与 AppBar
  final bool embedded;

  @override
  State<QPersonalityPage> createState() => _QPersonalityPageState();
}

class _QPersonalityPageState extends State<QPersonalityPage> {
  final TextEditingController _customController = TextEditingController();
  String _activeId = QPersonalities.defaultId;

  /// 运行时真正生效的个性（含回退结果），驱动顶部「当前生效」卡片
  QPersonality? _effective;

  /// 是否发生了「选了自定义却因描述为空而回退」的静默降级（由快照判定，卡片据此提示）
  bool _degraded = false;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  /// 写操作后重读一次快照：让「选中项」与「实际生效」始终取自同一份存储状态，
  /// 也顺带刷新降级标记，避免界面显示的和真正注入系统提示词的那段人格脱节
  Future<QPersonalitySnapshot> _refreshFromStore() async {
    final snapshot = await QPersonalityService.instance.readSnapshot();
    if (mounted) {
      setState(() {
        _activeId = snapshot.selectedId;
        _effective = snapshot.effective;
        _degraded = snapshot.degradedToFallback;
      });
    }
    return snapshot;
  }

  Future<void> _loadConfig() async {
    try {
      // 单次快照读：选中态、自定义原文、实际生效个性同源，不会出现三次读取拼出两个版本
      final snapshot = await QPersonalityService.instance.readSnapshot();
      if (!mounted) return;
      _customController.text = snapshot.customPrompt;
      setState(() {
        _activeId = snapshot.selectedId;
        _effective = snapshot.effective;
        _degraded = snapshot.degradedToFallback;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _select(String id) async {
    if (id == _activeId) return;
    setState(() => _activeId = id);
    try {
      await QPersonalityService.instance.setActiveId(id);
      final snapshot = await _refreshFromStore();
      if (!mounted) return;
      if (snapshot.degradedToFallback) {
        Toast.warning(context, '已选择自定义，但人格描述为空：当前仍按「经典管家」说话');
      }
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  /// 保存自定义人格文本；[alsoActivate] 为 true 时顺带切到自定义个性（省一次点击）
  Future<void> _saveCustomPrompt({bool alsoActivate = false}) async {
    final text = _customController.text.trim();
    try {
      await QPersonalityService.instance.setCustomPrompt(text);
      if (alsoActivate) {
        await QPersonalityService.instance.setActiveId(QPersonalities.customId);
      }
      final snapshot = await _refreshFromStore();
      if (!mounted) return;
      if (text.isEmpty) {
        Toast.warning(
          context,
          '自定义人格已清空，实际说话风格回退为「${snapshot.effective.name}」',
        );
      } else if (alsoActivate) {
        Toast.success(context, '已保存并启用，下轮对话开始这样说话');
      } else {
        Toast.success(context, '自定义人格已保存');
      }
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final body = _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _buildEffectiveCard(context),
              const SizedBox(height: 12),
              ...QPersonalities.presets.map(
                (p) => _buildPresetCard(context, p),
              ),
              if (_activeId == QPersonalities.customId) ...[
                const SizedBox(height: 12),
                _buildCustomEditor(context),
              ],
              const SizedBox(height: 20),
            ],
          );

    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('小Q个性'), centerTitle: false),
      body: body,
    );
  }

  /// 「当前生效」卡片：直接回显运行时真正注入系统提示词的人格文本，
  /// 并把「选了自定义却因描述为空而静默回退」这类用户最容易误判成没生效的情况显式标出来
  Widget _buildEffectiveCard(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final effective = _effective;
    if (effective == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainerHigh.withValues(alpha: 0.55)
            : theme.colorScheme.primary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: _degraded
              ? theme.colorScheme.tertiary.withValues(alpha: 0.65)
              : theme.colorScheme.primary.withValues(alpha: 0.5),
          width: 1.2,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.auto_awesome_rounded,
                size: 18,
                color: theme.colorScheme.primary,
              ),
              const SizedBox(width: 8),
              Text(
                '当前生效个性',
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const Spacer(),
              Text(
                effective.name,
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (_degraded) ...[
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              decoration: BoxDecoration(
                color: theme.colorScheme.tertiaryContainer.withValues(alpha: 0.75),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 16,
                    color: theme.colorScheme.onTertiaryContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '自定义人格描述还是空的，所以小Q实际仍按「${effective.name}」说话。'
                      '在下方填写描述后点「保存并启用」即可切换。',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onTertiaryContainer,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          const SizedBox(height: 10),
          Text(
            effective.prompt,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
              height: 1.5,
            ),
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          Text(
            '这段话每轮对话都会注入小Q的系统提示词：开头作为「人格与身份」小节，'
            '结尾的环境上下文里再复述一次语气要点。修改后下一条消息生效。',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.85),
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// 单个预设卡片：选中态高亮 + 自定义时附编辑区
  Widget _buildPresetCard(BuildContext context, QPersonality preset) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selected = preset.id == _activeId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(24),
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => _select(preset.id),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeInOut,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: selected
                  ? (isDark
                        ? theme.colorScheme.surfaceContainerHigh.withValues(
                            alpha: 0.6,
                          )
                        : theme.colorScheme.primary.withValues(alpha: 0.035))
                  : theme.colorScheme.surface,
              borderRadius: BorderRadius.circular(24),
              border: Border.all(
                color: selected
                    ? theme.colorScheme.primary.withValues(alpha: 0.85)
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.45),
                width: selected ? 1.5 : 1,
              ),
              boxShadow: selected
                  ? [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(
                          alpha: isDark ? 0.20 : 0.08,
                        ),
                        blurRadius: 14,
                        offset: const Offset(0, 4),
                      ),
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.15 : 0.02,
                        ),
                        blurRadius: 4,
                        offset: const Offset(0, 1),
                      ),
                    ]
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(
                          alpha: isDark ? 0.10 : 0.02,
                        ),
                        blurRadius: 8,
                        offset: const Offset(0, 2),
                      ),
                    ],
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 22,
                  color: selected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.9),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              preset.name,
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: selected
                                    ? FontWeight.bold
                                    : FontWeight.w600,
                                color: selected
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.onSurface,
                              ),
                            ),
                          ),
                          if (selected) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 1.5,
                              ),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.primary.withValues(
                                  alpha: isDark ? 0.20 : 0.10,
                                ),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '使用中',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.w600,
                                  color: theme.colorScheme.primary,
                                  height: 1.2,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        preset.description,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 自定义人格编辑区：多行输入 + 保存按钮
  Widget _buildCustomEditor(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.12 : 0.02),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自定义人格描述',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _customController,
            maxLines: 5,
            minLines: 3,
            maxLength: 400,
            textInputAction: TextInputAction.newline,
            // 实时回显尾部语气摘要预览，让用户看到这句话将如何被钉在提示词结尾
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              hintText:
                  '例如：你是一位说话带点幽默感的极简主义助手，'
                  '喜欢用短句，偶尔打个比方，讨厌啰嗦……',
              border: OutlineInputBorder(),
            ),
          ),
          if (_customController.text.trim().isNotEmpty) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.arrow_drop_down_circle_outlined,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '结尾复述句：${QPersonalityService.digestOf(_customController.text)}',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.45,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              OutlinedButton(
                onPressed: () => _saveCustomPrompt(),
                child: const Text('保存'),
              ),
              const SizedBox(width: 10),
              FilledButton.tonal(
                onPressed: () => _saveCustomPrompt(alsoActivate: true),
                child: const Text('保存并启用'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
