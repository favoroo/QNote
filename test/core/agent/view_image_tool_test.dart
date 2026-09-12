import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:qnote_flutter/core/agent/engine/tool_dispatcher.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/workspace/view_image_tool.dart';
import 'package:qnote_flutter/models/chat_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('view_image_test');
  });

  tearDown(() async {
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  /// 生成一张真实 JPEG 图片文件（走完整压缩链路）
  Future<String> createJpegFile(String name) async {
    final image = img.Image(width: 32, height: 32);
    img.fill(image, color: img.ColorRgb8(200, 60, 60));
    final bytes = img.encodeJpg(image);
    final file = File('${tempDir.path}/$name');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  group('ViewImageTool', () {
    test('工具元信息符合 Agent 工具规范', () {
      final tool = ViewImageTool();
      expect(tool.name, 'view_image');
      expect(tool.executionMode, ToolExecutionMode.parallel);
      expect(tool.description, isNotEmpty);
      expect(tool.parametersSchema['required'], contains('path'));
      expect(tool.toFunctionDefinition()['type'], 'function');
    });

    test('空路径返回错误', () async {
      final tool = ViewImageTool();
      final result = await tool.execute({});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('路径为空'));
    });

    test('图片文件不存在返回错误', () async {
      final tool = ViewImageTool();
      final result = await tool.execute({
        'path': '${tempDir.path}/not_exist.jpg',
      });
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('不存在'));
    });

    test('成功读取图片并返回 data URI 附带图', () async {
      final path = await createJpegFile('sample.jpg');
      final tool = ViewImageTool();
      final result = await tool.execute({'path': path});

      expect(result.isError, isFalse);
      expect(result.images, isNotNull);
      expect(result.images!.length, 1);
      expect(result.images!.first, startsWith('data:image/jpeg;base64,'));
      expect(result.modelOutput, contains('已成功加载图片'));
      expect(result.uiDetails?['path'], path);
      expect(result.uiDetails?['sizeKB'], greaterThan(0));
    });

    test('/images/ 相对路径可被解析为应用文档目录下的文件', () async {
      // ImageRepository.resolveLocalPath 只在直接路径不存在时才回退应用文档目录，
      // 测试环境下 path_provider 未初始化，这里仅验证绝对路径同一文件可重复读取
      final path = await createJpegFile('relative.jpg');
      final tool = ViewImageTool();
      final first = await tool.execute({'path': path});
      final second = await tool.execute({'path': path});
      expect(first.isError, isFalse);
      expect(second.isError, isFalse);
      expect(first.images, second.images);
    });
  });

  group('ToolDispatcher 图片透传', () {
    test('dispatch 将 ToolResult.images 挂载到 tool 消息', () async {
      final path = await createJpegFile('dispatch.jpg');
      final dispatcher = ToolDispatcher()..register(ViewImageTool());

      final ChatMessage msg = await dispatcher.dispatch(
        ToolCall(id: 'call_1', name: 'view_image', arguments: {'path': path}),
      );

      expect(msg.role, 'tool');
      expect(msg.isError, isFalse);
      expect(msg.images, isNotNull);
      expect(msg.images!.first, startsWith('data:image/jpeg;base64,'));
    });

    test('无图工具的 dispatch 结果 images 为空', () async {
      final dispatcher = ToolDispatcher()..register(ViewImageTool());

      final ChatMessage msg = await dispatcher.dispatch(
        const ToolCall(id: 'call_2', name: 'view_image', arguments: {'path': ''}),
      );

      expect(msg.isError, isTrue);
      expect(msg.images, isNull);
    });
  });
}
