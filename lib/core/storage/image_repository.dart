import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';

class ImageRepository {
  static final ImageRepository _instance = ImageRepository._internal();
  factory ImageRepository() => _instance;
  ImageRepository._internal();

  static const _uuid = Uuid();

  Future<String> saveImage(File imageFile, {String? subfolder}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(appDir.path, 'images', subfolder ?? ''));
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    
    // 强制转换为 .jpg 后缀
    final fileName = '${_uuid.v4()}.jpg';
    final newPath = p.join(imagesDir.path, fileName);
    
    final bytes = await imageFile.readAsBytes();
    final originalSize = bytes.length;
    
    // 使用 compute 在后台 isolate 线程中执行压缩计算，避免阻塞 UI 主线程
    final compressedBytes = await compute(_compressImage, bytes);
    final compressedSize = compressedBytes.length;
    
    LoggerService.instance.logDatabase(
      '保存并压缩图片文件',
      details: '源=${imageFile.path}, 目标=$newPath, 原始大小≈${(originalSize / 1024).toStringAsFixed(1)}KB, 压缩后大小≈${(compressedSize / 1024).toStringAsFixed(1)}KB'
    );
    
    await File(newPath).writeAsBytes(compressedBytes);
    return newPath;
  }

  static Uint8List _compressImage(Uint8List bytes) {
    try {
      final image = img.decodeImage(bytes);
      if (image == null) return bytes;
      
      const int maxDim = 1080;
      int width = image.width;
      int height = image.height;
      
      if (width <= maxDim && height <= maxDim) {
        // 如果尺寸本身就在限制内，只进行 JPEG 编码压缩 (80 质量)
        final compressed = img.encodeJpg(image, quality: 80);
        return Uint8List.fromList(compressed);
      }
      
      int newWidth;
      int newHeight;
      if (width > height) {
        newWidth = maxDim;
        newHeight = (height * maxDim / width).round();
      } else {
        newHeight = maxDim;
        newWidth = (width * maxDim / height).round();
      }
      
      final resized = img.copyResize(image, width: newWidth, height: newHeight);
      final compressed = img.encodeJpg(resized, quality: 80);
      return Uint8List.fromList(compressed);
    } catch (_) {
      return bytes;
    }
  }

  static String getMimeType(String path) {
    final ext = p.extension(path).toLowerCase();
    if (ext == '.png') return 'image/png';
    if (ext == '.webp') return 'image/webp';
    if (ext == '.gif') return 'image/gif';
    return 'image/jpeg';
  }

  Future<String> resolveLocalPath(String originalPath) async {
    if (originalPath.isEmpty) return originalPath;
    final file = File(originalPath);
    if (await file.exists()) return originalPath;
    
    // 如果文件不存在，检测是否包含 images 文件夹路径
    final normalized = originalPath.replaceAll('\\', '/');
    final imagesIndex = normalized.lastIndexOf('/images/');
    if (imagesIndex != -1) {
      final relativePath = originalPath.substring(imagesIndex + 8);
      final appDir = await getApplicationDocumentsDirectory();
      final correctedPath = p.join(appDir.path, 'images', relativePath);
      if (await File(correctedPath).exists()) {
        return correctedPath;
      }
    }
    return originalPath;
  }

  Future<File?> getImage(String path) async {
    final resolved = await resolveLocalPath(path);
    final file = File(resolved);
    if (await file.exists()) return file;
    return null;
  }

  Future<void> deleteImage(String path) async {
    final resolved = await resolveLocalPath(path);
    final file = File(resolved);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<String> getBase64Image(String path) async {
    final resolved = await resolveLocalPath(path);
    final file = File(resolved);
    if (!await file.exists()) return '';
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
  }

  /// 检查图片文件是否存在（兼容绝对路径与 /images/ 相对路径）
  Future<bool> imageExists(String path) async {
    if (path.isEmpty) return false;
    final resolved = await resolveLocalPath(path);
    return File(resolved).exists();
  }

  /// 读取图片并压缩后返回 base64（供 Agent 多模态输入等需要控制体积的场景）
  ///
  /// 复用 [saveImage] 落盘时的压缩策略（最长边 1080px / JPEG 80），
  /// 避免聊天附件原图等未压缩的大图直接 base64 后冲爆请求体；
  /// 文件不存在时返回空字符串。
  Future<String> getCompressedBase64Image(String path) async {
    final resolved = await resolveLocalPath(path);
    final file = File(resolved);
    if (!await file.exists()) return '';
    final bytes = await file.readAsBytes();
    final compressed = await compute(_compressImage, bytes);
    return base64Encode(compressed);
  }

  Future<String> saveBase64Image(String base64Data, {String? subfolder}) async {
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(appDir.path, 'images', subfolder ?? ''));
    if (!await imagesDir.exists()) {
      await imagesDir.create(recursive: true);
    }
    final fileName = '${_uuid.v4()}.png';
    final newPath = p.join(imagesDir.path, fileName);
    final bytes = base64Decode(base64Data);
    await File(newPath).writeAsBytes(bytes);
    return newPath;
  }

  Future<List<String>> exportAllImagePaths() async {
    final appDir = await getApplicationDocumentsDirectory();
    final imagesDir = Directory(p.join(appDir.path, 'images'));
    if (!await imagesDir.exists()) return [];
    final files = await imagesDir.list(recursive: true).where((f) => f is File).cast<File>().toList();
    return files.map((f) => f.path).toList();
  }
}
