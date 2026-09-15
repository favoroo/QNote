import 'package:flutter/material.dart';

import 'package:qnote_flutter/core/agent/prompts/q_personalities.dart';
import 'package:qnote_flutter/core/agent/services/q_personality_service.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';

/// 小Q个性设置页
///
/// 对齐 Hermes SOUL.md 语义：个性只改变身份与语气，能力规范保持内置不变；
/// 切换后下轮对话生效（对齐记忆的冻结快照注入时机）。
/// 与小Q经 VFS `/settings/personality.json` 的自我调整为同一份数据，双向同步。
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

  Future<void> _loadConfig() async {
    try {
      final service = QPersonalityService.instance;
      final activeId = await service.getActiveId();
      _customController.text = await service.getCustomPrompt();
      if (!mounted) return;
      setState(() {
        _activeId = activeId;
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
      if (!mounted) return;
      if (id == QPersonalities.customId &&
          _customController.text.trim().isEmpty) {
        Toast.warning(context, '已选择自定义，请在下方填写人格描述');
      }
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  Future<void> _saveCustomPrompt() async {
    final text = _customController.text.trim();
    try {
      await QPersonalityService.instance.setCustomPrompt(text);
      if (!mounted) return;
      Toast.success(context, text.isEmpty ? '已清空自定义人格' : '自定义人格已保存');
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
            decoration: const InputDecoration(
              hintText:
                  '例如：你是一位说话带点幽默感的极简主义助手，'
                  '喜欢用短句，偶尔打个比方，讨厌啰嗦……',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: FilledButton.tonal(
              onPressed: _saveCustomPrompt,
              child: const Text('保存'),
            ),
          ),
        ],
      ),
    );
  }
}
