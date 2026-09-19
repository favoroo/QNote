import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/models/agent_tool.dart';
import 'package:qnote_flutter/core/agent/tools/general/generate_image_tool.dart';
import 'package:qnote_flutter/models/ai_config.dart';

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

  group('GenerateImageTool.parseChatImagesDetailed（图片形态兼容）', () {
    test('OpenAI 多模态 content parts 数组里的 image_url 能解析', () {
      final outcome = GenerateImageTool.parseChatImagesDetailed({
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': [
                {'type': 'text', 'text': '图好了'},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/png;base64,QUJD'},
                },
              ],
            },
          },
        ],
      });
      expect(outcome.refs, ['data:image/png;base64,QUJD']);
      expect(outcome.shapes, contains(GenerateImageTool.shapeContentParts));
      expect(outcome.hasImages, isTrue);
    });

    test('AI-studio 网关把图片转成正文 Markdown data URI 时同样能解析', () {
      final outcome = GenerateImageTool.parseChatImagesDetailed({
        'choices': [
          {
            'message': {
              'content': '看这张图：\n![Generated Image](data:image/jpeg;base64,/9j/4AAQSkZJRgAB)'
                  '更长的载荷xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
            },
          },
        ],
      });
      expect(outcome.refs, hasLength(1));
      expect(outcome.refs.single, startsWith('data:image/jpeg;base64,/9j/4AAQ'));
      expect(outcome.shapes, contains(GenerateImageTool.shapeContentMarkdown));
    });

    test('正文里的 Markdown http 图片链接可提取', () {
      final refs = GenerateImageTool.extractMarkdownImageRefs(
        '结果如下 ![a](https://cdn.example.com/x.png) 以及 ![b](<https://y.example/z.jpg>)',
      );
      expect(refs, ['https://cdn.example.com/x.png', 'https://y.example/z.jpg']);
    });

    test('Google 原生 inlineData 节点转为 data URI', () {
      final outcome = GenerateImageTool.parseChatImagesDetailed({
        'choices': [
          {
            'message': {
              'content': [
                {
                  'inlineData': {'mimeType': 'image/webp', 'data': 'V0VCUA=='},
                },
              ],
            },
          },
        ],
      });
      expect(outcome.refs, ['data:image/webp;base64,V0VCUA==']);
      expect(outcome.shapes, contains(GenerateImageTool.shapeInlineData));
    });

    test('整段 content 就是一张 data URI 图片时也能解析', () {
      final refs = GenerateImageTool.parseChatImages({
        'choices': [
          {'message': {'content': 'data:image/png;base64,WFla'}},
        ],
      });
      expect(refs, ['data:image/png;base64,WFla']);
    });

    test('多形态混合时按出现顺序去重', () {
      final refs = GenerateImageTool.parseChatImages({
        'choices': [
          {
            'message': {
              'images': [
                {'image_url': {'url': 'data:image/png;base64,AAA'}},
                {'image_url': {'url': 'data:image/png;base64,AAA'}},
              ],
              'content': [
                {'type': 'image_url', 'image_url': {'url': 'https://e.com/b.png'}},
              ],
            },
          },
        ],
      });
      expect(refs, ['data:image/png;base64,AAA', 'https://e.com/b.png']);
    });
  });

  group('GenerateImageTool.parseChatImagesDetailed（失败分类判据）', () {
    test('上游空壳（无图片线索、零 usage）判为上游空结果', () {
      final outcome = GenerateImageTool.parseChatImagesDetailed({
        'id': 'x',
        'choices': [
          {
            'message': {'role': 'assistant', 'content': null, 'images': null},
            'finish_reason': 'stop',
          },
        ],
      });
      expect(outcome.hasImages, isFalse);
      expect(outcome.sawImageLikeField, isFalse);
      expect(outcome.summary, contains('images=none'));
      expect(outcome.summary, contains('usage=none'));
    });

    test('出现图片节点但取不出引用时判为格式未识别', () {
      final outcome = GenerateImageTool.parseChatImagesDetailed({
        'choices': [
          {
            'message': {
              'images': [
                {'image_url': {'url': ''}},
              ],
            },
          },
        ],
      });
      expect(outcome.hasImages, isFalse);
      expect(outcome.sawImageLikeField, isTrue);
    });

    test('真实网关成功响应（message.images + 非零 usage）解析出图片且形态标签正确', () {
      final outcome = GenerateImageTool.parseChatImagesDetailed({
        'model': 'gemini-3.1-flash-image',
        'choices': [
          {
            'message': {
              'role': 'assistant',
              'content': null,
              'images': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,/9j/4AAQSkZJRg'},
                  'index': 0,
                },
              ],
            },
            'finish_reason': 'stop',
          },
        ],
        'usage': {'prompt_tokens': 20, 'completion_tokens': 1474, 'total_tokens': 1494},
      });
      expect(outcome.hasImages, isTrue);
      expect(outcome.shapes, {GenerateImageTool.shapeMessageImages});
      expect(outcome.summary, contains('usage=20/1474/1494'));
    });
  });

  group('GenerateImageTool.summarizeImageResponse（日志脱敏）', () {
    test('base64 载荷替换为占位符，摘要不含图片原文', () {
      final huge = 'A' * 400_000;
      final summary = GenerateImageTool.summarizeImageResponse({
        'choices': [
          {
            'message': {
              'content': '![img](data:image/png;base64,$huge)',
            },
          },
        ],
      });
      expect(summary, isNot(contains('AAAAAA')));
      expect(summary, contains('<BASE64≈'));
      expect(summary.length, lessThanOrEqualTo(620));
    });

    test('错误信息里的 API Key 打码', () {
      final summary = GenerateImageTool.summarizeImageResponse({
        'error': {'message': 'invalid key sk-abcdefgh12345678 provided'},
      });
      expect(summary, isNot(contains('sk-abcdefgh12345678')));
      expect(summary, contains('sk-***'));
    });

    test('images/generations 错误包也能给出结构提示', () {
      final summary = GenerateImageTool.summarizeImageResponse({
        'message': 'quota exceeded',
        'data': <Object>[],
      });
      expect(summary, contains('data=0'));
      expect(summary, contains('quota exceeded'));
    });
  });

  group('GenerateImageTool.ImageFailureKind 文案', () {
    test('每种失败分类都有中文标签', () {
      for (final kind in ImageFailureKind.values) {
        expect(kind.label, isNotEmpty);
      }
    });
  });

  group('GenerateImageTool.classifyParseResult（失败分类）', () {
    test('无图片线索 => 上游空结果', () {
      const outcome = ImageParseOutcome(
        refs: [],
        shapes: {},
        sawImageLikeField: false,
        summary: 'usage=none',
      );
      expect(GenerateImageTool.classifyParseResult(outcome), ImageFailureKind.upstreamEmpty);
    });

    test('有图片线索但取不出引用 => 格式未识别', () {
      const outcome = ImageParseOutcome(
        refs: [],
        shapes: {},
        sawImageLikeField: true,
        summary: 'images=1',
      );
      expect(GenerateImageTool.classifyParseResult(outcome), ImageFailureKind.unknownFormat);
    });
  });

  group('GenerateImageTool.shouldTryFallback（降级判据）', () {
    test('上游空结果且预算充足 => 允许降级', () {
      expect(
        GenerateImageTool.shouldTryFallback(ImageFailureKind.upstreamEmpty,
            const Duration(seconds: 70)),
        isTrue,
      );
    });

    test('HTTP 错误（秒级失败）=> 允许降级', () {
      expect(
        GenerateImageTool.shouldTryFallback(ImageFailureKind.httpError,
            const Duration(seconds: 1)),
        isTrue,
      );
    });

    test('本地保存失败 => 换后端无解，不降级', () {
      expect(
        GenerateImageTool.shouldTryFallback(ImageFailureKind.saveFailed,
            const Duration(seconds: 1)),
        isFalse,
      );
    });

    test('剩余预算不足一次降级请求 => 放弃降级', () {
      expect(
        GenerateImageTool.shouldTryFallback(ImageFailureKind.timeout,
            const Duration(seconds: 150)),
        isFalse,
      );
      expect(
        GenerateImageTool.shouldTryFallback(ImageFailureKind.upstreamEmpty,
            const Duration(seconds: 149)),
        isTrue,
      );
    });
  });

  group('GenerateImageTool.describeFailures（给模型的可执行文案）', () {
    test('空尝试列表也要给出如实告知且禁止编造路径的文案', () {
      final text = GenerateImageTool.describeFailures([]);
      expect(text, contains('严禁编造图片路径'));
    });

    test('上游空结果文案要说明与用户描述无关并建议重试', () {
      final text = GenerateImageTool.describeFailures([
        ImageAttempt.failure(geminiConfig, ImageFailureKind.upstreamEmpty,
            const Duration(seconds: 70),
            detail: '网关接受请求但未产出图片'),
      ]);
      expect(text, contains('Gemini 生图'));
      expect(text, contains('上游返回空结果'));
      expect(text, contains('与用户的描述无关'));
      expect(text, contains('严禁编造图片路径'));
    });

    test('主备双失败时两条后端与各自分类都要出现', () {
      final text = GenerateImageTool.describeFailures([
        ImageAttempt.failure(geminiConfig, ImageFailureKind.upstreamEmpty,
            const Duration(seconds: 70)),
        ImageAttempt.failure(sensenovaConfig, ImageFailureKind.httpError,
            const Duration(seconds: 3)),
      ]);
      expect(text, contains('Gemini 生图'));
      expect(text, contains('SenseNova 生图'));
      expect(text, contains('上游返回空结果'));
      expect(text, contains('服务返回错误'));
    });

    test('成功尝试的分类兜底为 unknown 且 succeeded 为真', () {
      final attempt = ImageAttempt.success(
          geminiConfig, ['/tmp/a.png'], const Duration(seconds: 9));
      expect(attempt.succeeded, isTrue);
      expect(attempt.failureKind, ImageFailureKind.unknown);
      expect(attempt.saved, ['/tmp/a.png']);
    });
  });

  group('GenerateImageTool.stripDataUriPrefix（保存前引用规范化）', () {
    test('data URI 剥掉前缀返回纯 base64', () {
      final base64 =
          GenerateImageTool.stripDataUriPrefix('data:image/jpeg;base64,/9j/4AAQSkZJRg');
      expect(base64, '/9j/4AAQSkZJRg');
    });

    test('裸 base64 原样返回', () {
      expect(GenerateImageTool.stripDataUriPrefix('aW1nLWJhc2U2NA=='), 'aW1nLWJhc2U2NA==');
    });

    test('data: 开头但无 base64, 标记时返回 null（无法解码）', () {
      expect(GenerateImageTool.stripDataUriPrefix('data:image/svg+xml;utf8,<svg/>'), isNull);
    });

    test('parseChatImages 输出的 data URI 可被规范化为合法 base64 并解码', () {
      final refs = GenerateImageTool.parseChatImages({
        'choices': [
          {
            'message': {
              'images': [
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,$aValidBase64'},
                },
              ],
            },
          },
        ],
      });
      final stripped = GenerateImageTool.stripDataUriPrefix(refs.single);
      expect(stripped, aValidBase64);
      // 不抛异常即验证是合法 base64
      expect(() => base64Decode(stripped!), returnsNormally);
    });
  });
}

const String aValidBase64 = 'SGVsbG8gUUhOb3RlIQ==';

/// 两个内置生图后端的测试配置：仅用于文案与分类断言，不含真实 Key、不发起网络请求
final AiConfig geminiConfig = AiConfig(
  id: 'free_gemini-3.1-flash-image',
  name: 'Gemini 生图',
  provider: 'openai',
  modelName: 'gemini-3.1-flash-image',
  apiKey: 'sk-test-placeholder',
  baseUrl: 'https://cpa-gateway.example/v1',
  createdAt: DateTime(2026, 9, 19),
  updatedAt: DateTime(2026, 9, 19),
);

final AiConfig sensenovaConfig = AiConfig(
  id: 'free_sensenova-u1.5-lite',
  name: 'SenseNova 生图',
  provider: 'openai',
  modelName: 'sensenova-u1.5-lite',
  apiKey: 'sk-test-placeholder',
  baseUrl: 'https://token.sensenova.cn/v1',
  createdAt: DateTime(2026, 9, 19),
  updatedAt: DateTime(2026, 9, 19),
);

