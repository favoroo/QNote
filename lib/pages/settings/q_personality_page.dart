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
  const QPersonalityPage({super.key});

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
    final service = QPersonalityService.instance;
    final activeId = await service.getActiveId();
    _customController.text = await service.getCustomPrompt();
    if (!mounted) return;
    setState(() {
      _activeId = activeId;
      _loading = false;
    });
  }

  Future<void> _select(String id) async {
    if (id == _activeId) return;
    setState(() => _activeId = id);
    try {
      await QPersonalityService.instance.setActiveId(id);
      if (!mounted) return;
      if (id == QPersonalities.customId && _customController.text.trim().isEmpty) {
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
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('小Q个性'),
        centerTitle: false,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  '个性决定小Q的身份与说话风格，不影响它的任何能力；'
                  '切换后下轮对话生效。也可以直接对小Q说「你以后活泼一点」。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 16),
                ...QPersonalities.presets.map(
                  (p) => _buildPresetCard(context, p),
                ),
                if (_activeId == QPersonalities.customId) ...[
                  const SizedBox(height: 12),
                  _buildCustomEditor(context),
                ],
                const SizedBox(height: 20),
              ],
            ),
    );
  }

  /// 单个预设卡片：选中态高亮 + 自定义时附编辑区
  Widget _buildPresetCard(BuildContext context, QPersonality preset) {
    final theme = Theme.of(context);
    final selected = preset.id == _activeId;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => _select(preset.id),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: selected
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
                : theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: selected
                  ? theme.colorScheme.primary.withValues(alpha: 0.6)
                  : theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
              width: selected ? 1.5 : 1,
            ),
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
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.name,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
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
    );
  }

  /// 自定义人格编辑区：多行输入 + 保存按钮
  Widget _buildCustomEditor(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '自定义人格描述（3~6 句，写清身份、语气与风格）',
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
              hintText: '例如：你是一位说话带点幽默感的极简主义助手，'
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
