import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/providers/diary_provider.dart';
import 'package:qnote_flutter/providers/shortcut_provider.dart';
import 'package:qnote_flutter/core/storage/image_repository.dart';
import 'package:qnote_flutter/widgets/time_picker.dart';
import 'package:qnote_flutter/widgets/tag_picker.dart';
import 'package:qnote_flutter/widgets/unified_image.dart';

class DiaryEditorView extends ConsumerStatefulWidget {
  final DiaryRecord record;

  const DiaryEditorView({super.key, required this.record});

  @override
  ConsumerState<DiaryEditorView> createState() => _DiaryEditorViewState();
}

class _DiaryEditorViewState extends ConsumerState<DiaryEditorView> {
  late TextEditingController _contentController;
  late DateTime _time;
  late DateTime? _startTime;
  late DateTime? _endTime;
  late List<String> _tags;
  late String _displayTag;
  late List<String> _photos;
  late List<String> _newlyUploadedPaths;
  late List<String> _removedPaths;

  @override
  void initState() {
    super.initState();
    final r = widget.record;
    _contentController = TextEditingController(text: r.content);
    _time = r.time;
    _startTime = r.startTime;
    _endTime = r.endTime;
    _tags = List.from(r.tags);
    _displayTag = r.displayTag;
    _photos = List.from(r.photos);
    _newlyUploadedPaths = [];
    _removedPaths = [];
  }

  @override
  void dispose() {
    _contentController.dispose();
    super.dispose();
  }

  Future<void> _pickTime() async {
    final result = await showTimePickerDialog(
      context: context,
      initialTime: _startTime ?? _time,
      mode: TimePickerMode.dateTime,
    );
    if (result != null) {
      setState(() {
        _time = result;
        _startTime = result;
      });
    }
  }

  Future<void> _pickEndTime() async {
    final result = await showTimePickerDialog(
      context: context,
      initialTime: _endTime ?? _startTime ?? _time,
      mode: TimePickerMode.dateTime,
    );
    if (result != null) {
      setState(() {
        _endTime = result;
      });
    }
  }

  Future<void> _pickTags() async {
    final shortcuts = ref.read(shortcutListProvider);
    final availableTags = shortcuts.valueOrNull?.map((s) => s.name).toList() ?? [];
    final result = await showTagPickerDialog(
      context: context,
      availableTags: availableTags,
      selectedTags: _tags,
    );
    if (result != null) {
      setState(() {
        _tags = result;
        if (result.isNotEmpty) {
          _displayTag = result.first;
        } else {
          _displayTag = '记录';
        }
      });
    }
  }

