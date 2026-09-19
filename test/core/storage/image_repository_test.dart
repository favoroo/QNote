import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:qnote_flutter/core/storage/image_repository.dart';

/// 将文档目录 mock 到临时目录，验证 saveImage 落盘逻辑
class _MockPathProviderPlatform extends PathProviderPlatform {
  late String rootPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => rootPath;
}

final _mockPathProvider = _MockPathProviderPlatform();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('image_repo_test');
    _mockPathProvider.rootPath = tempDir.path;
    PathProviderPlatform.instance = _mockPathProvider;
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// 生成真实 JPEG 文件
  Future<String> createJpegFile(String name, int width, int height) async {
    final image = img.Image(width: width, height: height);
    img.fill(image, color: img.ColorRgb8(120, 160, 200));
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(img.encodeJpg(image));
    return file.path;
  }

  /// 解码压缩产物读取尺寸
  Future<(int, int)> readSize(String path) async {
    final bytes = await File(path).readAsBytes();
    final decoded = img.decodeImage(bytes);
    expect(decoded, isNotNull, reason: '压缩产物应为可解码的 JPEG');
    return (decoded!.width, decoded.height);
  }

  group('ImageRepository.saveImage', () {
    test('超大图压缩后最长边不超过 1080', () async {
      final source = await createJpegFile('big.jpg', 2000, 1200);
      final savedPath = await ImageRepository().saveImage(File(source));

      expect(await File(savedPath).exists(), isTrue);
      final (width, height) = await readSize(savedPath);
      expect(width, 1080);
      expect(height, 648);
    });

    test('小图不放大尺寸', () async {
      final source = await createJpegFile('small.jpg', 400, 300);
      final savedPath = await ImageRepository().saveImage(File(source));

      final (width, height) = await readSize(savedPath);
      expect(width, 400);
      expect(height, 300);
    });

    test('非图片字节回退原字节落盘，不抛异常', () async {
      final file = File('${tempDir.path}/invalid.jpg');
      final raw = Uint8List.fromList(List<int>.generate(512, (i) => i % 256));
      await file.writeAsBytes(raw);

      final savedPath = await ImageRepository().saveImage(file);
      final savedBytes = await File(savedPath).readAsBytes();
      expect(savedBytes, raw);
    });

    test('并发多次调用串行执行且全部成功', () async {
      final source1 = await createJpegFile('a.jpg', 1600, 900);
      final source2 = await createJpegFile('b.jpg', 900, 1600);

      final repo = ImageRepository();
      final paths = await Future.wait([
        repo.saveImage(File(source1)),
        repo.saveImage(File(source2)),
      ]);

      expect(paths.length, 2);
      expect(paths[0], isNot(paths[1]));
      for (final path in paths) {
        final (width, height) = await readSize(path);
        expect(width <= 1080 && height <= 1080, isTrue);
      }
    });
  });
}
