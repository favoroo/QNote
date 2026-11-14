import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

/// 统一封装系统相册选图与头像裁剪入口。
class GalleryHelper {
  static final ImagePicker _imagePicker = ImagePicker();

  /// 在 Android 端启用系统 Photo Picker（PickVisualMedia），
  /// 直接唤起系统级照片选择器，避免部分机型默认跳转到文件管理器。
  static ImagePickerAndroid? _enableAndroidPhotoPicker() {
    final implementation = ImagePickerPlatform.instance;
    if (implementation is ImagePickerAndroid) {
      implementation.useAndroidPhotoPicker = true;
      return implementation;
    }
    return null;
  }

  /// 调用系统相册单选一张图片；用户取消或异常时返回 `null`。
  static Future<XFile?> pickSingleImage(BuildContext context) async {
    return _runWithPhotoPickerFallback<XFile?>(
      label: '单图选择',
      fallbackValue: null,
      action: () =>
          _imagePicker.pickImage(source: ImageSource.gallery, maxWidth: 1200, maxHeight: 1200, imageQuality: 80),
    );
  }

  /// 裁剪图片文件（目前用于头像正方形裁剪）。
  static Future<CroppedFile?> cropImage(BuildContext context, String sourcePath) async {
    final theme = Theme.of(context);
    return await ImageCropper().cropImage(
      sourcePath: sourcePath,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: '裁剪头像',
          toolbarColor: theme.colorScheme.surface,
          toolbarWidgetColor: theme.colorScheme.onSurface,
          activeControlsWidgetColor: theme.colorScheme.primary,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          hideBottomControls: false,
        ),
        IOSUiSettings(title: '裁剪头像', aspectRatioLockEnabled: true, resetAspectRatioEnabled: false),
        WebUiSettings(
          context: context,
          presentStyle: WebPresentStyle.dialog,
          size: const CropperSize(width: 480, height: 480),
        ),
      ],
    );
  }

  /// 调用系统相册多选图片，最多返回 [maxAssets] 张；用户取消或异常时返回空列表。
  static Future<List<XFile>> pickMultiImages(BuildContext context, {int maxAssets = 3}) async {
    if (maxAssets <= 0) {
      return [];
    }
    // image_picker 的 pickMultiImage 要求 limit >= 2；仅剩 1 张配额时改走单选接口。
    if (maxAssets == 1) {
      final image = await _runWithPhotoPickerFallback<XFile?>(
        label: '单图选择',
        fallbackValue: null,
        action: () => _imagePicker.pickImage(source: ImageSource.gallery),
      );
      return image != null ? [image] : [];
    }

    final picked = await _runWithPhotoPickerFallback<List<XFile>>(
      label: '多图选择',
      fallbackValue: const [],
      action: () => _imagePicker.pickMultiImage(limit: maxAssets),
    );
    // 兜底截断：部分不支持 limit 的旧系统或 Web 端可能返回超出上限的图片数量。
    if (picked.length > maxAssets) {
      return picked.take(maxAssets).toList();
    }
    return picked;
  }

  static Future<T> _runWithPhotoPickerFallback<T>({
    required String label,
    required T fallbackValue,
    required Future<T> Function() action,
  }) async {
    final androidImpl = _enableAndroidPhotoPicker();
    try {
      return await action();
    } on PlatformException catch (e) {
      debugPrint('GalleryHelper $label 失败 (${e.code}): ${e.message}');
      // 连点导致的并发占位或明确无权限不再重试，避免重复弹窗。
      if (e.code == 'already_active' || e.code == 'photo_access_denied') {
        return fallbackValue;
      }
      // 部分精简或旧版 Android 系统不支持 Photo Picker 时，临时回退传统选图 Intent 重试一次。
      if (androidImpl != null && androidImpl.useAndroidPhotoPicker) {
        try {
          androidImpl.useAndroidPhotoPicker = false;
          return await action();
        } catch (fallbackError) {
          debugPrint('GalleryHelper $label 回退失败: $fallbackError');
          return fallbackValue;
        } finally {
          androidImpl.useAndroidPhotoPicker = true;
        }
      }
      return fallbackValue;
    } catch (e) {
      debugPrint('GalleryHelper $label 异常: $e');
      return fallbackValue;
    }
  }
}