  Future<void> _addPhoto(ImageSource source) async {
    if (_photos.length >= 3) return;
    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: source,
      maxWidth: 1200,
      maxHeight: 1200,
      imageQuality: 80,
    );
    if (xFile == null) return;
    final imageRepo = ImageRepository();
    final savedPath = await imageRepo.saveImage(File(xFile.path), subfolder: 'diary');
    setState(() {
      _photos.add(savedPath);
      _newlyUploadedPaths.add(savedPath);
    });
  }

  void _removePhoto(int index) {
    final removed = _photos.removeAt(index);
    if (_newlyUploadedPaths.contains(removed)) {
      _newlyUploadedPaths.remove(removed);
      ImageRepository().deleteImage(removed);
    } else {
      _removedPaths.add(removed);
    }
    setState(() {});
  }

  void _previewPhoto(int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => _FullScreenImageView(imagePath: _photos[index]),
      ),
    );
  }

  Future<void> _save() async {
    for (final path in _removedPaths) {
      await ImageRepository().deleteImage(path);
    }
    final updated = widget.record.copyWith(
      time: _time,
      startTime: _startTime,
      endTime: _endTime,
      tags: _tags,
      displayTag: _displayTag,
      content: _contentController.text,
      photos: _photos,
      updatedAt: DateTime.now(),
    );
    await ref.read(diaryListProvider.notifier).updateDiary(updated);
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('确认删除'),
        content: const Text('删除后可在回收站恢复，确定要删除这条记录吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      for (final path in _newlyUploadedPaths) {
        await ImageRepository().deleteImage(path);
      }
      await ref.read(diaryListProvider.notifier).deleteDiary(widget.record.id);
      if (mounted) Navigator.of(context).pop();
    }
  }

  void _handleBack() {
    for (final path in _newlyUploadedPaths) {
      ImageRepository().deleteImage(path);
    }
    Navigator.of(context).pop();
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('MM-dd HH:mm').format(dt);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _handleBack,
          ),
          title: const Text('编辑记录'),
          centerTitle: true,
          actions: [
            IconButton(
              icon: Icon(Icons.delete_outline, color: colorScheme.error),
              onPressed: _delete,
            ),
          ],
        ),
        body: Column(
          children: [
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildTimeSection(theme, colorScheme),
                    const SizedBox(height: 24),
                    _buildTagSection(theme, colorScheme),
                    const SizedBox(height: 24),
                    _buildContentSection(theme, colorScheme),
                    const SizedBox(height: 24),
                    _buildPhotosSection(theme, colorScheme),
                  ],
                ),
              ),
            ),
            _buildBottomBar(colorScheme),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '记录时间',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            GestureDetector(
              onTap: _pickTime,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                height: 44,
                decoration: BoxDecoration(
                  color: colorScheme.primaryContainer.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: colorScheme.primary.withValues(alpha: 0.15)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.schedule, size: 16, color: colorScheme.primary),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        _formatDateTime(_startTime ?? _time),
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                          fontSize: 12,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (_endTime != null)
              GestureDetector(
                onTap: _pickEndTime,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorScheme.primaryContainer.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(color: colorScheme.primary.withValues(alpha: 0.15)),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.access_time, size: 16, color: colorScheme.primary),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _formatDateTime(_endTime!),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 12,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              GestureDetector(
                onTap: _pickEndTime,
                child: Container(
                  height: 44,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(22),
                    border: Border.all(
                      color: colorScheme.outlineVariant.withValues(alpha: 0.2),
                      style: BorderStyle.solid,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add, size: 16, color: colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Text(
                        '结束时间',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12,
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildTagSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '分类标签',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (_displayTag.isNotEmpty && _displayTag != '记录')
              Chip(
                label: Text(_displayTag),
                avatar: Icon(Icons.label, size: 16, color: colorScheme.onPrimary),
                backgroundColor: colorScheme.primary,
                labelStyle: TextStyle(color: colorScheme.onPrimary, fontWeight: FontWeight.bold),
                deleteIcon: Icon(Icons.close, size: 16, color: colorScheme.onPrimary),
                onDeleted: () {
                  setState(() {
                    _tags = [];
                    _displayTag = '记录';
                  });
                },
              ),
            ActionChip(
              label: Text(_displayTag.isNotEmpty && _displayTag != '记录' ? '修改' : '添加标签'),
              avatar: Icon(
                _displayTag.isNotEmpty && _displayTag != '记录' ? Icons.edit : Icons.add,
                size: 16,
              ),
              onPressed: _pickTags,
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildContentSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        const SizedBox(height: 16),
        Text(
          '内容',
          style: theme.textTheme.labelSmall?.copyWith(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _contentController,
          maxLines: null,
          minLines: 5,
          decoration: InputDecoration(
            hintText: '在此输入详细记录内容...',
            border: InputBorder.none,
            filled: false,
          ),
          style: theme.textTheme.bodyLarge,
        ),
      ],
    );
  }

  Widget _buildPhotosSection(ThemeData theme, ColorScheme colorScheme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
        const SizedBox(height: 16),
        Row(
          children: [
            Text(
              '照片 (最多3张)',
              style: theme.textTheme.labelSmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.bold,
                letterSpacing: 1.2,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 80,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            itemCount: _photos.length + (_photos.length < 3 ? 2 : 0),
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
              if (index < _photos.length) {
                return _buildPhotoItem(index, colorScheme);
              }
              final isGallery = index == _photos.length;
              return _buildAddPhotoButton(
                icon: isGallery ? Icons.photo_library : Icons.camera_alt,
                label: isGallery ? '图库' : '拍照',
                source: isGallery ? ImageSource.gallery : ImageSource.camera,
                colorScheme: colorScheme,
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildPhotoItem(int index, ColorScheme colorScheme) {
    return GestureDetector(
      onTap: () => _previewPhoto(index),
      child: Stack(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: colorScheme.outlineVariant.withValues(alpha: 0.3)),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: UnifiedImage(
                imagePath: _photos[index],
                width: 80,
                height: 80,
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
          Positioned(
            top: 2,
            right: 2,
            child: GestureDetector(
              onTap: () => _removePhoto(index),
              child: Container(
                width: 24,
                height: 24,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.5),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddPhotoButton({
    required IconData icon,
    required String label,
    required ImageSource source,
    required ColorScheme colorScheme,
  }) {
    return GestureDetector(
      onTap: () => _addPhoto(source),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: colorScheme.outlineVariant,
            style: BorderStyle.solid,
          ),
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 24, color: colorScheme.onSurfaceVariant),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(ColorScheme colorScheme) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton(
            onPressed: _save,
            style: FilledButton.styleFrom(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(26),
              ),
            ),
            child: const Text('保存修改', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          ),
        ),
      ),
    );
  }
}

class _FullScreenImageView extends StatelessWidget {
  final String imagePath;

  const _FullScreenImageView({required this.imagePath});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          child: UnifiedImage(
            imagePath: imagePath,
            fit: BoxFit.contain,
          ),
        ),
      ),
    );
  }
}
