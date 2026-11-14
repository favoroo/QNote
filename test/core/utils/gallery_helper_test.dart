import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:image_picker_android/image_picker_android.dart';
import 'package:image_picker_platform_interface/image_picker_platform_interface.dart';

import 'package:qnote_flutter/core/utils/gallery_helper.dart';

class _FakeAndroidImagePicker extends ImagePickerAndroid {
  final List<bool> singleCallsWithPhotoPicker = [];
  final List<bool> multiCallsWithPhotoPicker = [];
  final List<int?> multiLimits = [];
  ImagePickerOptions? lastSingleOptions;
  ImageSource? lastSingleSource;

  XFile? Function(bool usePhotoPicker)? onSinglePick;
  List<XFile> Function(bool usePhotoPicker, int? limit)? onMultiPick;

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    singleCallsWithPhotoPicker.add(useAndroidPhotoPicker);
    lastSingleSource = source;
    lastSingleOptions = options;
    return onSinglePick?.call(useAndroidPhotoPicker);
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    multiCallsWithPhotoPicker.add(useAndroidPhotoPicker);
    multiLimits.add(options.limit);
    return onMultiPick?.call(useAndroidPhotoPicker, options.limit) ?? const [];
  }
}

class _FakeGenericImagePicker extends ImagePickerPlatform {
  int singleCallCount = 0;
  int multiCallCount = 0;
  int? lastMultiLimit;

  XFile? singleResult;
  List<XFile> multiResult = const [];

  @override
  Future<XFile?> getImageFromSource({
    required ImageSource source,
    ImagePickerOptions options = const ImagePickerOptions(),
  }) async {
    singleCallCount++;
    return singleResult;
  }

  @override
  Future<List<XFile>> getMultiImageWithOptions({
    MultiImagePickerOptions options = const MultiImagePickerOptions(),
  }) async {
    multiCallCount++;
    lastMultiLimit = options.limit;
    return multiResult;
  }
}

Future<BuildContext> _pumpDummyContext(WidgetTester tester) async {
  late BuildContext capturedContext;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) {
          capturedContext = context;
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  return capturedContext;
}

