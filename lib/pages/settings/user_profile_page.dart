import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';

class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key});

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  final _nicknameController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  DateTime? _birthday;
  DateTime _weightDate = DateTime.now();
  bool _showWeightHistory = false;
  bool _saveSuccess = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProfile());
  }

  Future<void> _loadProfile() async {
    try {
      await ref.read(userProfileNotifierProvider.notifier).load();
    } catch (e) {
      debugPrint('加载用户资料失败: $e');
    }
    if (!mounted) return;
    final profile = ref.read(userProfileNotifierProvider);
    if (profile != null) {
      setState(() {
        _nicknameController.text = profile.nickname ?? '';
        _heightController.text = profile.height?.toString() ?? '';
        if (profile.birthday != null) {
          _birthday = DateTime.tryParse(profile.birthday!);
        }
      });
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    super.dispose();
  }

  int _calculateAge() {
    if (_birthday == null) return 0;
    final now = DateTime.now();
    int age = now.year - _birthday!.year;
    if (now.month < _birthday!.month || (now.month == _birthday!.month && now.day < _birthday!.day)) {
      age--;
    }
    return age;
  }

  double? get _latestWeight {
    final profile = ref.read(userProfileNotifierProvider);
    if (profile == null || profile.weightHistory.isEmpty) return null;
    final sorted = List.of(profile.weightHistory)..sort((a, b) => b.time.compareTo(a.time));
    return sorted.first.weight;
  }

  Future<void> _save() async {
    try {
      final notifier = ref.read(userProfileNotifierProvider.notifier);
      final current = ref.read(userProfileNotifierProvider);
      final profile = (current ??
              UserProfile(
                id: '',
                createdAt: DateTime.now(),
                updatedAt: DateTime.now(),
              ))
          .copyWith(
        nickname: _nicknameController.text.isEmpty ? null : _nicknameController.text,
        birthday: _birthday?.toIso8601String().split('T').first,
        height: double.tryParse(_heightController.text),
        updatedAt: DateTime.now(),
      );
      await notifier.save(profile);
      if (!mounted) return;
      setState(() => _saveSuccess = true);
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) setState(() => _saveSuccess = false);
      });
    } catch (e) {
      debugPrint('保存用户资料失败: $e');
    }
  }

  Future<void> _addWeightRecord() async {
    try {
      final weight = double.tryParse(_weightController.text);
      if (weight == null) return;
      await ref.read(userProfileNotifierProvider.notifier).addWeightRecord(
            weight,
            time: DateTime(
              _weightDate.year,
              _weightDate.month,
              _weightDate.day,
              12,
            ),
          );
      if (!mounted) return;
      _weightController.clear();
    } catch (e) {
      debugPrint('添加体重记录失败: $e');
    }
  }

  Future<void> _deleteWeightRecord(String id) async {
    try {
      await ref.read(userProfileNotifierProvider.notifier).deleteWeightRecord(id);
    } catch (e) {
      debugPrint('删除体重记录失败: $e');
    }
  }

  BoxDecoration _cardDecoration(ThemeData theme) {
    return BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.02),
          blurRadius: 10,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('个人信息'),
        centerTitle: false,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: FilledButton(
              onPressed: _save,
              style: FilledButton.styleFrom(
                backgroundColor: _saveSuccess ? Colors.green : theme.colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                minimumSize: const Size(0, 36),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
              ),
              child: Text(_saveSuccess ? '已保存' : '保存', style: const TextStyle(fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _buildTopCard(theme),
          const SizedBox(height: 24),
          Text('基本资料', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 12),
          _buildBasicInfoCard(theme),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('体重管理', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              GestureDetector(
                onTap: () => setState(() => _showWeightHistory = !_showWeightHistory),
                child: Row(
                  children: [
                    Icon(Icons.history, size: 16, color: theme.colorScheme.primary),
                    const SizedBox(width: 4),
                    Text('历史', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary)),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          _buildWeightCard(theme),
          const SizedBox(height: 24),
          _buildAiHint(theme),
        ],
      ),
    );
  }

  Widget _buildTopCard(ThemeData theme) {
    final age = _calculateAge();
    final weight = _latestWeight;

    return Container(
      decoration: _cardDecoration(theme),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primaryContainer.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.person_outline, size: 32, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: _nicknameController,
                      decoration: const InputDecoration(
                        hintText: 'HQ',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        isDense: true,
                      ),
                      style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '个人资料会帮助 AI 助手了解您',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.8)),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            children: [
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Text('当前年龄', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(text: age > 0 ? '$age' : '-', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                            TextSpan(text: ' 岁', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    children: [
                      Text('最新体重', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(height: 4),
                      RichText(
                        text: TextSpan(
                          children: [
                            TextSpan(text: weight != null ? weight.toStringAsFixed(0) : '-', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold, color: theme.colorScheme.primary)),
                            TextSpan(text: ' kg', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBasicInfoCard(ThemeData theme) {
    return Container(
      decoration: _cardDecoration(theme),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.cake_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 8),
                    Text('出生年月', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  ],
                ),
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: _birthday ?? DateTime(2000, 1, 1),
                      firstDate: DateTime(1900),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null && mounted) {
                      setState(() => _birthday = picked);
                    }
                  },
                  child: Row(
                    children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _birthday != null ? DateFormat('MM月').format(_birthday!) : '月',
                                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              Icon(Icons.keyboard_arrow_down, size: 16, color: theme.colorScheme.onSurfaceVariant),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                _birthday != null ? DateFormat('dd日').format(_birthday!) : '日',
                                style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                              ),
                              Icon(Icons.keyboard_arrow_down, size: 16, color: theme.colorScheme.onSurfaceVariant),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Divider(height: 32, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Row(
              children: [
                Icon(Icons.straighten, size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('身高 (CM)', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                const Spacer(),
                Container(
                  width: 100,
                  height: 40,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: TextField(
                    controller: _heightController,
                    keyboardType: TextInputType.number,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                    decoration: const InputDecoration(
                      hintText: '173',
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWeightCard(ThemeData theme) {
    final profile = ref.watch(userProfileNotifierProvider);
    final weightHistory = profile != null ? profile.weightHistory : <dynamic>[];

    return Container(
      decoration: _cardDecoration(theme),
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                DateFormat('yyyy-MM-dd').format(_weightDate),
                style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              Text('今日', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _weightController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            hintText: '今日体重',
                            hintStyle: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6)),
                            border: InputBorder.none,
                          ),
                        ),
                      ),
                      Text('kg', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              GestureDetector(
                onTap: _addWeightRecord,
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer.withValues(alpha: 0.8),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Icon(Icons.add_circle_outline, color: Colors.white, size: 24),
                ),
              ),
            ],
          ),
          if (_showWeightHistory && weightHistory.isNotEmpty) ...[
            const SizedBox(height: 16),
            Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
            const SizedBox(height: 8),
            ...weightHistory.map((record) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${record.weight} kg', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold)),
                  subtitle: Text(DateFormat('yyyy-MM-dd').format(record.time), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                    onPressed: () => _deleteWeightRecord(record.id),
                  ),
                )),
          ],
        ],
      ),
    );
  }

  Widget _buildAiHint(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.smart_toy, size: 18, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, height: 1.5),
                children: [
                  const TextSpan(text: '您的资料已集成至 '),
                  TextSpan(text: 'AI 助手', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold)),
                  const TextSpan(text: '，我们将为您提供更精准的健康与运动建议。'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

