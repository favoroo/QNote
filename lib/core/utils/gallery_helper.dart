import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:wechat_assets_picker/wechat_assets_picker.dart';
import 'package:image_cropper/image_cropper.dart';

class GalleryHelper {
  static final ImagePicker _imagePicker = ImagePicker();

  /// Picks a single image and returns an XFile.
  /// On Web, falls back to ImagePicker.
  /// On Mobile, uses AssetPicker to directly show local gallery.
  static Future<XFile?> pickSingleImage(BuildContext context) async {
    if (kIsWeb) {
      return await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1200,
        maxHeight: 1200,
        imageQuality: 80,
      );
    } else {
      try {
        final List<AssetEntity>? result = await AssetPicker.pickAssets(
          context,
          pickerConfig: const AssetPickerConfig(
            maxAssets: 1,
            requestType: RequestType.image,
          ),
        );
        if (result == null || result.isEmpty) return null;
        final File? file = await result.first.file;
        if (file == null) return null;
        return XFile(file.path);
      } catch (e) {
        debugPrint('GalleryHelper error picking single image: $e');
        // Fallback to image picker if wechat_assets_picker fails
        return await _imagePicker.pickImage(
          source: ImageSource.gallery,
          maxWidth: 1200,
          maxHeight: 1200,
          imageQuality: 80,
        );
      }
    }
  }

  /// Crops an image file.
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
        IOSUiSettings(
          title: '裁剪头像',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
        ),
        WebUiSettings(
          context: context,
          presentStyle: WebPresentStyle.dialog,
          size: const CropperSize(width: 480, height: 480),
        ),
      ],
    );
  }

  /// Picks multiple images and returns a list of XFile.
  /// On Web, falls back to ImagePicker.
  /// On Mobile, uses AssetPicker to directly show local gallery.
  static Future<List<XFile>> pickMultiImages(BuildContext context, {int maxAssets = 3}) async {
    if (kIsWeb) {
      return await _imagePicker.pickMultiImage();
    } else {
      try {
        final List<AssetEntity>? result = await AssetPicker.pickAssets(
          context,
          pickerConfig: AssetPickerConfig(
            maxAssets: maxAssets,
            requestType: RequestType.image,
          ),
        );
        if (result == null || result.isEmpty) return [];
        final List<XFile> xFiles = [];
        for (final asset in result) {
          final File? file = await asset.file;
          if (file != null) {
            xFiles.add(XFile(file.path));
          }
        }
        return xFiles;
      } catch (e) {
        debugPrint('GalleryHelper error picking multi images: $e');
        // Fallback to image picker if wechat_assets_picker fails
        return await _imagePicker.pickMultiImage();
      }
    }
  }
}
