import 'dart:convert' show base64Encode;
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/core/utils/gallery_helper.dart';
import 'package:qnote_flutter/models/user_profile.dart';
import 'package:qnote_flutter/models/weight_record.dart';
import 'package:qnote_flutter/providers/user_profile_provider.dart';
import 'package:qnote_flutter/widgets/birthday_picker.dart';
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
  final _otherInfoController = TextEditingController();
  final _scrollController = ScrollController();
  final _weightInputFocusNode = FocusNode();
  final Map<String, TextEditingController> _customFieldControllers = {};
  DateTime? _birthday;
  String? _gender;
  DateTime _weightDate = DateTime.now();
  bool _showWeightHistory = false;
  int _historyTab = 0; // 0: 折线趋势图, 1: 历史记录列表
  bool _saveSuccess = false;
  String _avatarPath = '';
  String _weightUnit = 'kg'; // 体重单位：'kg' 或 '斤'

  final ImageRepository _imageRepo = ImageRepository();

  @override
  void initState() {
    super.initState();
    _weightInputFocusNode.addListener(() {
      if (mounted) setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProfile());
  }

  Future<void> _loadProfile() async {
    try {
      await ref.read(userProfileNotifierProvider.notifier).load();
      final unit = await ConfigRepository.instance.getAppConfig('weight_unit');
      if (unit != null && mounted) {
        setState(() {
          _weightUnit = unit;
        });
      }
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
        _gender = profile.gender;
        _otherInfoController.text = profile.otherInfo ?? '';
        if (profile.birthday != null) {
          _birthday = DateTime.tryParse(profile.birthday!);
        }
        final age = _calculateAge();
        _ageController.text = age > 0 ? '$age' : '';

        _customFieldControllers.forEach((_, controller) => controller.dispose());
        _customFieldControllers.clear();
        profile.customFields.forEach((key, value) {
          _customFieldControllers[key] = TextEditingController(text: value);
        });
      });
    }
  }

  Future<void> _setWeightUnit(String unit) async {
    if (_weightUnit == unit) return;
    setState(() {
      _weightUnit = unit;
    });
    try {
      await ConfigRepository.instance.setAppConfig('weight_unit', unit);
    } catch (e) {
      debugPrint('保存体重单位偏好失败: $e');
    }
  }

  void _toggleWeightUnit() {
    _setWeightUnit(_weightUnit == 'kg' ? '斤' : 'kg');
  }

  void _focusWeightInput() {
    _weightInputFocusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          120,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutCubic,
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _weightInputFocusNode.dispose();
    _nicknameController.dispose();
    _heightController.dispose();
    _weightController.dispose();
    _ageController.dispose();
    _otherInfoController.dispose();
    _customFieldControllers.forEach((_, controller) => controller.dispose());
    super.dispose();
  }

  int _calculateAge() {
    if (_birthday == null) return 0;
    final now = DateTime.now();
    int age = now.year - _birthday!.year;
    if (now.month < _birthday!.month ||
        (now.month == _birthday!.month && now.day < _birthday!.day)) {
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

  Future<void> _showBirthdayPicker() async {
    final picked = await showBirthdayPicker(
      context: context,
      initialDate: _birthday ?? DateTime(2000, 1, 1),
      firstDate: DateTime(1900),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        _birthday = picked;
        final ageValue = _calculateAge();
        _ageController.text = ageValue > 0 ? '$ageValue' : '';
      });
    }
  }

  Future<void> _pickAvatar() async {
    final image = await GalleryHelper.pickSingleImage(context);
    if (image == null) return;

    // Add cropping step
    if (!mounted) return;
    final croppedFile = await GalleryHelper.cropImage(context, image.path);
    if (croppedFile == null) return;

    String savedPath;
    if (kIsWeb) {
      final bytes = await croppedFile.readAsBytes();
      final base64Str = base64Encode(bytes);
      final ext = image.path.contains('.png') ? 'png' : 'jpeg';
      savedPath = 'data:image/$ext;base64,$base64Str';
    } else {
      final file = File(croppedFile.path);
      savedPath = await _imageRepo.saveImage(file, subfolder: 'avatar');
    }

    if (mounted) {
      setState(() {
        _avatarPath = savedPath;
      });
    }
  }

  double? get _latestWeight {
    final profile = ref.watch(userProfileNotifierProvider);
    if (profile == null || profile.weightHistory.isEmpty) return null;
    final sorted = List.of(profile.weightHistory)
      ..sort((a, b) => b.time.compareTo(a.time));
    return sorted.first.weight;
  }

  Future<void> _save() async {
    try {
      final notifier = ref.read(userProfileNotifierProvider.notifier);
      final current = ref.read(userProfileNotifierProvider);
      final customFields = <String, String>{};
      _customFieldControllers.forEach((key, controller) {
        customFields[key] = controller.text;
      });
      final profile =
          (current ??
                  UserProfile(
                    id: '',
                    createdAt: DateTime.now(),
                    updatedAt: DateTime.now(),
                  ))
              .copyWith(
                nickname: _nicknameController.text.isEmpty
                    ? null
                    : _nicknameController.text,
                birthday: _birthday?.toIso8601String().split('T').first,
                height: double.tryParse(_heightController.text),
                avatarPath: _avatarPath,
                gender: _gender,
                otherInfo: _otherInfoController.text.isEmpty
                    ? null
                    : _otherInfoController.text,
                customFields: customFields,
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
      final weightInKg = _weightUnit == '斤' ? weight / 2.0 : weight;
      await ref
          .read(userProfileNotifierProvider.notifier)
          .addWeightRecord(
            weightInKg,
            time: DateTime(
              _weightDate.year,
              _weightDate.month,
              _weightDate.day,
              12,
            ),
          );
      if (!mounted) return;
      _weightController.clear();
      setState(() {
        _weightDate = DateTime.now();
      });
    } catch (e) {
      debugPrint('添加体重记录失败: $e');
    }
  }

  Future<void> _deleteWeightRecord(String id) async {
    try {
      await ref
          .read(userProfileNotifierProvider.notifier)
          .deleteWeightRecord(id);
    } catch (e) {
      debugPrint('删除体重记录失败: $e');
    }
  }

  BoxDecoration _cardDecoration(ThemeData theme) {
    return BoxDecoration(
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(24),
      border: Border.all(
        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
      ),
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
                backgroundColor: _saveSuccess
                    ? Colors.green
                    : theme.colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 24),
                minimumSize: const Size(0, 36),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: Text(
                _saveSuccess ? '已保存' : '保存',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ),
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: ListView(
          controller: _scrollController,
          padding: const EdgeInsets.all(20),
          children: [
            _buildIdentityCard(theme),
            const SizedBox(height: 20),
            _buildHealthCard(theme),
            const SizedBox(height: 20),
            _buildOtherInfoCard(theme),
            ..._buildCustomFieldCards(theme),
            const SizedBox(height: 12),
            _buildAddCustomFieldButton(theme),
            const SizedBox(height: 20),
            _buildAiHint(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildIdentityCard(ThemeData theme) {
    return Container(
      decoration: _cardDecoration(theme),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 第一行：头像（左） + 姓名/性别（右）
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: _pickAvatar,
                child: Stack(
                  children: [
                    Container(
                      width: 76,
                      height: 76,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: theme.colorScheme.surface,
                          width: 2,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: _avatarPath.isNotEmpty
                            ? UnifiedImage(
                                imagePath: _avatarPath,
                                width: 72,
                                height: 72,
                                borderRadius: BorderRadius.circular(36),
                                fit: BoxFit.cover,
                              )
                            : Container(
                                color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
                                child: Icon(
                                  Icons.person_outline,
                                  size: 32,
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      bottom: 0,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: theme.colorScheme.surface,
                            width: 1.5,
                          ),
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          size: 10,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 16),
              // 姓名与性别选择
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: _nicknameController,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                      textInputAction: TextInputAction.next,
                      decoration: const InputDecoration(
                        labelText: '姓名 / 昵称',
                        hintText: '输入您的姓名或昵称',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        isDense: true,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Container(
                      height: 38,
                      padding: const EdgeInsets.all(3),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          _buildGenderTab(theme, '男', 'male'),
                          _buildGenderTab(theme, '女', 'female'),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 第二行：出生年月 & 年龄 Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: TextField(
                  readOnly: true,
                  onTap: _showBirthdayPicker,
                  controller: TextEditingController(
                    text: _birthday != null
                        ? DateFormat('yyyy-MM-dd').format(_birthday!)
                        : '',
                  ),
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  decoration: const InputDecoration(
                    labelText: '出生年月',
                    hintText: '选择日期',
                    suffixIcon: Icon(Icons.calendar_today, size: 16),
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _ageController,
                  keyboardType: TextInputType.number,
                  onChanged: _onAgeTextChanged,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '年龄',
                    suffixText: '岁',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 第三行：身高 & 最新体重 Row
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: _heightController,
                  keyboardType: TextInputType.number,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                  textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(
                    labelText: '身高',
                    suffixText: 'cm',
                    floatingLabelBehavior: FloatingLabelBehavior.always,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _focusWeightInput,
                    borderRadius: BorderRadius.circular(12),
                    child: InputDecorator(
                      decoration: InputDecoration(
                        labelText: '最新体重',
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        suffixIcon: Icon(
                          Icons.edit_note_rounded,
                          size: 20,
                          color: theme.colorScheme.primary.withValues(alpha: 0.8),
                        ),
                      ),
                      child: Text(
                        _latestWeight != null
                            ? '${_weightUnit == '斤' ? (_latestWeight! * 2).toStringAsFixed(1) : _latestWeight!.toStringAsFixed(1)} $_weightUnit'
                            : '点击记录',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: _latestWeight != null
                              ? theme.colorScheme.onSurface
                              : theme.colorScheme.primary.withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGenderTab(ThemeData theme, String label, String value) {
    final isSelected = _gender == value;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _gender = value),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? theme.colorScheme.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                value == 'male' ? Icons.male : Icons.female,
                size: 18,
                color: isSelected
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  color: isSelected
                      ? theme.colorScheme.primary
                      : theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUnitToggle(ThemeData theme) {
    final isJin = _weightUnit == '斤';
    return Container(
      height: 28,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildUnitOption(theme, '斤', isJin),
          _buildUnitOption(theme, 'kg', !isJin),
        ],
      ),
    );
  }

  Widget _buildUnitOption(ThemeData theme, String unit, bool isSelected) {
    return GestureDetector(
      onTap: () => _setWeightUnit(unit),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          unit,
          style: TextStyle(
            fontSize: 12,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
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
          // Weight Management Header
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.monitor_weight_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
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
              Row(
                children: [
                  _buildUnitToggle(theme),
                  const SizedBox(width: 10),
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
            ],
          ),
          const SizedBox(height: 12),
          // Weight Input Bar
          AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _weightInputFocusNode.hasFocus
                    ? theme.colorScheme.primary
                    : theme.colorScheme.outlineVariant.withValues(alpha: 0.8),
                width: _weightInputFocusNode.hasFocus ? 1.5 : 1.0,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(
              children: [
                // Date Select Chip
                InkWell(
                  onTap: _selectWeightDate,
                  borderRadius: BorderRadius.circular(10),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.calendar_month,
                          size: 14,
                          color: theme.colorScheme.primary,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          _isToday(_weightDate) ? '今天' : DateFormat('MM-dd').format(_weightDate),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Weight TextField
                Expanded(
                  child: TextField(
                    controller: _weightController,
                    focusNode: _weightInputFocusNode,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => _addWeightRecord(),
                    decoration: InputDecoration(
                      hintText: _isToday(_weightDate) ? '记录今日体重...' : '记录该日体重...',
                      hintStyle: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                      ),
                      border: InputBorder.none,
                      isDense: true,
                      suffix: GestureDetector(
                        onTap: _toggleWeightUnit,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 6, right: 4),
                          child: Text(
                            _weightUnit,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.colorScheme.primary,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Add Button
                IconButton.filled(
                  onPressed: _addWeightRecord,
                  icon: const Icon(Icons.add, size: 20),
                  style: IconButton.styleFrom(
                    backgroundColor: theme.colorScheme.primary,
                    foregroundColor: theme.colorScheme.onPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    minimumSize: const Size(40, 40),
                    padding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
          ),
          // Weight History List / Chart inside the card
          if (_showWeightHistory && weightHistory.isNotEmpty) ...[
            const SizedBox(height: 16),
            Container(
              height: 40,
              padding: const EdgeInsets.all(3),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHistoryTabItem(theme, '折线趋势图', 0),
                  _buildHistoryTabItem(theme, '历史列表', 1),
                ],
              ),
            ),
            const SizedBox(height: 12),
            if (_historyTab == 0)
              _buildWeightChart(weightHistory, theme)
            else
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
                    final sortedList = List<WeightRecord>.from(weightHistory)
                      ..sort((a, b) => b.time.compareTo(a.time));
                    final record = sortedList[index];
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '${_weightUnit == '斤' ? (record.weight * 2.0).toStringAsFixed(1) : record.weight.toStringAsFixed(1)} $_weightUnit',
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
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
                            icon: const Icon(
                              Icons.delete_outline,
                              size: 18,
                              color: Colors.red,
                            ),
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

  Widget _buildHistoryTabItem(ThemeData theme, String title, int index) {
    final isSelected = _historyTab == index;
    return GestureDetector(
      onTap: () => setState(() => _historyTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          title,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildOtherInfoCard(ThemeData theme) {
    return Container(
      decoration: _cardDecoration(theme),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.info_outline,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Text(
                '其他信息',
                style: theme.textTheme.titleSmall?.copyWith(
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _otherInfoController,
            maxLines: 4,
            minLines: 2,
            keyboardType: TextInputType.multiline,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            decoration: const InputDecoration(
              hintText: '职业、爱好、身体状况等',
            ),
          ),
        ],
      ),
    );
  }

  Iterable<Widget> _buildCustomFieldCards(ThemeData theme) {
    return _customFieldControllers.keys.map((key) {
      return Padding(
        padding: const EdgeInsets.only(top: 20),
        child: _buildCustomFieldCard(theme, key),
      );
    });
  }

  Widget _buildCustomFieldCard(ThemeData theme, String fieldName) {
    return Container(
      decoration: _cardDecoration(theme),
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.assignment_outlined,
                size: 20,
                color: theme.colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  fieldName,
                  style: theme.textTheme.titleSmall?.copyWith(
                    color: theme.colorScheme.onSurface,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              IconButton(
                icon: Icon(
                  Icons.edit_outlined,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _showRenameCustomFieldDialog(fieldName),
                tooltip: '重命名',
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: Icon(
                  Icons.delete_outline_rounded,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () => _confirmDeleteCustomField(fieldName),
                tooltip: '删除',
              ),
            ],
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _customFieldControllers[fieldName],
            maxLines: 4,
            minLines: 2,
            keyboardType: TextInputType.multiline,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
            decoration: InputDecoration(
              hintText: '请输入$fieldName',
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddCustomFieldButton(ThemeData theme) {
    return OutlinedButton.icon(
      onPressed: _showAddCustomFieldDialog,
      icon: const Icon(Icons.add),
      label: const Text('添加自定义信息字段'),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 16),
        side: BorderSide(
          color: theme.colorScheme.primary.withValues(alpha: 0.5),
          style: BorderStyle.solid,
        ),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    );
  }

  void _showAddCustomFieldDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('添加自定义字段'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              hintText: '例如：工作信息、身体状况',
              labelText: '字段名称',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isNotEmpty) {
                  if (_customFieldControllers.containsKey(name) || name == '其他信息') {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('该字段名称已存在')),
                    );
                    return;
                  }
                  setState(() {
                    _customFieldControllers[name] = TextEditingController();
                  });
                  Navigator.pop(context);
                }
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _showRenameCustomFieldDialog(String oldName) {
    final controller = TextEditingController(text: oldName);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('重命名字段'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: '新字段名称',
            ),
            autofocus: true,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                final newName = controller.text.trim();
                if (newName.isNotEmpty && newName != oldName) {
                  if (_customFieldControllers.containsKey(newName) || newName == '其他信息') {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('该字段名称已存在')),
                    );
                    return;
                  }
                  setState(() {
                    final oldController = _customFieldControllers.remove(oldName);
                    if (oldController != null) {
                      _customFieldControllers[newName] = oldController;
                    }
                  });
                  Navigator.pop(context);
                } else {
                  Navigator.pop(context);
                }
              },
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
  }

  void _confirmDeleteCustomField(String name) {
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('确认删除'),
          content: Text('确定要删除“$name”这个字段吗？删除后该字段的内容将不会保存。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  final controller = _customFieldControllers.remove(name);
                  controller?.dispose();
                });
                Navigator.pop(context);
              },
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
  }

  Widget _buildAiHint(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: theme.colorScheme.primary.withValues(alpha: 0.1),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.smart_toy_outlined,
            size: 20,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.6,
                  fontSize: 12,
                ),
                children: [
                  const TextSpan(text: '您的资料已集成至 '),
                  TextSpan(
                    text: 'AI 助手',
                    style: TextStyle(
                      color: theme.colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const TextSpan(text: '，我们将为您提供更精准的健康与运动建议。'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildWeightChart(List<dynamic> weightHistory, ThemeData theme) {
    final sortedHistory = List<WeightRecord>.from(weightHistory)
      ..sort((a, b) => a.time.compareTo(b.time));

    final spots = <FlSpot>[];
    for (var i = 0; i < sortedHistory.length; i++) {
      final double weightVal = _weightUnit == '斤' ? sortedHistory[i].weight * 2.0 : sortedHistory[i].weight;
      spots.add(FlSpot(i.toDouble(), weightVal));
    }

    final weights = sortedHistory.map((e) => _weightUnit == '斤' ? e.weight * 2.0 : e.weight).toList();
    final double minW = weights.isEmpty ? 0.0 : weights.reduce((a, b) => a < b ? a : b);
    final double maxW = weights.isEmpty ? 0.0 : weights.reduce((a, b) => a > b ? a : b);

    final double range = maxW - minW;
    final double padding = range < 1.0 ? 2.0 : range * 0.15;
    final double minY = math.max(0.0, minW - padding);
    final double maxY = maxW + padding;

    return LayoutBuilder(
      builder: (context, constraints) {
        final double availableWidth = constraints.maxWidth;
        final double chartWidth = math.max(
          availableWidth,
          sortedHistory.length * 64.0,
        );

        return Container(
          height: 180,
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(
              alpha: 0.15,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
            ),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Container(
              width: chartWidth,
              padding: const EdgeInsets.only(right: 24, left: 16, top: 12),
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: true,
                    drawHorizontalLine: true,
                    horizontalInterval: range < 1.0
                        ? 1.0
                        : (range / 4.0).clamp(0.5, 100.0),
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.2,
                      ),
                      strokeWidth: 1,
                    ),
                    getDrawingVerticalLine: (value) => FlLine(
                      color: theme.colorScheme.outlineVariant.withValues(
                        alpha: 0.15,
                      ),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 28,
                        interval: 1,
                        getTitlesWidget: (value, meta) {
                          final int index = value.toInt();
                          if (index < 0 || index >= sortedHistory.length) {
                            return const SizedBox.shrink();
                          }
                          final record = sortedHistory[index];
                          final dateStr = DateFormat(
                            'MM/dd',
                          ).format(record.time);
                          return Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              dateStr,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.7),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            value.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.6),
                            ),
                          );
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  minY: minY,
                  maxY: maxY,
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      preventCurveOverShooting: true,
                      color: theme.colorScheme.primary,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) =>
                            FlDotCirclePainter(
                              radius: 4,
                              color: theme.colorScheme.primary,
                              strokeWidth: 2,
                              strokeColor: theme.colorScheme.surface,
                            ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          colors: [
                            theme.colorScheme.primary.withValues(alpha: 0.25),
                            theme.colorScheme.primary.withValues(alpha: 0.0),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (touchedSpot) =>
                          theme.colorScheme.surfaceContainerHighest,
                      tooltipRoundedRadius: 8,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((lineBarSpot) {
                          final index = lineBarSpot.x.toInt();
                          final record = sortedHistory[index];
                          final dateStr = DateFormat(
                            'yyyy-MM-dd',
                          ).format(record.time);
                          final displayWeight = _weightUnit == '斤' ? (record.weight * 2.0) : record.weight;
                          return LineTooltipItem(
                            '${displayWeight.toStringAsFixed(1)} $_weightUnit\n$dateStr',
                            TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.bold,
                              fontSize: 11,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  bool _isToday(DateTime date) {
    final now = DateTime.now();
    return date.year == now.year &&
        date.month == now.month &&
        date.day == now.day;
  }

  Future<void> _selectWeightDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _weightDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) {
      setState(() {
        _weightDate = picked;
      });
    }
  }
}
