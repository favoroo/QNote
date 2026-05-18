import 'dart:io';
import 'dart:convert' show base64Encode;
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:image_picker/image_picker.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

class UserProfilePage extends ConsumerStatefulWidget {
  const UserProfilePage({super.key});

  @override
  ConsumerState<UserProfilePage> createState() => _UserProfilePageState();
}

class _UserProfilePageState extends ConsumerState<UserProfilePage> {
  final _nicknameController = TextEditingController();
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  final _ageController = TextEditingController();
  DateTime? _birthday;
  final DateTime _weightDate = DateTime.now();
  bool _showWeightHistory = false;
  bool _saveSuccess = false;
  String _avatarPath = '';

  final ImagePicker _imagePicker = ImagePicker();
  final ImageRepository _imageRepo = ImageRepository();

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
        _avatarPath = profile.avatarPath;
        if (profile.birthday != null) {
          _birthday = DateTime.tryParse(profile.birthday!);
        }
        final age = _calculateAge();
        _ageController.text = age > 0 ? '$age' : '';
      });
    }
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    _ageController.dispose();
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

  void _onAgeTextChanged(String value) {
    final age = int.tryParse(value);
    if (age == null || age < 0 || age > 150) {
      if (value.isEmpty) {
        setState(() {
          _birthday = null;
        });
      }
      return;
    }
    
    setState(() {
      final now = DateTime.now();
      final currentMonth = _birthday?.month ?? 1;
      final currentDay = _birthday?.day ?? 1;
      _birthday = DateTime(now.year - age, currentMonth, currentDay);
    });
  }

  Future<void> _pickAvatar() async {
    final image = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 500,
      maxHeight: 500,
      imageQuality: 85,
    );
    if (image == null) return;

    String savedPath;
    if (kIsWeb) {
      final bytes = await image.readAsBytes();
      final base64Str = base64Encode(bytes);
      final ext = image.path.contains('.png') ? 'png' : 'jpeg';
      savedPath = 'data:image/$ext;base64,$base64Str';
    } else {
      final file = File(image.path);
      savedPath = await _imageRepo.saveImage(file, subfolder: 'avatar');
    }

    if (mounted) {
      setState(() {
        _avatarPath = savedPath;
      });
    }
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
        avatarPath: _avatarPath,
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
          _buildIdentityCard(theme),
          const SizedBox(height: 20),
          _buildHealthCard(theme),
          const SizedBox(height: 20),
          _buildAiHint(theme),
        ],
      ),
    );
  }

  Widget _buildIdentityCard(ThemeData theme) {
    return Container(
      decoration: _cardDecoration(theme),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Avatar
              GestureDetector(
                onTap: _pickAvatar,
                child: Stack(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: _avatarPath.isNotEmpty
                          ? UnifiedImage(
                              imagePath: _avatarPath,
                              width: 72,
                              height: 72,
                              borderRadius: BorderRadius.circular(36),
                              fit: BoxFit.cover,
                            )
                          : Icon(Icons.person_outline, size: 36, color: theme.colorScheme.primary),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          size: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Nickname
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '姓名 / 昵称',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    TextField(
                      controller: _nicknameController,
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      decoration: const InputDecoration(
                        hintText: '输入昵称',
                        border: InputBorder.none,
                        contentPadding: EdgeInsets.zero,
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // Age Input
              Container(
                width: 90,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    Text(
                      '年龄 (岁)',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      height: 24,
                      child: TextField(
                        controller: _ageController,
                        keyboardType: TextInputType.number,
                        textAlign: TextAlign.center,
                        onChanged: _onAgeTextChanged,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.primary,
                        ),
                        decoration: const InputDecoration(
                          hintText: '年龄',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4), thickness: 1),
          const SizedBox(height: 16),
          // Birthday Selector Row
          Row(
            children: [
              Icon(Icons.cake_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
              const SizedBox(width: 8),
              Text(
                '出生年月',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  fontWeight: FontWeight.bold,
                ),
              ),
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
                initialDatePickerMode: DatePickerMode.year,
              );
              if (picked != null && mounted) {
                setState(() {
                  _birthday = picked;
                  final ageValue = _calculateAge();
                  _ageController.text = ageValue > 0 ? '$ageValue' : '';
                });
              }
            },
            child: Row(
              children: [
                // Year
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          _birthday != null ? DateFormat('yyyy年').format(_birthday!) : '年',
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                        ),
                        Icon(Icons.keyboard_arrow_down, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Month
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                        Icon(Icons.keyboard_arrow_down, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Day
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
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
                        Icon(Icons.keyboard_arrow_down, size: 14, color: theme.colorScheme.onSurfaceVariant),
                      ],
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

  Widget _buildHealthCard(ThemeData theme) {
    final profile = ref.watch(userProfileNotifierProvider);
    final weightHistory = profile != null ? profile.weightHistory : <dynamic>[];

    return Container(
      decoration: _cardDecoration(theme),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Height and Weight Fields Side-by-Side
          Row(
            children: [
              // Height
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.straighten, size: 16, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Text(
                            '身高 (CM)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _heightController,
                        keyboardType: TextInputType.number,
                        style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                        decoration: const InputDecoration(
                          hintText: '173',
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Latest Weight Display
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.scale_outlined, size: 16, color: theme.colorScheme.primary),
                          const SizedBox(width: 6),
                          Text(
                            '最新体重 (kg)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        _latestWeight != null ? '${_latestWeight!.toStringAsFixed(1)} kg' : '未记录',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: _latestWeight != null ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          Divider(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4), thickness: 1),
          const SizedBox(height: 16),
          // Weight Management Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(Icons.monitor_weight_outlined, size: 18, color: theme.colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    '体重记录',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              GestureDetector(
                onTap: () => setState(() => _showWeightHistory = !_showWeightHistory),
                child: Row(
                  children: [
                    Icon(
                      _showWeightHistory ? Icons.keyboard_arrow_up : Icons.history,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      _showWeightHistory ? '收起历史' : '历史记录',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Weight Input Field + Add Button
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Expanded(
                        child: TextField(
                          controller: _weightController,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            hintText: '记录今日体重 (kg)...',
                            hintStyle: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                            ),
                            border: InputBorder.none,
                            isDense: true,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 10),
              GestureDetector(
                onTap: _addWeightRecord,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.add, color: Colors.white, size: 20),
                ),
              ),
            ],
          ),
          // Weight History List inside the card
          if (_showWeightHistory && weightHistory.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              constraints: const BoxConstraints(maxHeight: 180),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                itemCount: weightHistory.length,
                separatorBuilder: (context, index) => Divider(
                  height: 1,
                  color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                ),
                itemBuilder: (context, index) {
                  final record = weightHistory[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${record.weight} kg',
                              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              DateFormat('yyyy-MM-dd').format(record.time),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                              ),
                            ),
                          ],
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                          onPressed: () => _deleteWeightRecord(record.id),
                          constraints: const BoxConstraints(),
                          padding: EdgeInsets.zero,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAiHint(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.primaryContainer.withValues(alpha: 0.15),
        ),
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

