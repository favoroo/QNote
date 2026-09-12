import 'package:flutter_test/flutter_test.dart';
import 'package:qnote_flutter/core/agent/agent_tool_labels.dart';

void main() {
  group('AgentToolLabels.detailFromPartialArguments', () {
    test('write_file：path 完整流出时提取路径', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'write_file',
        '{"path": "/notes/个人网页/index.html", "content": "<!DOCTYPE html><html>',
      );
      expect(detail['path'], '/notes/个人网页/index.html');
    });

    test('content 未闭合（仍在流式生成）不影响 path 提取', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'write_file',
        '{"path": "/notes/a.md", "content": "尚未写完的内容片段',
      );
      expect(detail['path'], '/notes/a.md');
      expect(detail.containsKey('content'), isFalse);
    });

    test('值内转义引号不破坏提取并正确反转义', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'write_file',
        r'{"path": "/notes/\"quoted\".md"}',
      );
      expect(detail['path'], '/notes/"quoted".md');
    });

    test('Unicode 转义反转义', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'web_search',
        '{"query": "\\u63a7\\u7cd6\\u996e\\u98df"}',
      );
      expect(detail['query'], '控糖饮食');
    });

    test('grep：按候选键顺序取 pattern', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'grep',
        '{"pattern": "体重", "path": "/notes"}',
      );
      expect(detail['pattern'], '体重');
    });

    test('path 尚未流出时返回空 map', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'write_file',
        '{"content": "直接先写了内容',
      );
      expect(detail, isEmpty);
    });

    test('未知工具返回空 map', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'unknown_tool',
        '{"path": "/notes/a.md"}',
      );
      expect(detail, isEmpty);
    });

    test('空参数返回空 map', () {
      expect(
        AgentToolLabels.detailFromPartialArguments('write_file', ''),
        isEmpty,
      );
    });
  });

  group('AgentToolLabels.progressLabel 组合部分参数快照', () {
    test('可直接消费 detailFromPartialArguments 的结果', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'write_file',
        '{"path": "/notes/个人网页/index.html", "content": "x',
      );
      expect(
        AgentToolLabels.progressLabel('write_file', detail),
        '正在写入文件 · /notes/个人网页/index.html',
      );
    });

    test('快照为空时回退纯工具文案', () {
      expect(
        AgentToolLabels.progressLabel('write_file', const {}),
        '正在写入文件',
      );
    });

    test('超长路径按既有截断规则收敛', () {
      final detail = AgentToolLabels.detailFromPartialArguments(
        'write_file',
        '{"path": "/notes/a-very-long-path-that-exceeds-the-truncate-limit.md"}',
      );
      final label = AgentToolLabels.progressLabel('write_file', detail);
      expect(label, startsWith('正在写入文件 · '));
      expect(label.endsWith('…'), isTrue);
    });
  });
}
