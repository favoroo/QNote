import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/anthropic_protocol.dart';
import 'package:qnote_flutter/models/ai_token_usage.dart';

void main() {
  group('基址归一化', () {
    test('官方根地址原样保留', () {
      expect(anthropicBaseUrl('https://api.anthropic.com'), 'https://api.anthropic.com');
    });

    test('粘了完整端点或末尾斜杠时归一化，避免拼出 /v1/v1/messages', () {
      expect(anthropicBaseUrl('https://api.anthropic.com/v1/messages'), 'https://api.anthropic.com');
      expect(anthropicBaseUrl('https://api.anthropic.com/v1/'), 'https://api.anthropic.com');
      expect(anthropicBaseUrl('https://relay.example.com/api/  '), 'https://relay.example.com/api');
    });

    test('聊天与模型列表端点都基于归一化后的根地址', () {
      expect(anthropicChatEndpoint('https://api.anthropic.com/v1'), 'https://api.anthropic.com/v1/messages');
      expect(anthropicModelsEndpoint('https://api.anthropic.com'), 'https://api.anthropic.com/v1/models');
    });
  });

  group('鉴权头', () {
    test('用 x-api-key + 版本头，并显式清掉 Authorization', () {
      final headers = anthropicAuthHeaders('sk-test');
      expect(headers['x-api-key'], 'sk-test');
      expect(headers['anthropic-version'], anthropicApiVersion);
      // null 是 Dio 的删除语义：路由组换到别家后残留的 Bearer 必须被清掉
      expect(headers.containsKey('Authorization'), isTrue);
      expect(headers['Authorization'], isNull);
    });
  });

  group('请求体转换', () {
    test('system 提到顶层，messages 只留 user/assistant', () {
      final body = buildAnthropicBody(
        model: 'claude-sonnet-5',
        messages: [
          {'role': 'system', 'content': '你是助手'},
          {'role': 'user', 'content': '你好'},
          {'role': 'assistant', 'content': '在'},
        ],
      );
      expect(body['system'], '你是助手');
      expect(body['model'], 'claude-sonnet-5');
      expect((body['messages'] as List).length, 2);
      expect(body['messages'][0], {'role': 'user', 'content': '你好'});
    });

    test('max_tokens 必填且缺省有值', () {
      final body = buildAnthropicBody(model: 'claude-sonnet-5', messages: const []);
      expect(body['max_tokens'], isA<int>());
      expect(body['max_tokens'], greaterThan(0));
    });

    test('多个 system 段合并，stream 与 temperature 按需注入', () {
      final body = buildAnthropicBody(
        model: 'claude-sonnet-5',
        messages: [
          {'role': 'system', 'content': 'A'},
          {'role': 'system', 'content': 'B'},
          {'role': 'user', 'content': 'hi'},
        ],
        temperature: 0.3,
        stream: true,
      );
      expect(body['system'], 'A\n\nB');
      expect(body['temperature'], 0.3);
      expect(body['stream'], isTrue);
      // Messages 没有 stream_options 这个参数，带上会被拒
      expect(body.containsKey('stream_options'), isFalse);
    });

    test('data URL 图片转成 image.source.base64', () {
      final body = buildAnthropicBody(
        model: 'claude-sonnet-5',
        messages: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': '看图'},
              {
                'type': 'image_url',
                'image_url': {'url': 'data:image/png;base64,AAAA'},
              },
            ],
          },
        ],
      );
      final content = (body['messages'] as List).first['content'] as List;
      expect(content[0], {'type': 'text', 'text': '看图'});
      expect(content[1], {
        'type': 'image',
        'source': {'type': 'base64', 'media_type': 'image/png', 'data': 'AAAA'},
      });
    });

    test('tool 角色与工具调用消息被丢弃（本协议不支持工具）', () {
      final body = buildAnthropicBody(
        model: 'claude-sonnet-5',
        messages: [
          {'role': 'user', 'content': 'hi'},
          {'role': 'tool', 'content': '工具结果'},
          {'role': 'assistant', 'content': null, 'tool_calls': []},
        ],
      );
      expect((body['messages'] as List).length, 1);
    });

    test('空白文本消息被丢弃，避免空内容块被拒', () {
      final body = buildAnthropicBody(
        model: 'claude-sonnet-5',
        messages: [
          {'role': 'user', 'content': '   '},
          {'role': 'user', 'content': 'real'},
        ],
      );
      expect((body['messages'] as List).length, 1);
    });
  });

  group('思考预算', () {
    test('未知档位与 none 不发 thinking', () {
      expect(anthropicThinkingBudget(null), isNull);
      expect(anthropicThinkingBudget('none'), isNull);
      expect(anthropicThinkingBudget('nope'), isNull);
    });

    test('档位映射到 >= 1024 的预算（Anthropic 的硬性下限）', () {
      expect(anthropicThinkingBudget('minimal'), greaterThanOrEqualTo(1024));
      expect(anthropicThinkingBudget('high'), greaterThan(anthropicThinkingBudget('low')!));
    });

    test('预算不小于 max_tokens 时自动抬高 max_tokens', () {
      final body = buildAnthropicBody(
        model: 'claude-sonnet-5',
        messages: [
          {'role': 'user', 'content': 'hi'},
        ],
        maxTokens: 2048,
        thinkingEffort: 'high',
      );
      final budget = (body['thinking'] as Map)['budget_tokens'] as int;
      expect(body['max_tokens'], greaterThan(budget));
    });
  });

  group('响应与流式解析', () {
    test('非流式取 content[].text，跳过 thinking 块', () {
      final data = {
        'content': [
          {'type': 'thinking', 'thinking': '内部推理'},
          {'type': 'text', 'text': '你好'},
          {'type': 'text', 'text': '，世界'},
        ],
        'stop_reason': 'end_turn',
      };
      expect(anthropicExtractText(data), '你好，世界');
      expect(anthropicExtractStopReason(data), 'end_turn');
    });

    test('流式只认 text_delta / thinking_delta，其他事件返回 null', () {
      expect(
        anthropicStreamText({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': 'hi'},
        }),
        'hi',
      );
      expect(
        anthropicStreamReasoning({
          'type': 'content_block_delta',
          'delta': {'type': 'thinking_delta', 'thinking': '想'},
        }),
        '想',
      );
      expect(anthropicStreamText({'type': 'message_start', 'message': {}}), isNull);
      expect(
        anthropicStreamText({
          'type': 'content_block_delta',
          'delta': {'type': 'text_delta', 'text': ''},
        }),
        isNull,
      );
    });

    test('error 事件给出可读原因', () {
      expect(
        anthropicStreamError({
          'type': 'error',
          'error': {'type': 'overloaded_error', 'message': 'Overloaded'},
        }),
        'Overloaded',
      );
      expect(anthropicStreamError({'type': 'message_stop'}), isNull);
    });

    test('usage 跨帧合并：输入来自 message_start、输出来自 message_delta', () {
      final first = mergeAnthropicUsage({
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 120, 'output_tokens': 1},
        },
      }, null);
      expect(first, const AiTokenUsage(promptTokens: 120, completionTokens: 1, totalTokens: 121));

      final merged = mergeAnthropicUsage({
        'type': 'message_delta',
        'usage': {'output_tokens': 80},
      }, first);
      expect(merged, const AiTokenUsage(promptTokens: 120, completionTokens: 80, totalTokens: 200));
    });

    test('没有 usage 的事件不覆盖已记录的值', () {
      const current = AiTokenUsage(promptTokens: 10, completionTokens: 5, totalTokens: 15);
      expect(mergeAnthropicUsage({'type': 'ping'}, current), current);
    });

    test('message_stop 标记收尾', () {
      expect(anthropicStreamFinished({'type': 'message_stop'}), isTrue);
      expect(anthropicStreamFinished({'type': 'message_delta'}), isFalse);
    });
  });
}
