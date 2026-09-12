import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/generate_image_tool.dart';

void main() {
  group('GenerateImageTool 参数与基础定义', () {
    final tool = GenerateImageTool();

    test('工具名与串行调度模式', () {
      expect(tool.name, 'generate_image');
      expect(tool.executionMode, ToolExecutionMode.sequential);
    });

    test('parametersSchema 必填 prompt', () {
      final schema = tool.parametersSchema;
      expect(schema['required'], contains('prompt'));
      expect((schema['properties'] as Map).containsKey('size'), isTrue);
    });

    test('空 prompt 返回错误且不发起网络请求', () async {
      final result = await tool.execute({'prompt': '   '});
      expect(result.isError, isTrue);
      expect(result.modelOutput, contains('prompt 不能为空'));
    });
  });

  group('GenerateImageTool.parseGenerationImages（SenseNova images/generations 结构）', () {
    test('解析 b64_json 数组', () {
      final refs = GenerateImageTool.parseGenerationImages({
        'created': 1789206735,
        'data': [
          {'b64_json': 'aW1nLWJhc2U2NA=='},
          {'b64_json': 'aW1nLTI='},
        ],
      });
      expect(refs, ['aW1nLWJhc2U2NA==', 'aW1nLTI=']);
    });

    test('b64_json 缺失时回退读取 url 字段', () {
      final refs = GenerateImageTool.parseGenerationImages({
        'data': [
          {'url': 'https://example.com/a.png'},
          {'url': 'not-a-url'},
        ],
      });
      expect(refs, ['https://example.com/a.png']);
    });

    test('data 缺失或结构异常时返回空列表', () {
      expect(GenerateImageTool.parseGenerationImages({}), isEmpty);
      expect(GenerateImageTool.parseGenerationImages({'data': 'bad'}), isEmpty);
      expect(GenerateImageTool.parseGenerationImages({'data': [1, 'x']}), isEmpty);
    });
  });

  group('GenerateImageTool.parseChatImages（网关 chat/completions 结构）', () {
    test('解析 choices[].message.images[].image_url.url 的 data URI', () {
      final refs = GenerateImageTool.parseChatImages({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': null,
              'images': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,QUJDRA=='},
                },
              ],
            },
          },
        ],
      });
      expect(refs, ['data:image/jpeg;base64,QUJDRA==']);
    });

    test('image_url 为纯字符串 data URI 时同样解析', () {
      final refs = GenerateImageTool.parseChatImages({
        'choices': [
          {
            'message': {
              'images': [
                'data:image/png;base64,WFla',
                {'image_url': 'https://example.com/b.png'},
              ],
            },
          },
        ],
      });
      expect(refs, containsAll(<String>['data:image/png;base64,WFla', 'https://example.com/b.png']));
    });

    test('兜底解析 OpenAI 风格 data[].b64_json 结构', () {
      final refs = GenerateImageTool.parseChatImages({
        'data': [
          {'b64_json': 'Rm9v'},
        ],
      });
      expect(refs, ['Rm9v']);
    });

    test('无图片字段时返回空列表', () {
      expect(
        GenerateImageTool.parseChatImages({
          'choices': [
            {
              'message': {'role': 'assistant', 'content': '仅文本回复'},
            },
          ],
        }),
        isEmpty,
      );
    });
  });
}
