import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:qnote_flutter/core/agent/skills/skill_registry.dart';
import 'package:qnote_flutter/core/utils/toast_utils.dart';
import 'package:qnote_flutter/models/agent_skill.dart';
import 'package:qnote_flutter/providers/agent_skill_provider.dart';

/// 小Q技能编辑/查看页
///
/// 三种模式：内置技能只读查看（[builtinName]）、新建用户技能（两者皆空）、
/// 编辑既有用户技能（[skill]）。用户技能保存后经 Provider 持久化到
/// app_configs 并同步技能索引；内置技能不可修改。
class QSkillEditPage extends ConsumerStatefulWidget {
  final String? builtinName;
  final AgentSkill? skill;

  const QSkillEditPage({super.key, this.builtinName, this.skill});

  @override
  ConsumerState<QSkillEditPage> createState() => _QSkillEditPageState();
}

class _QSkillEditPageState extends ConsumerState<QSkillEditPage> {
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _contentController;
  late final bool _isViewMode;

  @override
  void initState() {
    super.initState();
    _isViewMode = widget.builtinName != null;
    final builtinContent = _isViewMode
        ? SkillRegistry.instance.getSkillContent(widget.builtinName!) ?? ''
        : '';
    _nameController = TextEditingController(
      text: _isViewMode ? widget.builtinName : widget.skill?.name ?? '',
    );
    _descriptionController = TextEditingController(
      text: _isViewMode ? _builtinDescription(builtinContent) : widget.skill?.description ?? '',
    );
    _contentController = TextEditingController(
      text: _isViewMode ? _stripFrontmatter(builtinContent) : widget.skill?.content ?? '',
    );
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  /// 从内置手册中提取 frontmatter 的 description（查看模式展示用）
  String _builtinDescription(String doc) {
    final match = RegExp(r'^description:\s*(.+)$', multiLine: true).firstMatch(doc);
    return match?.group(1)?.trim() ?? '';
  }

  /// 剥离手册开头的 YAML frontmatter，仅展示正文
  String _stripFrontmatter(String doc) {
    if (!doc.startsWith('---')) return doc;
    final secondDash = doc.indexOf('---', 3);
    if (secondDash == -1) return doc;
    return doc.substring(secondDash + 3).trim();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final readOnly = _isViewMode;
    final isEditingExisting = widget.skill != null;

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _isViewMode ? '技能详情' : (isEditingExisting ? '编辑技能' : '新建技能'),
        ),
        centerTitle: false,
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // 技能名称：内置只读、编辑时锁定（改名校验复杂，直接不可改）
          TextField(
            controller: _nameController,
            readOnly: readOnly || isEditingExisting,
            enabled: !(readOnly || isEditingExisting),
            decoration: InputDecoration(
              labelText: '技能名称（对应 /skills/<名称>.md）',
              hintText: '例如：投资复盘',
              helperText: readOnly || isEditingExisting ? null : '创建后不可修改；不能与内置技能重名',
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _descriptionController,
            readOnly: readOnly,
            decoration: const InputDecoration(
              labelText: '一句话描述',
              hintText: '说明这份手册适用于什么场景，将展示在技能索引中',
            ),
          ),
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '手册正文（Markdown）',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _contentController,
            readOnly: readOnly,
            maxLines: null,
            minLines: 12,
            keyboardType: TextInputType.multiline,
            decoration: InputDecoration(
              alignLabelWithHint: true,
              hintText: _isViewMode
                  ? ''
                  : '按章节组织的手册内容，建议使用「## 1. 标题」二级标题分章，'
                      '小Q可按章节按需加载（section 参数）',
              border: const OutlineInputBorder(),
            ),
          ),
          if (!readOnly) ...[
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_outlined),
              label: const Text('保存技能'),
            ),
            const SizedBox(height: 8),
          ],
          if (isEditingExisting) ...[
            const SizedBox(height: 4),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: theme.colorScheme.error,
              ),
              onPressed: _confirmDelete,
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('删除该技能'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final description = _descriptionController.text.trim();
    final content = _contentController.text.trim();

    if (!AgentSkill.isValidName(name)) {
      Toast.warning(context, '技能名称不能为空、含空白或路径分隔符，且不超过 40 字');
      return;
    }
    if (description.isEmpty) {
      Toast.warning(context, '请填写一句话描述，便于在技能索引中识别');
      return;
    }
    if (content.isEmpty) {
      Toast.warning(context, '手册正文不能为空');
      return;
    }

    try {
      await ref.read(agentSkillListProvider.notifier).saveUserSkill(
            AgentSkill(name: name, description: description, content: content),
          );
      if (!mounted) return;
      Toast.success(context, '已保存技能「$name」');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '保存失败：$e');
    }
  }

  Future<void> _confirmDelete() async {
    final skill = widget.skill!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除技能'),
        content: Text('确定删除技能「${skill.name}」吗？删除后小Q将无法再查阅这份手册。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(dialogContext).colorScheme.error,
              foregroundColor: Theme.of(dialogContext).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ref.read(agentSkillListProvider.notifier).deleteUserSkill(skill.name);
      if (!mounted) return;
      Toast.success(context, '已删除技能「${skill.name}」');
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      Toast.error(context, '删除失败：$e');
    }
  }
}
