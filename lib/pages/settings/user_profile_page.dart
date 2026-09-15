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
  String? _gender; // 'male', 'female', 'other' 或 null
  DateTime _weightDate = DateTime.now();
  bool _showWeightHistory = false;
  int _historyTab = 0; // 0: 折线图, 1: 记录列表
  bool _saveSuccess = false;
  String _avatarPath = '';
  String _weightUnit = 'kg'; // 'kg' 或 '斤'

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
        _heightController.text = profile.height != null ? profile.height!.toStringAsFixed(0) : '';
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
          140,
          duration: const Duration(milliseconds: 300),
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

  double? get _latestWeightInKg {
    final profile = ref.watch(userProfileNotifierProvider);
    if (profile == null || profile.weightHistory.isEmpty) return null;
    final sorted = List.of(profile.weightHistory)
      ..sort((a, b) => b.time.compareTo(a.time));
    return sorted.first.weight;
  }

  String get _displayLatestWeight {
    final w = _latestWeightInKg;
    if (w == null) return '--';
    final val = _weightUnit == '斤' ? w * 2.0 : w;
    return '${val.toStringAsFixed(1)} $_weightUnit';
  }

  // 计算 BMI: kg / (m * m)
  double? get _bmi {
    final w = _latestWeightInKg;
    final hStr = _heightController.text.trim();
    final h = double.tryParse(hStr);
    if (w == null || h == null || h <= 0) return null;
    final hInMeter = h / 100.0;
    return w / (hInMeter * hInMeter);
  }

  String get _bmiLabel {
    final bmi = _bmi;
    if (bmi == null) return '';
    if (bmi < 18.5) return '偏瘦';
    if (bmi < 24.0) return '正常';
    if (bmi < 28.0) return '偏重';
    return '肥胖';
  }

  Color _bmiColor(ThemeData theme) {
    final bmi = _bmi;
    if (bmi == null) return theme.colorScheme.outline;
    if (bmi < 18.5) return Colors.amber.shade700;
    if (bmi < 24.0) return Colors.green.shade600;
    if (bmi < 28.0) return Colors.orange.shade700;
    return Colors.red.shade600;
  }

  Future<void> _save() async {
    try {
      final notifier = ref.read(userProfileNotifierProvider.notifier);
      final current = ref.read(userProfileNotifierProvider);
      final customFields = <String, String>{};
      _customFieldControllers.forEach((key, controller) {
        customFields[key] = controller.text;
      });
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
        gender: _gender,
        otherInfo: _otherInfoController.text.isEmpty ? null : _otherInfoController.text,
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
      if (weight == null || weight <= 0) return;
      final weightInKg = _weightUnit == '斤' ? weight / 2.0 : weight;
      await ref.read(userProfileNotifierProvider.notifier).addWeightRecord(
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
      await ref.read(userProfileNotifierProvider.notifier).deleteWeightRecord(id);
    } catch (e) {
      debugPrint('删除体重记录失败: $e');
    }
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
            child: FilledButton.icon(
              onPressed: _save,
              icon: Icon(
                _saveSuccess ? Icons.check_circle_rounded : Icons.check_rounded,
                size: 16,
              ),
              label: Text(_saveSuccess ? '已保存' : '保存'),
              style: FilledButton.styleFrom(
                backgroundColor: _saveSuccess ? Colors.green.shade600 : theme.colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                minimumSize: const Size(0, 34),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(17),
                ),
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
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          children: [
            // 1. 顶部紧凑名片区
            _buildProfileHeader(theme),
            const SizedBox(height: 14),

            // 2. 核心身体档案组
            _buildSectionCard(
              theme,
              title: '身体档案',
              icon: Icons.accessibility_new_rounded,
              trailing: _bmi != null
                  ? Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: _bmiColor(theme).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        'BMI ${_bmi!.toStringAsFixed(1)} · $_bmiLabel',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: _bmiColor(theme),
                        ),
                      ),
                    )
                  : null,
              children: [
                _buildGenderRow(theme),
                _buildDivider(theme),
                _buildBirthdayAndAgeRow(theme),
                _buildDivider(theme),
                _buildHeightAndWeightRow(theme),
              ],
            ),
            const SizedBox(height: 14),

            // 3. 体重记录与趋势组
            _buildWeightManagementCard(theme),
            const SizedBox(height: 14),

            // 4. 备注与自定义信息组
            _buildAdditionalInfoCard(theme),
            const SizedBox(height: 28),
          ],
        ),
      ),
    );
  }

  /// 顶部紧凑名片区（头像 + 昵称大字号 + 快捷信息胶囊）
  Widget _buildProfileHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // 头像
          GestureDetector(
            onTap: _pickAvatar,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                  ),
                  child: ClipOval(
                    child: _avatarPath.isNotEmpty
                        ? UnifiedImage(
                            imagePath: _avatarPath,
                            width: 60,
                            height: 60,
                            borderRadius: BorderRadius.circular(30),
                            fit: BoxFit.cover,
                          )
                        : Container(
                            color: theme.colorScheme.primaryContainer.withValues(alpha: 0.3),
                            child: Icon(
                              Icons.person_rounded,
                              size: 32,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                  ),
                ),
                Positioned(
                  right: -2,
                  bottom: -2,
                  child: Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 1.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.camera_alt_rounded,
                      size: 11,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 14),

          // 昵称与简介
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _nicknameController,
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.2,
                  ),
                  decoration: InputDecoration(
                    hintText: '点击输入姓名 / 昵称',
                    hintStyle: theme.textTheme.titleMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
                      fontWeight: FontWeight.normal,
                    ),
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    _buildMicroTag(
                      theme,
                      _gender == 'male'
                          ? '男 ♂'
                          : _gender == 'female'
                              ? '女 ♀'
                              : '性别未设',
                    ),
                    if (_calculateAge() > 0)
                      _buildMicroTag(theme, '${_calculateAge()} 岁'),
                    if (_heightController.text.isNotEmpty)
                      _buildMicroTag(theme, '${_heightController.text} cm'),
                    if (_latestWeightInKg != null)
                      _buildMicroTag(theme, _displayLatestWeight),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMicroTag(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  /// 通用圆角分组容器
  Widget _buildSectionCard(
    ThemeData theme, {
    required String title,
    required IconData icon,
    Widget? trailing,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Icon(icon, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.3,
                  ),
                ),
                const Spacer(),
                ?trailing,
              ],
            ),
          ),
          ...children,
        ],
      ),
    );
  }

  Widget _buildDivider(ThemeData theme) {
    return Divider(
      height: 1,
      thickness: 0.5,
      indent: 14,
      endIndent: 14,
      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
    );
  }

  /// 性别单选行
  Widget _buildGenderRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          Text(
            '生理性别',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          Container(
            height: 30,
            padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildGenderPill(theme, '男', 'male', Icons.male_rounded),
                _buildGenderPill(theme, '女', 'female', Icons.female_rounded),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGenderPill(ThemeData theme, String label, String value, IconData icon) {
    final isSelected = _gender == value;
    return GestureDetector(
      onTap: () => setState(() => _gender = value),
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 3,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 生日与年龄联动行
  Widget _buildBirthdayAndAgeRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          Text(
            '出生日期',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          InkWell(
            onTap: _showBirthdayPicker,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _birthday != null
                        ? DateFormat('yyyy-MM-dd').format(_birthday!)
                        : '选择日期',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w500,
                      color: _birthday != null
                          ? theme.colorScheme.onSurface
                          : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    Icons.calendar_today_rounded,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          Container(
            width: 1,
            height: 16,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 58,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: TextField(
                    controller: _ageController,
                    keyboardType: TextInputType.number,
                    onChanged: _onAgeTextChanged,
                    textAlign: TextAlign.right,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    decoration: const InputDecoration(
                      hintText: '--',
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 4),
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                    ),
                  ),
                ),
                Text(
                  ' 岁',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 身高与当前体重行
  Widget _buildHeightAndWeightRow(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
      child: Row(
        children: [
          Text(
            '基本体征',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const Spacer(),
          // 身高
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '身高 ',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
              SizedBox(
                width: 44,
                child: TextField(
                  controller: _heightController,
                  keyboardType: TextInputType.number,
                  textAlign: TextAlign.right,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                  decoration: const InputDecoration(
                    hintText: '--',
                    isDense: true,
                    contentPadding: EdgeInsets.symmetric(vertical: 4),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    filled: false,
                  ),
                ),
              ),
              Text(
                ' cm',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(width: 14),
          Container(
            width: 1,
            height: 16,
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5),
          ),
          const SizedBox(width: 14),
          // 最新体重快捷跳转
          InkWell(
            onTap: _focusWeightInput,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '体重 ',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  Text(
                    _displayLatestWeight,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.edit_note_rounded,
                    size: 16,
                    color: theme.colorScheme.primary,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 体重管理模块（紧凑录入条 + 内置轻量趋势/历史）
  Widget _buildWeightManagementCard(ThemeData theme) {
    final profile = ref.watch(userProfileNotifierProvider);
    final weightHistory = profile != null ? profile.weightHistory : <dynamic>[];

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部栏
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
            child: Row(
              children: [
                Icon(Icons.monitor_weight_outlined, size: 16, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  '体重管理',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                // 斤 / kg 单位微切换
                _buildUnitToggle(theme),
                const SizedBox(width: 10),
                // 展开/收起历史
                InkWell(
                  onTap: () => setState(() => _showWeightHistory = !_showWeightHistory),
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _showWeightHistory ? '收起' : '趋势/历史',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                        Icon(
                          _showWeightHistory ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
                          size: 16,
                          color: theme.colorScheme.primary,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 极简单行录入条
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            child: Container(
              height: 40,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _weightInputFocusNode.hasFocus
                      ? theme.colorScheme.primary.withValues(alpha: 0.8)
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  // 日期选择
                  InkWell(
                    onTap: _selectWeightDate,
                    borderRadius: BorderRadius.circular(6),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.calendar_today_rounded,
                            size: 13,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _isToday(_weightDate) ? '今天' : DateFormat('MM-dd').format(_weightDate),
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8),
                    width: 1,
                    height: 16,
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  ),
                  // 体重输入框
                  Expanded(
                    child: TextField(
                      controller: _weightController,
                      focusNode: _weightInputFocusNode,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      textInputAction: TextInputAction.done,
                      onSubmitted: (_) => _addWeightRecord(),
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      decoration: InputDecoration(
                        hintText: '输入体重数值...',
                        hintStyle: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        filled: false,
                        suffix: GestureDetector(
                          onTap: _toggleWeightUnit,
                          behavior: HitTestBehavior.opaque,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            child: Text(
                              _weightUnit,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // 记录按钮
                  IconButton(
                    onPressed: _addWeightRecord,
                    icon: const Icon(Icons.add_rounded, size: 18),
                    style: IconButton.styleFrom(
                      backgroundColor: theme.colorScheme.primary,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),

          // 展开的趋势与历史
          if (_showWeightHistory && weightHistory.isNotEmpty) ...[
            _buildDivider(theme),
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
              child: Row(
                children: [
                  Container(
                    height: 28,
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildHistoryTabItem(theme, '折线趋势', 0),
                        _buildHistoryTabItem(theme, '详细记录', 1),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '共 ${weightHistory.length} 条记录',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            if (_historyTab == 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                child: _buildWeightChart(weightHistory, theme),
              )
            else
              _buildHistoryList(weightHistory, theme),
          ] else if (_showWeightHistory && weightHistory.isEmpty) ...[
            _buildDivider(theme),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  '暂无历史体重记录',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildUnitToggle(ThemeData theme) {
    final isJin = _weightUnit == '斤';
    return Container(
      height: 24,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(6),
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
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          unit,
          style: TextStyle(
            fontSize: 11,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryTabItem(ThemeData theme, String title, int index) {
    final isSelected = _historyTab == index;
    return GestureDetector(
      onTap: () => setState(() => _historyTab = index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: isSelected ? theme.colorScheme.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.04),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ]
              : null,
        ),
        alignment: Alignment.center,
        child: Text(
          title,
          style: TextStyle(
            fontSize: 11,
            color: isSelected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildHistoryList(List<dynamic> weightHistory, ThemeData theme) {
    final sortedList = List<WeightRecord>.from(weightHistory)
      ..sort((a, b) => b.time.compareTo(a.time));

    return Container(
      constraints: const BoxConstraints(maxHeight: 160),
      child: ListView.separated(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        itemCount: sortedList.length,
        separatorBuilder: (_, _) => Divider(
          height: 1,
          thickness: 0.5,
          color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
        ),
        itemBuilder: (context, index) {
          final record = sortedList[index];
          final val = _weightUnit == '斤' ? (record.weight * 2.0) : record.weight;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: [
                Text(
                  DateFormat('yyyy-MM-dd').format(record.time),
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                Text(
                  '${val.toStringAsFixed(1)} $_weightUnit',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => _deleteWeightRecord(record.id),
                  borderRadius: BorderRadius.circular(4),
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(
                      Icons.close_rounded,
                      size: 14,
                      color: theme.colorScheme.error.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 备注与自定义信息统一卡片
  Widget _buildAdditionalInfoCard(ThemeData theme) {
    return _buildSectionCard(
      theme,
      title: '备注与拓展信息',
      icon: Icons.notes_rounded,
      trailing: InkWell(
        onTap: _showAddCustomFieldDialog,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.add_rounded, size: 14, color: theme.colorScheme.primary),
              const SizedBox(width: 2),
              Text(
                '添加字段',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
      children: [
        // 其他信息多行文本
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: TextField(
            controller: _otherInfoController,
            maxLines: 3,
            minLines: 2,
            keyboardType: TextInputType.multiline,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.35, fontSize: 13),
            decoration: InputDecoration(
              hintText: '个性说明、职业、生活习惯或身体状况备忘...',
              hintStyle: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
              isDense: true,
              contentPadding: const EdgeInsets.all(10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.5)),
              ),
            ),
          ),
        ),

        // 自定义字段列表
        if (_customFieldControllers.isNotEmpty) ...[
          _buildDivider(theme),
          ..._customFieldControllers.keys.map((key) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
                  child: Row(
                    children: [
                      Container(
                        width: 4,
                        height: 12,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          key,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      InkWell(
                        onTap: () => _showRenameCustomFieldDialog(key),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.edit_outlined,
                            size: 14,
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: () => _confirmDeleteCustomField(key),
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(
                            Icons.delete_outline_rounded,
                            size: 14,
                            color: theme.colorScheme.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
                  child: TextField(
                    controller: _customFieldControllers[key],
                    maxLines: 2,
                    minLines: 1,
                    style: theme.textTheme.bodyMedium?.copyWith(fontSize: 13),
                    decoration: InputDecoration(
                      hintText: '请输入$key',
                      hintStyle: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.45),
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
                      isDense: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide.none,
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: theme.colorScheme.primary.withValues(alpha: 0.5)),
                      ),
                    ),
                  ),
                ),
              ],
            );
          }),
        ],
      ],
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
              hintText: '例如：工作信息、目标、血型',
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

  Widget _buildWeightChart(List<dynamic> weightHistory, ThemeData theme) {
    final sortedHistory = List<WeightRecord>.from(weightHistory)
      ..sort((a, b) => a.time.compareTo(b.time));

    final spots = <FlSpot>[];
    for (var i = 0; i < sortedHistory.length; i++) {
      final double weightVal =
          _weightUnit == '斤' ? sortedHistory[i].weight * 2.0 : sortedHistory[i].weight;
      spots.add(FlSpot(i.toDouble(), weightVal));
    }

    final weights =
        sortedHistory.map((e) => _weightUnit == '斤' ? e.weight * 2.0 : e.weight).toList();
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
          sortedHistory.length * 54.0,
        );

        return Container(
          height: 140,
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Container(
              width: chartWidth,
              padding: const EdgeInsets.only(right: 16, left: 12, top: 10, bottom: 4),
              child: LineChart(
                LineChartData(
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    drawHorizontalLine: true,
                    horizontalInterval: range < 1.0 ? 1.0 : (range / 3.0).clamp(0.5, 100.0),
                    getDrawingHorizontalLine: (value) => FlLine(
                      color: theme.colorScheme.outlineVariant.withValues(alpha: 0.2),
                      strokeWidth: 1,
                    ),
                  ),
                  titlesData: FlTitlesData(
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 22,
                        interval: 1,
                        getTitlesWidget: (value, meta) {
                          final int index = value.toInt();
                          if (index < 0 || index >= sortedHistory.length) {
                            return const SizedBox.shrink();
                          }
                          final record = sortedHistory[index];
                          final dateStr = DateFormat('MM/dd').format(record.time);
                          return Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              dateStr,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w600,
                                color:
                                    theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        getTitlesWidget: (value, meta) {
                          return Text(
                            value.toStringAsFixed(1),
                            style: TextStyle(
                              fontSize: 9,
                              color:
                                  theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
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
                      barWidth: 2.5,
                      isStrokeCapRound: true,
                      dotData: FlDotData(
                        show: true,
                        getDotPainter: (spot, percent, barData, index) => FlDotCirclePainter(
                          radius: 3,
                          color: theme.colorScheme.primary,
                          strokeWidth: 1.5,
                          strokeColor: theme.colorScheme.surface,
                        ),
                      ),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          colors: [
                            theme.colorScheme.primary.withValues(alpha: 0.2),
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
                      tooltipRoundedRadius: 6,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((lineBarSpot) {
                          final index = lineBarSpot.x.toInt();
                          final record = sortedHistory[index];
                          final dateStr = DateFormat('yyyy-MM-dd').format(record.time);
                          final displayWeight =
                              _weightUnit == '斤' ? (record.weight * 2.0) : record.weight;
                          return LineTooltipItem(
                            '${displayWeight.toStringAsFixed(1)} $_weightUnit\n$dateStr',
                            TextStyle(
                              color: theme.colorScheme.onSurface,
                              fontWeight: FontWeight.bold,
                              fontSize: 10,
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
    return date.year == now.year && date.month == now.month && date.day == now.day;
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
