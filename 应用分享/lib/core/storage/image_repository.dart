import 'dart:io';
import 'dart:convert';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
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
    final ext = p.extension(imageFile.path);
    final fileName = '${_uuid.v4()}$ext';
    final newPath = p.join(imagesDir.path, fileName);
    
    final sizeBytes = await imageFile.length();
    LoggerService.instance.logDatabase(
      '保存图片文件',
      details: '源=${imageFile.path}, 目标=$newPath, 大小≈${(sizeBytes / 1024).toStringAsFixed(1)}KB'
    );
    
    await imageFile.copy(newPath);
    return newPath;
  }

  Future<File?> getImage(String path) async {
    final file = File(path);
    if (await file.exists()) return file;
    return null;
  }

  Future<void> deleteImage(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<String> getBase64Image(String path) async {
    final file = File(path);
    if (!await file.exists()) return '';
    final bytes = await file.readAsBytes();
    return base64Encode(bytes);
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
