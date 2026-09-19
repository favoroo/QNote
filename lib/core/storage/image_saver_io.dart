import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';

/// 原生端（Android / iOS）图片保存实现：交给系统相册写入。
///
/// Android 侧走 MediaStore（`Pictures/QNote`），iOS 侧走 PHPhotoLibrary addOnly，
/// 两端共用 `com.appone.qnote_flutter/media` 通道，详见 MainActivity.kt 与 AppDelegate.swift。
const MethodChannel _mediaChannel = MethodChannel(
  'com.appone.qnote_flutter/media',
);

/// 保存本地文件到系统相册；[fileName] 为相册中展示的文件名。
Future<void> saveImage(String source, String fileName) async {
  final path = await _materializeToFilePath(source, fileName);
  final ok = await _mediaChannel.invokeMethod<bool>('saveToGallery', {
    'path': path,
    'fileName': fileName,
  });
  if (ok != true) {
    throw StateError('系统相册未接收该图片');
  }
}

/// 保存失败时的降级路径：调起系统分享面板，用户在面板里选「存储到照片 / 文件」。
Future<bool> shareImageFallback(String source, String fileName) async {
  final path = await _materializeToFilePath(source, fileName);
  await Share.shareXFiles([XFile(path)], subject: fileName);
  return true;
}

/// 把 data URI 在 Dart 侧解码为临时文件，让原生通道只处理普通文件路径，
/// 避免在 Kotlin / Swift 两端各写一份 base64 解码逻辑。
Future<String> _materializeToFilePath(String source, String fileName) async {
  final trimmed = source.trim();
  if (!trimmed.startsWith('data:')) {
    return trimmed;
  }
  final commaIndex = trimmed.indexOf(',');
  if (commaIndex == -1) {
    throw const FormatException('非法的 data URI：缺少 base64 分隔符');
  }
  final bytes = base64Decode(trimmed.substring(commaIndex + 1).trim());
  final dir = await getTemporaryDirectory();
  final dotIndex = fileName.lastIndexOf('.');
  final ext = dotIndex == -1 ? 'png' : fileName.substring(dotIndex + 1);
  final file = File(
    '${dir.path}/qnote_share_${const Uuid().v4()}.$ext',
  );
  await file.writeAsBytes(bytes);
  return file.path;
}
