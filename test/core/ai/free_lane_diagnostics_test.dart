import 'package:flutter_test/flutter_test.dart';

import 'package:qnote_flutter/core/ai/free_lane_diagnostics.dart';
import 'package:qnote_flutter/models/ai_request_stat.dart';

/// 免费网关观测汇总纯函数单测（不碰数据库，聚合口径的回归锁）
void main() {
  AiRequestStat row({
    required String keyMask,
    required String outcome,
    String modelId = 'deepseek-flash',
    int? ttftMs,
    int latencyMs = 1000,
    int? promptTokens,
    int? cachedTokens,
    DateTime? createdAt,
  }) {
    return AiRequestStat(
      scene: '带工具流式对话',
      modelId: modelId,
      keyMask: keyMask,
      outcome: outcome,
      latencyMs: latencyMs,
      ttftMs: ttftMs,
      promptTokens: promptTokens,
      completionTokens: null,
      cachedTokens: cachedTokens,
      createdAt: createdAt ?? DateTime(2026, 9, 25, 10),
    );
  }

  group('FreeLaneDiagnostics.summarize', () {
    test('空输入得到空汇总（面板据此整卡不显示）', () {
      final summary = FreeLaneDiagnostics.summarize(const []);
      expect(summary.isEmpty, isTrue);
      expect(summary.limitRate, equals(0));
      expect(summary.successRate, equals(0));
      expect(summary.avgTtftMs, isNull);
    });

    test('总量、成功数、限流数与比率按形态分列统计', () {
      final summary = FreeLaneDiagnostics.summarize([
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.tpm),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.rps),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.auth),
      ]);

      expect(summary.total, equals(4));
      expect(summary.okCount, equals(1));
      expect(summary.limitedCount, equals(2), reason: 'rps 与额度都算限流');
      expect(summary.authCount, equals(1));
      expect(summary.successRate, closeTo(0.25, 0.001));
      expect(summary.limitRate, closeTo(0.5, 0.001));
    });

    test('首字均值只统计有 TTFT 样本，不被非流式行稀释', () {
      final summary = FreeLaneDiagnostics.summarize([
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, ttftMs: 900),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, ttftMs: 1100),
        // 日记提取这类非流式请求没有 ttft，但 latency 有值
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, latencyMs: 3000),
      ]);

      expect(summary.ttftSamples, equals(2));
      expect(summary.avgTtftMs, equals(1000));
      // (1000 + 1000 + 3000) / 3 四舍五入
      expect(summary.avgLatencyMs, equals(1667));
    });

    test('token 全缺时 hasTokenData 为 false，面板显示「未上报」而非 0', () {
      final noTokens = FreeLaneDiagnostics.summarize([
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok),
      ]);
      expect(noTokens.hasTokenData, isFalse);
      expect(FreeLaneFormats.tokens(noTokens.promptTokens), equals('未上报'));

      final withTokens = FreeLaneDiagnostics.summarize([
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, promptTokens: 18000, cachedTokens: 12000),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, promptTokens: 2000),
      ]);
      expect(withTokens.hasTokenData, isTrue);
      expect(withTokens.promptTokens, equals(20000));
      expect(withTokens.cachedTokens, equals(12000));
    });

    test('按 Key 切片：最成问题的 Key 排最前，且小样本噪声靠后', () {
      final summary = FreeLaneDiagnostics.summarize([
        // 1 条样本 100% 撞墙（噪声）
        row(keyMask: 'sk-noise...1', outcome: AiRequestOutcomes.tpm),
        // 5 条样本 60% 撞墙（真问题）
        ...List.generate(
          3,
          (_) => row(keyMask: 'sk-bad0...2', outcome: AiRequestOutcomes.tpm),
        ),
        ...List.generate(
          2,
          (_) => row(keyMask: 'sk-bad0...2', outcome: AiRequestOutcomes.ok),
        ),
        ...List.generate(
          4,
          (_) => row(keyMask: 'sk-good...3', outcome: AiRequestOutcomes.ok),
        ),
      ]);

      expect(summary.byKey.map((b) => b.label),
          equals(['sk-bad0...2', 'sk-noise...1', 'sk-good...3']));
      final worst = summary.byKey.first;
      expect(worst.total, equals(5));
      expect(worst.limitRate, closeTo(0.6, 0.001));
      expect(worst.failRate, closeTo(0.6, 0.001));
    });

    test('按模型切片：只有一个模型时 modelCount=1（面板不再重复列一遍）', () {
      final summary = FreeLaneDiagnostics.summarize([
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, modelId: 'deepseek-flash'),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, modelId: 'glm-5.2'),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.tpm, modelId: 'glm-5.2'),
      ]);

      expect(summary.modelCount, equals(2));
      final glm = summary.byModel.firstWhere((b) => b.label == 'glm-5.2');
      expect(glm.total, equals(2));
      expect(glm.okCount, equals(1));
    });

    test('掩码缺失（非池路径）时归到「未标注 Key」而不是丢进同一个桶', () {
      final summary = FreeLaneDiagnostics.summarize([
        row(keyMask: '', outcome: AiRequestOutcomes.ok),
        row(keyMask: '', outcome: AiRequestOutcomes.ok),
      ]);
      expect(summary.byKey, hasLength(1));
      expect(summary.byKey.first.label, equals('未标注 Key'));
      expect(summary.byKey.first.total, equals(2));
    });

    test('未知 outcome 落进 other 桶，不会被静默吞掉', () {
      final summary = FreeLaneDiagnostics.summarize([
        row(keyMask: 'sk-a...0001', outcome: 'weird'),
      ]);
      expect(summary.otherCount, equals(1));
      expect(summary.okCount, equals(0));
    });

    test('统计窗口取最早与最晚一行', () {
      final summary = FreeLaneDiagnostics.summarize([
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, createdAt: DateTime(2026, 9, 25, 11)),
        row(keyMask: 'sk-a...0001', outcome: AiRequestOutcomes.ok, createdAt: DateTime(2026, 9, 25, 9)),
      ]);
      expect(summary.firstAt, equals(DateTime(2026, 9, 25, 9)));
      expect(summary.lastAt, equals(DateTime(2026, 9, 25, 11)));
    });
  });

  group('FreeLaneFormats', () {
    test('百分比取整，避免 0.3799999 直接进面板', () {
      expect(FreeLaneFormats.percent(0.379), equals('38%'));
      expect(FreeLaneFormats.percent(0), equals('0%'));
      expect(FreeLaneFormats.percent(1), equals('100%'));
    });

    test('毫秒小于 1 秒用 ms，更大用一位小数的秒，空值用破折号', () {
      expect(FreeLaneFormats.duration(850), equals('850ms'));
      expect(FreeLaneFormats.duration(1200), equals('1.2s'));
      expect(FreeLaneFormats.duration(null), equals('—'));
      expect(FreeLaneFormats.duration(0), equals('—'));
    });
  });
}
