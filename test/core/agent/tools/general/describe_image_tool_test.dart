import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/describe_image_tool.dart';

/// 记录被调用的次数与入参，替代真实的视觉链路请求（不打网关）
class _RecordingVision {
  static const String answer = '左半边是红色，右半边是蓝色';

  final Object? throwsOnCall;
  int calls = 0;
  String? lastQuestion;
  String? lastImage;

  _RecordingVision({this.throwsOnCall});

  Future<String> call(String question, String imageDataUri) async {
    calls++;
    lastQuestion = question;
    lastImage = imageDataUri;
    if (throwsOnCall != null) throw throwsOnCall!;
    return answer;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 一张 1×1 的合法 PNG，够用来验证 data URI 原样透传
  const tinyPngUri =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJ'
      'AAAADUlEQVR42mP8z8DwHwAFAAH/q842iQAAAABJRU5ErkJggg==';

  group('DescribeImageTool 参数与基础定义', () {
    final tool = DescribeImageTool();

    test('工具名与并行调度模式（只读、无副作用）', () {
      expect(tool.name, 'describe_image');
      expect(tool.executionMode, ToolExecutionMode.parallel);
    });

    test('schema 必填 path、可选 question', () {
      final schema = tool.parametersSchema;
      expect(schema['required'], ['path']);
      final props = schema['properties'] as Map;
      expect(props.containsKey('question'), isTrue);
    });

    test('描述里点明返回文字结果、不与 view_image 抢活', () {
      expect(tool.description, contains('文字'));
      expect(tool.description, contains('不支持图片输入'));
      expect(tool.description, contains('虚构路径'));
    });
  });

  group('DescribeImageTool.execute 入参分流', () {
    test('空 path 直接失败且不发起识图请求', () async {
      final vision = _RecordingVision();
      final tool = DescribeImageTool(visionRequester: vision.call);

      final result = await tool.execute({'path': '   '});

      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('图片路径为空'));
      expect(vision.calls, 0);
    });

    test('data URI 原样透传给视觉链路，不重新编码', () async {
      final vision = _RecordingVision();
      final tool = DescribeImageTool(visionRequester: vision.call);

      final result = await tool.execute({'path': tinyPngUri});

      expect(vision.calls, 1);
      expect(vision.lastImage, tinyPngUri);
      expect(result.isError, isFalse);
    });

    test('未传 question 时用默认提问（既描述画面也抄录图中文字）', () async {
      final vision = _RecordingVision();
      final tool = DescribeImageTool(visionRequester: vision.call);

      await tool.execute({'path': tinyPngUri});

      expect(vision.lastQuestion, DescribeImageTool.defaultQuestion);
      expect(vision.lastQuestion, contains('描述'));
      expect(vision.lastQuestion, contains('抄出'));
    });

    test('传了 question 时按原样发给识图模型', () async {
      final vision = _RecordingVision();
      final tool = DescribeImageTool(visionRequester: vision.call);

      await tool.execute({'path': tinyPngUri, 'question': '图上有几个苹果？'});

      expect(vision.lastQuestion, '图上有几个苹果？');
    });

    test('读不到的本地路径失败但不发请求，且文案禁止编造', () async {
      final vision = _RecordingVision();
      final tool = DescribeImageTool(visionRequester: vision.call);

      final result = await tool.execute({
        'path': '${Directory.systemTemp.path}/qnote-missing-image-9f3a.jpg',
      });

      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('不存在或读取失败'));
      expect(result.modelOutput, contains('严禁凭想象'));
      expect(vision.calls, 0);
    });

    test('识图请求抛异常时收敛为错误结果，不把异常抛回 AgentLoop', () async {
      final vision = _RecordingVision(throwsOnCall: Exception('429 quota'));
      final tool = DescribeImageTool(visionRequester: vision.call);

      final result = await tool.execute({'path': tinyPngUri});

      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('识图请求失败'));
    });
  });

  group('DescribeImageTool.buildVisionResult', () {
    final tool = DescribeImageTool(visionRequester: (_, _) async => '');

    test('正常结果带识图来源标记与 uiDetails', () {
      final result = tool.buildVisionResult(
        '/images/a.jpg',
        '图里是什么颜色',
        '  左=红色，右=蓝色  ',
      );

      expect(result.isError, isFalse);
      expect(result.modelOutput, contains('左=红色，右=蓝色'));
      expect(result.modelOutput, contains('识图结果'));
      // 必须提醒模型这不是它自己看到的，避免它把识图结果说成亲眼所见
      expect(result.modelOutput, contains('并未直接看到画面'));
      expect(result.uiDetails?['type'], 'describe_image');
      expect(result.uiDetails?['path'], '/images/a.jpg');
      expect(result.uiDetails?['model'], 'sensenova-6.8-flash-lite');
      // 识图工具返回文字，绝不把图片本体塞回上下文
      expect(result.images, isNull);
    });

    test('空回复算失败（否则模型会把「没内容」当成图片是空的）', () {
      final result = tool.buildVisionResult('/images/a.jpg', '问题', '   ');

      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('没有返回内容'));
    });

    test('超长回复按输出上限截断，不冲爆上下文', () {
      final result = tool.buildVisionResult(
        '/images/a.jpg',
        '问题',
        '字' * 4000,
      );

      expect(result.modelOutput, contains('输出已截断'));
      expect(result.modelOutput.length, lessThan(4200));
    });

    test('内联图片在展示标签里只写体积，不回显 base64', () {
      final result = tool.buildVisionResult(tinyPngUri, '问题', '红色');

      expect(result.uiDetails?['path'], contains('内联图片'));
      expect(result.uiDetails?['path'], isNot(contains('iVBORw0KGgo')));
    });
  });

  group('输入形态与图片类型判定（纯函数）', () {
    test('classifyImageSource 区分 data URI / http(s) / 本地路径', () {
      expect(
        DescribeImageTool.classifyImageSource('DATA:image/jpeg;base64,AAA'),
        ImageSourceKind.dataUri,
      );
      expect(
        DescribeImageTool.classifyImageSource('https://a.com/x.png'),
        ImageSourceKind.url,
      );
      expect(
        DescribeImageTool.classifyImageSource('/images/x.png'),
        ImageSourceKind.localPath,
      );
    });

    test('detectImageMime 按文件头识别，未知一律兜到 jpeg', () {
      expect(DescribeImageTool.detectImageMime(_bytes([0xFF, 0xD8, 0xFF])), 'image/jpeg');
      expect(
        DescribeImageTool.detectImageMime(
          _bytes([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0]),
        ),
        'image/png',
      );
      final webp = List<int>.filled(12, 0);
      webp.setAll(0, [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50]);
      expect(DescribeImageTool.detectImageMime(webp), 'image/webp');
      expect(DescribeImageTool.detectImageMime([1, 2, 3]), 'image/jpeg');
    });

    test('resolveDownloadedMime 优先信响应头，CDN 报成 octet-stream 时退回魔数', () {
      final pngBytes = _bytes([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0, 0, 0, 0, 0]);
      expect(
        DescribeImageTool.resolveDownloadedMime('image/webp', pngBytes),
        'image/webp',
      );
      expect(
        DescribeImageTool.resolveDownloadedMime(
          'application/octet-stream',
          pngBytes,
        ),
        'image/png',
      );
      expect(DescribeImageTool.resolveDownloadedMime(null, pngBytes), 'image/png');
    });

    test('默认提问同时要求描述画面与抄录图中文字', () {
      expect(DescribeImageTool.defaultQuestion, contains('描述'));
      expect(DescribeImageTool.defaultQuestion, contains('抄出'));
    });
  });
}

List<int> _bytes(List<int> head) {
  final full = List<int>.filled(12, 0);
  full.setAll(0, head);
  return full;
}