void main() {
  late ImagePickerPlatform originalPlatform;

  setUp(() {
    originalPlatform = ImagePickerPlatform.instance;
  });

  tearDown(() {
    ImagePickerPlatform.instance = originalPlatform;
  });

  group('GalleryHelper', () {
    testWidgets('Android 单图选择启用系统 Photo Picker 并传递压缩参数', (tester) async {
      final fake = _FakeAndroidImagePicker()
        ..useAndroidPhotoPicker = false
        ..onSinglePick = (_) => XFile('/tmp/picked.jpg');
      ImagePickerPlatform.instance = fake;
      final context = await _pumpDummyContext(tester);

      final result = await GalleryHelper.pickSingleImage(context);

      expect(result?.path, '/tmp/picked.jpg');
      expect(fake.singleCallsWithPhotoPicker, [true]);
      expect(fake.lastSingleSource, ImageSource.gallery);
      expect(fake.lastSingleOptions?.maxWidth, 1200);
      expect(fake.lastSingleOptions?.maxHeight, 1200);
      expect(fake.lastSingleOptions?.imageQuality, 80);
    });

    testWidgets('maxAssets <= 0 时直接返回空列表而不唤起相册', (tester) async {
      final fake = _FakeAndroidImagePicker();
      ImagePickerPlatform.instance = fake;
      final context = await _pumpDummyContext(tester);

      expect(await GalleryHelper.pickMultiImages(context, maxAssets: 0), isEmpty);
      expect(await GalleryHelper.pickMultiImages(context, maxAssets: -2), isEmpty);
      expect(fake.singleCallsWithPhotoPicker, isEmpty);
      expect(fake.multiCallsWithPhotoPicker, isEmpty);
    });

    testWidgets('maxAssets == 1 时走单选接口避免 image_picker limit < 2 校验异常', (tester) async {
      final fake = _FakeAndroidImagePicker()..onSinglePick = (_) => XFile('/tmp/single_quota.jpg');
      ImagePickerPlatform.instance = fake;
      final context = await _pumpDummyContext(tester);

      final result = await GalleryHelper.pickMultiImages(context, maxAssets: 1);

      expect(result.map((e) => e.path).toList(), ['/tmp/single_quota.jpg']);
      expect(fake.singleCallsWithPhotoPicker, [true]);
      expect(fake.multiCallsWithPhotoPicker, isEmpty);
    });

    testWidgets('maxAssets >= 2 时启用系统 Photo Picker 并限制数量且兜底截断', (tester) async {
      final fake = _FakeAndroidImagePicker()
        ..onMultiPick = (_, _) => [XFile('/tmp/1.jpg'), XFile('/tmp/2.jpg'), XFile('/tmp/3.jpg'), XFile('/tmp/4.jpg')];
      ImagePickerPlatform.instance = fake;
      final context = await _pumpDummyContext(tester);

      final result = await GalleryHelper.pickMultiImages(context, maxAssets: 3);

      expect(fake.multiCallsWithPhotoPicker, [true]);
      expect(fake.multiLimits, [3]);
      expect(result.map((e) => e.path).toList(), ['/tmp/1.jpg', '/tmp/2.jpg', '/tmp/3.jpg']);
    });

    testWidgets('Photo Picker 抛出常规 PlatformException 时回退传统选图一次并恢复配置', (tester) async {
      final fake = _FakeAndroidImagePicker()
        ..onSinglePick = (usePhotoPicker) {
          if (usePhotoPicker) {
            throw PlatformException(code: 'activity_not_found', message: 'No PhotoPicker');
          }
          return XFile('/tmp/fallback.jpg');
        };
      ImagePickerPlatform.instance = fake;
      final context = await _pumpDummyContext(tester);

      final result = await GalleryHelper.pickSingleImage(context);

      expect(result?.path, '/tmp/fallback.jpg');
      expect(fake.singleCallsWithPhotoPicker, [true, false]);
      expect(fake.useAndroidPhotoPicker, isTrue);
    });

    testWidgets('already_active 与 photo_access_denied 不触发重试并返回空结果', (tester) async {
      final fake = _FakeAndroidImagePicker()..onMultiPick = (_, _) => throw PlatformException(code: 'already_active');
      ImagePickerPlatform.instance = fake;
      final context = await _pumpDummyContext(tester);

      final multiResult = await GalleryHelper.pickMultiImages(context, maxAssets: 3);
      expect(multiResult, isEmpty);
      expect(fake.multiCallsWithPhotoPicker, [true]);

      fake.onSinglePick = (_) => throw PlatformException(code: 'photo_access_denied');
      final singleResult = await GalleryHelper.pickSingleImage(context);
      expect(singleResult, isNull);
      expect(fake.singleCallsWithPhotoPicker, [true]);
    });

    testWidgets('非 Android 平台实现可正常调用单选与多选', (tester) async {
      final fake = _FakeGenericImagePicker()
        ..singleResult = XFile('/tmp/ios_single.jpg')
        ..multiResult = [XFile('/tmp/ios_1.jpg'), XFile('/tmp/ios_2.jpg')];
      ImagePickerPlatform.instance = fake;
      final context = await _pumpDummyContext(tester);

      final single = await GalleryHelper.pickSingleImage(context);
      final multi = await GalleryHelper.pickMultiImages(context, maxAssets: 5);

      expect(single?.path, '/tmp/ios_single.jpg');
      expect(multi.map((e) => e.path).toList(), ['/tmp/ios_1.jpg', '/tmp/ios_2.jpg']);
      expect(fake.singleCallCount, 1);
      expect(fake.multiCallCount, 1);
      expect(fake.lastMultiLimit, 5);
    });
  });
}
