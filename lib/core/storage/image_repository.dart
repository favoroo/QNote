import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'package:qnote_flutter/core/logger/logger_service.dart';

/// 降采样解码出的 RGBA 位图，传给后台 isolate 做 JPEG 编码
class _RgbaBitmap {
  final int width;
  final int height;
  final Uint8List pixels;

  const _RgbaBitmap({required this.width, required this.height, required this.pixels});
}

class ImageRepository {
  static final ImageRepository _instance = ImageRepository._internal();
  factory ImageRepository() => _instance;
  ImageRepository._internal();

  static const _uuid = Uuid();

  /// 串行压缩队列：同一时刻只处理一张图，避免多选时多个压缩任务并发解码
  /// 叠加内存峰值导致系统杀进程（黑屏闪退）
  Future<void> _compressionQueue = Future.value();

  /// 任务依次入队执行；单个任务失败不影响后续任务（队列吞错保链，原始错误仍抛给调用方）
  Future<T> _enqueue<T>(Future<T> Function() task) {
    final result = _compressionQueue.then((_) => task());
    _compressionQueue = result.then<void>((_) {}, onError: (Object _) {});
    return result;
  }

  Future<String> saveImage(File imageFile, {String? subfolder}) {
    return _enqueue(() => _doSaveImage(imageFile, subfolder));
  }

  Future<String> _doSaveImage(File imageFile, String? subfolder) async {
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

    // 压缩：引擎边解码边降采样（内存峰值约 6MB）+ 后台 isolate 编码，避免阻塞 UI 主线程
    final compressedBytes = await _compressBytes(bytes);
    final compressedSize = compressedBytes.length;

    LoggerService.instance.logDatabase(
      '保存并压缩图片文件',
      details: '源=${imageFile.path}, 目标=$newPath, 原始大小≈${(originalSize / 1024).toStringAsFixed(1)}KB, 压缩后大小≈${(compressedSize / 1024).toStringAsFixed(1)}KB'
    );

    await File(newPath).writeAsBytes(compressedBytes);
    return newPath;
  }

  /// 压缩字节流：引擎解码器降采样到最长边 1080，再 isolate 内编码 JPEG（质量 80）；
  /// 解码或编码失败时返回原字节（保持旧的兜底落盘行为）
  Future<Uint8List> _compressBytes(Uint8List bytes) async {
    try {
      final bitmap = await _decodeDownsampled(bytes);
      if (bitmap == null) return bytes;
      return await compute(_encodeJpeg, bitmap);
    } catch (_) {
      return bytes;
    }
  }

  /// 用引擎原生解码器解码并降采样到最长边 [maxDim]：
  /// 只解析图片头获取原始尺寸（不解码全图，数十 MB 原图不会进内存），
  /// 解码阶段直接输出目标尺寸的 RGBA，单张内存峰值从全量解码的 100~200MB 降至约 6MB；
  /// 引擎解码还支持 HEIC 原图并尊重 EXIF 方向（旧 image 包均不支持，会落盘裂图/方向错乱）
  static Future<_RgbaBitmap?> _decodeDownsampled(Uint8List bytes) async {
    ui.ImmutableBuffer? buffer;
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.FrameInfo? frame;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      const int maxDim = 1080;
      final int width = descriptor.width;
      final int height = descriptor.height;
      if (width < 1 || height < 1) return null;

      int targetWidth = width;
      int targetHeight = height;
      if (width > maxDim || height > maxDim) {
        if (width >= height) {
          targetWidth = maxDim;
          targetHeight = (height * maxDim / width).round();
        } else {
          targetHeight = maxDim;
          targetWidth = (width * maxDim / height).round();
        }
      }
      if (targetWidth < 1) targetWidth = 1;
      if (targetHeight < 1) targetHeight = 1;

      codec = await descriptor.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (data == null) return null;
      // toByteData 返回独立缓冲，dispose ui.Image 后仍有效
      return _RgbaBitmap(
        width: targetWidth,
        height: targetHeight,
        pixels: Uint8List.view(data.buffer, data.offsetInBytes, data.lengthInBytes),
      );
    } catch (_) {
      return null;
    } finally {
      frame?.image.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer?.dispose();
    }
  }

  /// 后台 isolate 内执行：RGBA 位图 → JPEG（质量 80）
  static Uint8List _encodeJpeg(_RgbaBitmap bitmap) {
    final image = img.Image.fromBytes(
      width: bitmap.width,
      height: bitmap.height,
      bytes: bitmap.pixels.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    return Uint8List.fromList(img.encodeJpg(image, quality: 80));
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
  Future<String> getCompressedBase64Image(String path) {
    return _enqueue(() async {
      final resolved = await resolveLocalPath(path);
      final file = File(resolved);
      if (!await file.exists()) return '';
      final bytes = await file.readAsBytes();
      return base64Encode(await _compressBytes(bytes));
    });
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
