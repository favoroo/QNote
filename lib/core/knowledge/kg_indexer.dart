import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/knowledge/kg_communities.dart';
import 'package:qnote_flutter/core/knowledge/kg_config.dart';
import 'package:qnote_flutter/core/knowledge/kg_dictionaries.dart';
import 'package:qnote_flutter/core/knowledge/kg_extractor.dart';
import 'package:qnote_flutter/core/knowledge/kg_insight_service.dart';
import 'package:qnote_flutter/core/knowledge/kg_llm_extractor.dart';
import 'package:qnote_flutter/core/knowledge/kg_resolver.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/database_helper.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/folder_repository.dart';
import 'package:qnote_flutter/core/storage/health_metric_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/knowledge_graph_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/screen_usage_daily_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/utils/kg_text.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/health_daily_metrics.dart';
import 'package:qnote_flutter/models/knowledge_graph.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/screen_usage_daily.dart';
import 'package:qnote_flutter/models/todo.dart';

/// 规则抽取器版本。规则/词典发生不兼容变化时 +1，强制重跑全部源文档。
const int kKgExtractorVersion = 1;

/// 一次手动更新的统计，供设置页与统计卡片展示。
class KgIndexReport {
  final int scanned;
  final int updated;
  final int failed;
  final int removed;
  final int semanticUpdated;
  final int semanticPending;
  final bool semanticDeclined;
  final bool semanticUnavailable;
  final bool semanticQuotaExhausted;
  final bool fullScanCompleted;
  final bool hasMore;
  final bool cancelled;
  final String? error;

  const KgIndexReport({
    this.scanned = 0,
    this.updated = 0,
    this.failed = 0,
    this.removed = 0,
    this.semanticUpdated = 0,
    this.semanticPending = 0,
    this.semanticDeclined = false,
    this.semanticUnavailable = false,
    this.semanticQuotaExhausted = false,
    this.fullScanCompleted = false,
    this.hasMore = false,
    this.cancelled = false,
    this.error,
  });

  bool get hasChanges => updated > 0 || failed > 0 || removed > 0 || semanticUpdated > 0;
}

/// 手动更新的阶段，设置页据此显示进度文案。
enum KgRunPhase { collecting, rules, semantic, topics, insights }

/// 一次更新的实时进度；null 表示当前没有任务在跑。
class KgRunProgress {
  final KgRunPhase phase;
  final int done;
  final int? total;
  final String message;

  const KgRunProgress({required this.phase, required this.message, this.done = 0, this.total});

  /// total 未知时返回 null，让进度条显示为不确定状态
  double? get fraction {
    final value = total;
    if (value == null || value <= 0) return null;
    return (done / value).clamp(0.0, 1.0);
  }

  KgRunProgress copyWith({String? message, int? done, int? total}) {
    return KgRunProgress(
      phase: phase,
      message: message ?? this.message,
      done: done ?? this.done,
      total: total ?? this.total,
    );
  }
}

/// 语义分析计划：在真正调用模型前展示篇数、字数和今日额度，供用户确认。
class KgSemanticPlan {
  final int documents;
  final int characters;
  final int dailyUsed;
  final int dailyLimit;

  const KgSemanticPlan({
    required this.documents,
    required this.characters,
    required this.dailyUsed,
    required this.dailyLimit,
  });
}

/// 图谱新鲜度：设置页与 graph 工具用它提示「数据截至什么时候、有多少条待整理」。
class KgFreshness {
  final DateTime? lastScan;
  final int pendingRuleCount;
  final bool hasSourceData;

  const KgFreshness({this.lastScan, this.pendingRuleCount = 0, this.hasSourceData = false});
}

/// 知识图谱增量索引器。
///
/// 数据源：时间线、笔记、每日日记、待办、健康日指标、屏幕时长、长期记忆。
/// 触发：只由用户显式调用 [run]；不注册定时器、不在启动/回前台/提取后自动运行。
/// 增量：`updated_at` 拉候选 + 内容 hash 二次判定；没变直接跳过。
/// 成本：规则抽取零 LLM；语义抽取只处理笔记/日记，调用前由 UI 弹确认并受每日上限约束。
class KnowledgeGraphIndexer {
  static final KnowledgeGraphIndexer instance = KnowledgeGraphIndexer._internal();
  KnowledgeGraphIndexer._internal();

  final KnowledgeGraphRepository _repo = KnowledgeGraphRepository();
  final DiaryRepository _diaryRepo = DiaryRepository();
  final NoteRepository _noteRepo = NoteRepository();
  final TodoRepository _todoRepo = TodoRepository();
  final FolderRepository _folderRepo = FolderRepository();
  final HealthMetricRepository _healthRepo = HealthMetricRepository(DatabaseHelper.instance);
  final ScreenUsageDailyRepository _screenRepo = ScreenUsageDailyRepository(DatabaseHelper.instance);
  final ConfigRepository _configRepo = ConfigRepository.instance;
  final KgExtractor _extractor = KgExtractor();
  final KgLlmExtractor _llmExtractor = KgLlmExtractor();

  final StreamController<void> _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;

  /// 当前更新进度；null 表示没有正在进行的任务。
  /// 设置页与统计卡片通过它展示阶段、计数和停止按钮。
  final ValueNotifier<KgRunProgress?> progress = ValueNotifier<KgRunProgress?>(null);

  bool _running = false;
  bool _cancelRequested = false;
  bool _semanticDeclined = false;
  bool _semanticUnavailable = false;
  bool _semanticQuotaExhausted = false;

  /// 单批最多处理的「有变化」文档数；超过后在同一个任务内继续下一批
  static const int _maxDocsPerRun = 400;

  /// 语义抽取单次字符预算，避免一次更新把额度与上下文打满
  static const int _semanticCharBudget = 60000;

  bool get isRunning => _running;

  KgIndexReport _lastReport = const KgIndexReport();

  /// 请求停止当前更新。只在文档/篇目边界生效，已发出的模型请求会等它返回。
  void cancel() {
    if (!_running || _cancelRequested) return;
    _cancelRequested = true;
    final current = progress.value;
    if (current != null) {
      progress.value = current.copyWith(message: '正在停止…');
    }
  }

  /// 用户显式触发的增量更新。
  ///
  /// 不启动任何定时器；只有设置页/统计卡片点击后才会运行。`semantic` 为 true 时，
  /// 规则整理完成后先调用 [confirmSemantic] 征得确认，再消耗用户自己的
  /// 「时间线提取模型」额度。`clearFirst` 为 true 时先清空派生图（供「全部重建」使用）。
  /// 单批 400 条上限只在任务内部循环，不会让用户重复点。
  Future<KgIndexReport> run({
    bool semantic = false,
    bool forceFull = false,
    bool clearFirst = false,
    Future<bool> Function(KgSemanticPlan plan)? confirmSemantic,
  }) async {
    if (_running) return _lastReport;

    // 先同步占住运行位，再做异步配置读取：否则连点会让两个任务同时通过
    // `_running` 检查，造成重复索引与进度互相覆盖。
    _running = true;
    _cancelRequested = false;
    _semanticDeclined = false;
    _semanticUnavailable = false;
    _semanticQuotaExhausted = false;

    bool enabled;
    try {
      enabled = await KgConfig.isEnabled();
    } catch (_) {
      _running = false;
      rethrow;
    }
    if (!enabled) {
      _running = false;
      return const KgIndexReport();
    }

    final startedAt = DateTime.now();
    var scanned = 0;
    var updated = 0;
    var failed = 0;
    var removed = 0;
    var semanticUpdated = 0;
    var semanticPending = 0;
    var hasMore = false;
    var cancelled = false;
    var fullScanCompleted = false;
    String? error;

    _setProgress(KgRunPhase.collecting, '正在收集记录…');

    try {
      if (clearFirst) {
        await _repo.clearAll();
      }
      final full = forceFull || await _isFullScanDue();
      final lastScan = await _repo.getMetaDate('last_scan_at');
      final since = lastScan ?? DateTime(1970);
      final semanticCandidates = <KgSourceDocument>[];
      var pass = 0;

      while (true) {
        if (_cancelRequested) {
          cancelled = true;
          break;
        }
        pass++;
        final result = await _runRulePass(full: full, since: since, pass: pass);
        scanned += result.scanned;
        updated += result.updated;
        failed += result.failed;
        semanticCandidates.addAll(result.semanticCandidates);
        hasMore = result.hasMore;
        cancelled = result.cancelled;
        if (cancelled || !hasMore) break;
        // 还有积压：同一任务内继续，进度用累计条数展示
        _setProgress(KgRunPhase.rules, '已整理 ${updated + failed} 条，继续…', done: updated + failed);
      }

      if (!cancelled) {
        fullScanCompleted = full && !hasMore;
        await _repo.setMeta('last_scan_at', startedAt.toIso8601String());
        if (fullScanCompleted) {
          await _repo.setMeta('last_full_scan_at', startedAt.toIso8601String());
        }

        // 多批扫描可能重复收集同一篇，按来源去重后再确认是否真的需要语义分析
        final unique = <String, KgSourceDocument>{};
        for (final doc in semanticCandidates) {
          unique['${doc.sourceType}|${doc.sourceId}'] = doc;
        }
        final stillNeeded = <KgSourceDocument>[];
        for (final doc in unique.values) {
          if (_isSemanticDocument(doc) && await _needsSemantic(doc, _documentHash(doc))) {
            stillNeeded.add(doc);
          }
        }
        semanticPending = stillNeeded.length;

        if (semantic && stillNeeded.isNotEmpty) {
          semanticUpdated = await _maybeRunSemantic(stillNeeded, confirmSemantic);
          if (_cancelRequested) cancelled = true;
        }

        // 手动更新时每次都对账：用户删掉源记录后，下次点击就应该从图谱里消失。
        // 先清理再刷新统计，避免已删除记录的提及继续算进 mention_count/importance。
        removed = await _reconcile();
        await _repo.refreshNodeStats();
        if (!cancelled && !_cancelRequested) {
          _setProgress(KgRunPhase.topics, '正在计算主题…');
          await _refreshCommunities();
          if (!_cancelRequested) {
            _setProgress(KgRunPhase.insights, '正在更新关联发现…');
            await _refreshInsights();
          }
        }
        if (_cancelRequested) cancelled = true;
      } else {
        // 停止时保留已完成的规则贡献，只刷新节点统计
        await _repo.refreshNodeStats();
      }
    } catch (e, stackTrace) {
      error = e.toString();
      LoggerService.instance.logDatabase('知识图谱更新失败: $e', level: LogLevel.warning, details: stackTrace.toString());
    } finally {
      _running = false;
      _cancelRequested = false;
      _lastReport = KgIndexReport(
        scanned: scanned,
        updated: updated,
        failed: failed,
        removed: removed,
        semanticUpdated: semanticUpdated,
        semanticPending: semanticPending,
        semanticDeclined: _semanticDeclined,
        semanticUnavailable: _semanticUnavailable,
        semanticQuotaExhausted: _semanticQuotaExhausted,
        fullScanCompleted: fullScanCompleted,
        hasMore: hasMore,
        cancelled: cancelled,
        error: error,
      );
      progress.value = null;
      // 即使没有新增也通知一次：设置页的「最近更新」与卡片空态需要刷新
      _changes.add(null);
      LoggerService.instance.logDatabase(
        '知识图谱更新完成：扫描 $scanned 条，更新 $updated 条，语义补充 $semanticUpdated 条，失败 $failed 条'
        '${fullScanCompleted ? '（全量完成）' : ''}${cancelled ? '（已停止）' : ''}',
      );
    }
    return _lastReport;
  }

  /// 单批规则整理。返回 hasMore 时由 [run] 在同一任务内继续下一批。
  Future<_KgRulePassResult> _runRulePass({required bool full, required DateTime since, required int pass}) async {
    final docs = await _collectDocuments(full: full, since: since);
    final semanticEnabled = await KgConfig.isSemanticEnabled();
    final semanticCandidates = <KgSourceDocument>[];
    var processed = 0;
    var updated = 0;
    var failed = 0;
    var hitCap = false;
    var cancelled = false;

    _setProgress(KgRunPhase.rules, pass == 1 ? '正在整理记录…' : '继续整理记录…', done: 0, total: docs.length);

    for (final doc in docs) {
      if (_cancelRequested) {
        cancelled = true;
        break;
      }
      processed++;
      final hash = _documentHash(doc);
      final existing = await _repo.getDocument(doc.sourceType, doc.sourceId);
      final ruleChanged = existing == null || existing.status != 'ok' || existing.contentHash != hash;
      final semanticNeeded = semanticEnabled && _isSemanticDocument(doc) && await _needsSemantic(doc, hash);

      var ruleOk = true;
      if (ruleChanged) {
        if (updated + failed >= _maxDocsPerRun) {
          hitCap = true;
          break;
        }
        if (existing != null &&
            existing.status == 'failed' &&
            existing.retryCount >= 3 &&
            existing.contentHash == hash) {
          // 同一内容连续失败 3 次后不再每批重试；内容变化或 extractor 版本升级会重新尝试
          _emitRuleProgress(processed, docs.length);
          continue;
        }
        ruleOk = await _indexDocument(doc, hash, existing);
        if (ruleOk) {
          updated++;
        } else {
          failed++;
        }
        if ((updated + failed) % 10 == 0) {
          // 让出事件循环，避免一次性处理 400 条卡住首帧/动画
          await Future<void>.delayed(Duration.zero);
        }
      }
      // 规则建图失败的文档不进入语义队列：源节点/日期锚点可能还没写成功
      if (semanticNeeded && ruleOk) semanticCandidates.add(doc);
      _emitRuleProgress(processed, docs.length);
    }

    return _KgRulePassResult(
      scanned: docs.length,
      updated: updated,
      failed: failed,
      semanticCandidates: semanticCandidates,
      hasMore: hitCap,
      cancelled: cancelled,
    );
  }

  void _emitRuleProgress(int processed, int total) {
    // 每 10 条刷新一次即可：ValueNotifier 同步通知，太频繁会拖慢规则抽取
    if (processed % 10 != 0 && processed != total) return;
    _setProgress(KgRunPhase.rules, '正在整理记录 $processed/$total…', done: processed, total: total);
  }

  void _setProgress(KgRunPhase phase, String message, {int done = 0, int? total}) {
    // 用户已点停止时保留「正在停止…」，不再被后续阶段的常规进度覆盖
    if (!_running || _cancelRequested) return;
    progress.value = KgRunProgress(phase: phase, message: message, done: done, total: total);
  }

  Future<bool> _indexDocument(KgSourceDocument doc, String hash, KgDocument? existing) async {
    try {
      // 先清旧贡献，再整体重建：记录被编辑后，旧标签/旧关系不能残留
      await _repo.deleteSourceData(doc.sourceType, doc.sourceId);
      final result = await _extractor.extract(doc);
      await _repo.upsertNodes(result.nodes);
      await _repo.upsertMentions(result.mentions);
      await _repo.upsertEdges(result.edges);
      await _repo.upsertDocument(
        KgDocument(
          sourceType: doc.sourceType,
          sourceId: doc.sourceId,
          contentHash: hash,
          extractorVersion: kKgExtractorVersion,
          status: 'ok',
          retryCount: 0,
          indexedAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      return true;
    } catch (e, stackTrace) {
      LoggerService.instance.logDatabase(
        '知识图谱索引单条失败 ${doc.sourceType}/${doc.sourceId}: $e',
        level: LogLevel.warning,
        details: stackTrace.toString(),
      );
      await _repo.upsertDocument(
        KgDocument(
          sourceType: doc.sourceType,
          sourceId: doc.sourceId,
          contentHash: hash,
          extractorVersion: kKgExtractorVersion,
          status: 'failed',
          retryCount: (existing?.retryCount ?? 0) + 1,
          error: e.toString(),
          indexedAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      return false;
    }
  }

  Future<bool> _isFullScanDue() async {
    final last = await _repo.getMetaDate('last_full_scan_at');
    if (last == null) return true;
    return DateTime.now().difference(last) >= const Duration(hours: 24);
  }

  /// 对账并清理已删除源记录，返回清理条数。
  ///
  /// 之前按 24 小时节流是为后台轮询设计的；现在每次手动更新都执行，
  /// 保证用户删掉记录后，下一次点击更新就能从图谱与关联发现里消失。
  Future<int> _reconcile() async {
    try {
      var removed = 0;
      final noteIds = await _noteRepo.getAllIds();
      // 日记与普通笔记共用 notes 表：按 ID 前缀分类，避免笔记改标题后
      // sourceType 在 note/journal 之间切换时两边都留着旧数据
      final journalIds = noteIds.where(JournalService.isJournalNote).toSet();
      final regularNoteIds = noteIds.difference(journalIds);
      removed += await _reconcileType(KgSourceType.timeline, await _diaryRepo.getAllIds());
      removed += await _reconcileType(KgSourceType.note, regularNoteIds);
      removed += await _reconcileType(KgSourceType.journal, journalIds);
      removed += await _reconcileType(KgSourceType.todo, await _todoRepo.getAllIds());

      final healthDocs = await _repo.getDocumentsBySourceType(KgSourceType.health);
      final healthDates = (await _healthRepo.getRecentDailyMetrics(limit: 400)).map((m) => m.date).toSet();
      for (final doc in healthDocs) {
        if (!healthDates.contains(doc.sourceId)) {
          await _repo.deleteSourceData(doc.sourceType, doc.sourceId);
          removed++;
        }
      }

      // 长期记忆被清空后，也要把 /memory/user.md 对应的图谱贡献移除
      final memory = await _configRepo.getAgentMemory('user');
      if (memory.content.trim().isEmpty && await _repo.getDocument(KgSourceType.memory, 'user') != null) {
        await _repo.deleteSourceData(KgSourceType.memory, 'user');
        removed++;
      }
      await _repo.setMeta('last_reconcile_at', DateTime.now().toIso8601String());
      return removed;
    } catch (e, stackTrace) {
      LoggerService.instance.logDatabase('知识图谱对账失败: $e', level: LogLevel.warning, details: stackTrace.toString());
      return 0;
    }
  }

  bool _isSemanticDocument(KgSourceDocument doc) {
    if (doc.sourceType != KgSourceType.note && doc.sourceType != KgSourceType.journal) return false;
    return doc.body.trim().length >= 80;
  }

  /// 该文档是否需要跑语义抽取：内容 hash 变了，或上次没跑成功且今天还没试过
  Future<bool> _needsSemantic(KgSourceDocument doc, String hash) async {
    final key = '${doc.sourceType}:${doc.sourceId}';
    final done = await _repo.getMeta('semantic_ok:$key');
    if (done == hash) return false;
    final attempted = await _repo.getMeta('semantic_attempt:$key');
    return attempted != kgDateKey(DateTime.now());
  }

  /// 语义分析入口：先算出篇数/字数/今日额度，交给 UI 确认后再真正调用模型。
  Future<int> _maybeRunSemantic(
    List<KgSourceDocument> candidates,
    Future<bool> Function(KgSemanticPlan plan)? confirmSemantic,
  ) async {
    if (!await KgConfig.isSemanticEnabled()) return 0;
    if (!await AiRoleService.instance.hasUsableConfigForRole('timelineOptimization')) {
      _semanticUnavailable = true;
      LoggerService.instance.logAI('未配置「时间线提取模型」，跳过知识图谱语义分析');
      return 0;
    }

    final usage = await _semanticUsage();
    final plan = _buildSemanticPlan(candidates, usage);
    if (plan.documents == 0) {
      if (plan.dailyUsed >= plan.dailyLimit) _semanticQuotaExhausted = true;
      return 0;
    }

    // 没有确认回调就不允许静默消耗模型额度；UI 必须显式把计划交给用户确认
    if (confirmSemantic == null) {
      _semanticDeclined = true;
      return 0;
    }

    _setProgress(KgRunPhase.semantic, '等待确认深度分析…', done: 0, total: plan.documents);
    var approved = false;
    try {
      approved = await confirmSemantic(plan);
    } catch (e) {
      LoggerService.instance.logAI('语义分析确认失败: $e', level: LogLevel.warning);
    }
    if (!approved) {
      _semanticDeclined = true;
      return 0;
    }

    _setProgress(KgRunPhase.semantic, '正在深度分析笔记…', done: 0, total: plan.documents);
    return _runSemanticQueue(candidates, plan: plan);
  }

  Future<({int docsUsed, int charsUsed, int limit})> _semanticUsage() async {
    final today = kgDateKey(DateTime.now());
    var docsUsed = int.tryParse(await _repo.getMeta('llm_usage_docs') ?? '') ?? 0;
    var charsUsed = int.tryParse(await _repo.getMeta('llm_usage_chars') ?? '') ?? 0;
    if (await _repo.getMeta('llm_usage_date') != today) {
      docsUsed = 0;
      charsUsed = 0;
      await _repo.setMeta('llm_usage_date', today);
    }
    return (docsUsed: docsUsed, charsUsed: charsUsed, limit: await KgConfig.dailyDocLimit());
  }

  KgSemanticPlan _buildSemanticPlan(
    List<KgSourceDocument> candidates,
    ({int docsUsed, int charsUsed, int limit}) usage,
  ) {
    final remaining = (usage.limit - usage.docsUsed).clamp(0, usage.limit).toInt();
    var count = 0;
    var chars = 0;
    for (final doc in candidates) {
      if (count >= remaining) break;
      // 至少处理第一篇超长文档，避免单篇超过字符预算时永远轮不到
      if (count > 0 && chars + doc.body.length > _semanticCharBudget) break;
      count++;
      chars += doc.body.length;
    }
    return KgSemanticPlan(documents: count, characters: chars, dailyUsed: usage.docsUsed, dailyLimit: usage.limit);
  }

  /// 语义队列：只处理笔记/日记，单并发、受每日额度与字符预算约束，可在篇目边界停止。
  ///
  /// 先完成规则建图再跑语义，保证即使模型很慢/没配置，Agent 也能先查到
  /// 结构化关系；失败只记录尝试日期，不阻塞规则索引。
  Future<int> _runSemanticQueue(List<KgSourceDocument> candidates, {required KgSemanticPlan plan}) async {
    final today = kgDateKey(DateTime.now());
    final usage = await _semanticUsage();
    var docsUsed = usage.docsUsed;
    var charsUsed = usage.charsUsed;
    var attempted = 0;
    var updated = 0;

    for (final doc in candidates) {
      if (_cancelRequested) break;
      // 至少处理第一篇超长文档，避免单篇超过字符预算时永远轮不到
      if (docsUsed >= usage.limit || (docsUsed > 0 && charsUsed + doc.body.length > _semanticCharBudget)) break;

      attempted++;
      _setProgress(
        KgRunPhase.semantic,
        '正在分析 ${doc.title}（$attempted/${plan.documents}）…',
        done: attempted - 1,
        total: plan.documents,
      );

      final hash = _documentHash(doc);
      final key = '${doc.sourceType}:${doc.sourceId}';
      KgSemanticResult? result;
      try {
        result = await _llmExtractor.extract(doc);
      } catch (e, stackTrace) {
        LoggerService.instance.logAI(
          '知识图谱语义抽取异常 ${doc.sourceType}/${doc.sourceId}: $e',
          level: LogLevel.warning,
          details: stackTrace.toString(),
        );
        result = null;
      }

      if (result == null) {
        // 今天不再重试；内容变化或明天再试，避免失败时反复烧额度
        await _repo.setMeta('semantic_attempt:$key', today);
        _setProgress(KgRunPhase.semantic, '已分析 $attempted/${plan.documents} 篇', done: attempted, total: plan.documents);
        continue;
      }

      await _mergeSemanticResult(doc, result);
      await _repo.setMeta('semantic_ok:$key', hash);
      await _repo.setMeta('semantic_attempt:$key', today);
      docsUsed++;
      charsUsed += doc.body.length;
      await _repo.setMeta('llm_usage_docs', '$docsUsed');
      await _repo.setMeta('llm_usage_chars', '$charsUsed');
      updated++;
      _setProgress(KgRunPhase.semantic, '已分析 $attempted/${plan.documents} 篇', done: attempted, total: plan.documents);
      if (attempted % 2 == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }

    if (attempted > 0) {
      await _repo.setMeta('last_semantic_at', DateTime.now().toIso8601String());
    }
    if (updated > 0) {
      LoggerService.instance.logAI('知识图谱语义抽取完成：$updated 篇');
    }
    return updated;
  }

  /// 合并语义结果：规则已提及的节点不重复写提及，避免 mention_count 被放大
  Future<void> _mergeSemanticResult(KgSourceDocument doc, KgSemanticResult result) async {
    if (result.nodes.isEmpty && result.edges.isEmpty && result.mentions.isEmpty) return;

    final nodes = <String, KgNode>{for (final node in result.nodes) node.id: node};
    if (result.summary.trim().isNotEmpty) {
      final sourceId = KgIds.source(doc.sourceType, doc.sourceId);
      final sourceNode = nodes[sourceId] ?? await _repo.getSourceNode(doc.sourceType, doc.sourceId);
      if (sourceNode != null) {
        nodes[sourceId] = sourceNode.copyWith(summary: result.summary.trim());
      }
    }

    final existingMentions = await _repo.getMentionsForSource(doc.sourceType, doc.sourceId);
    final mentioned = existingMentions.map((mention) => mention.nodeId).toSet();
    final newMentions = <KgMention>[];
    for (final mention in result.mentions) {
      // 同一实体可能出现在多个 chunk 里，只保留第一条，避免 mention_count 被放大
      if (mentioned.add(mention.nodeId)) newMentions.add(mention);
    }

    await _repo.upsertNodes(nodes.values.toList());
    await _repo.upsertMentions(newMentions);
    await _repo.upsertEdges(result.edges);
  }

  /// 主题社区重算：手动更新时直接重算，保证看到的是本次数据的结果。
  /// 之前按 24 小时节流是为 5 分钟轮询设计的；现在只有用户点击才会走到这里。
  Future<void> _refreshCommunities() async {
    try {
      await KnowledgeGraphCommunityService.instance.rebuild();
    } catch (e, stackTrace) {
      LoggerService.instance.logDatabase('主题社区重算失败: $e', level: LogLevel.warning, details: stackTrace.toString());
    }
  }

  /// 关联发现重算：同样跟随手动更新，不再用 12 小时节流拖延卡片刷新。
  Future<void> _refreshInsights() async {
    try {
      await KnowledgeGraphInsightService.instance.rebuild();
    } catch (e, stackTrace) {
      LoggerService.instance.logDatabase('关联发现重算失败: $e', level: LogLevel.warning, details: stackTrace.toString());
    }
  }

  Future<int> _reconcileType(String sourceType, Set<String> existingIds) async {
    final docs = await _repo.getDocumentsBySourceType(sourceType);
    var removed = 0;
    for (final doc in docs) {
      if (!existingIds.contains(doc.sourceId)) {
        await _repo.deleteSourceData(doc.sourceType, doc.sourceId);
        removed++;
      }
    }
    return removed;
  }

  // ==========================================
  // 数据源 → 统一文档
  // ==========================================

  Future<List<KgSourceDocument>> _collectDocuments({required bool full, required DateTime since}) async {
    final now = DateTime.now();
    final start = full ? now.subtract(const Duration(days: 365)) : since.subtract(const Duration(minutes: 5));

    final noteFolders = {for (final folder in await _folderRepo.getByType('note')) folder.id: folder.name};
    final todoFolders = {for (final folder in await _folderRepo.getByType('todo')) folder.id: folder.name};

    final notes = full ? await _noteRepo.getAll() : await _noteRepo.getUpdatedSince(start);
    final todos = full ? await _todoRepo.getAll() : await _todoRepo.getUpdatedSince(start);
    final timeline = full ? await _diaryRepo.getByDateRange(start, now) : await _diaryRepo.getUpdatedSince(start);
    final health = full
        ? await _healthRepo.getRecentDailyMetrics(limit: 400)
        : await _healthRepo.getUpdatedSince(start);
    final screens = full
        ? await _screenRepo.getRange(kgDateKey(start), kgDateKey(now))
        : await _screenRepo.getUpdatedSince(start);

    // 健康日需要当天心情/消费/运动，用于派生状态节点；增量时补拉近 30 天时间线
    final moodSource = full || health.isEmpty
        ? timeline
        : await _diaryRepo.getByDateRange(now.subtract(const Duration(days: 30)), now);
    final dailyContext = _buildDailyContext(moodSource);
    final screenByDate = {for (final screen in screens) screen.date: screen};

    final docs = <KgSourceDocument>[
      ...notes.map((note) => _noteDocument(note, noteFolders)),
      ...todos.map((todo) => _todoDocument(todo, todoFolders)),
      ...timeline.map(_timelineDocument),
      ...health.map((metrics) => _healthDocument(metrics, dailyContext, screenByDate)),
    ];

    final memory = await _configRepo.getAgentMemory('user');
    if (memory.content.trim().isNotEmpty) {
      docs.add(
        KgSourceDocument(
          sourceType: KgSourceType.memory,
          sourceId: 'user',
          title: '用户画像与习惯',
          body: memory.content,
          path: '/memory/user.md',
          metadata: {'updated_at': memory.updatedAt.toIso8601String()},
        ),
      );
    }

    return docs;
  }

  KgSourceDocument _timelineDocument(DiaryRecord record) {
    final effectiveDate = record.getEffectiveDate();
    final dateKey = kgDateKey(effectiveDate);
    return KgSourceDocument(
      sourceType: KgSourceType.timeline,
      sourceId: record.id,
      title: record.title.trim().isNotEmpty
          ? record.title.trim()
          : (record.displayTag.trim().isNotEmpty ? record.displayTag : '时间线记录'),
      body: record.content,
      analysis: record.aiAnalysis,
      occurredAt: DateTime(
        effectiveDate.year,
        effectiveDate.month,
        effectiveDate.day,
        record.time.hour,
        record.time.minute,
      ),
      path: '/timeline/$dateKey.md',
      tagEntries: [
        for (final entry in record.tagEntries) KgSourceTag(id: entry.id, name: entry.name, fields: entry.fields),
      ],
      labelTags: record.tags,
      mood: record.mood,
      metadata: {
        'display_tag': record.displayTag,
        'time': record.time.toIso8601String(),
        if (record.startTime != null) 'start_time': record.startTime!.toIso8601String(),
        if (record.endTime != null) 'end_time': record.endTime!.toIso8601String(),
        'mood': record.mood,
        'weather': record.weather,
        'has_photos': record.photos.isNotEmpty,
      },
    );
  }

  KgSourceDocument _noteDocument(Note note, Map<String, String> folders) {
    final isJournal = JournalService.isJournalNote(note.id);
    final title = note.title.trim().isEmpty ? '未命名笔记' : note.title.trim();
    final folderName = folders[note.folderId];
    final journalDate = isJournal ? DateTime.tryParse(title) : null;
    final path = isJournal
        ? '/journal/$title.md'
        : (folderName == null || folderName.isEmpty ? '/notes/$title.md' : '/notes/$folderName/$title.md');
    return KgSourceDocument(
      sourceType: isJournal ? KgSourceType.journal : KgSourceType.note,
      sourceId: note.id,
      title: title,
      body: note.content,
      occurredAt: journalDate ?? note.updatedAt,
      path: path,
      labelTags: _splitTags(note.tags),
      folderName: folderName,
      metadata: {'pinned': note.isPinned, 'updated_at': note.updatedAt.toIso8601String(), 'is_journal': isJournal},
    );
  }

  KgSourceDocument _todoDocument(Todo todo, Map<String, String> folders) {
    final title = todo.title.trim().isEmpty ? '未命名待办' : todo.title.trim();
    final folderName = folders[todo.folderId] ?? (todo.isLongTerm ? '长期' : '今日');
    return KgSourceDocument(
      sourceType: KgSourceType.todo,
      sourceId: todo.id,
      title: title,
      body: todo.description,
      occurredAt: todo.dueDate ?? todo.updatedAt,
      path: '/todos/$folderName/$title.md',
      labelTags: _splitTags(todo.tags),
      folderName: folderName,
      metadata: {
        'status': todo.isCompleted ? 'completed' : 'pending',
        'priority': todo.priority,
        'repeat_rule': todo.repeatRule,
        'is_long_term': todo.isLongTerm,
        if (todo.dueDate != null) 'due_date': todo.dueDate!.toIso8601String(),
      },
    );
  }

  KgSourceDocument _healthDocument(
    HealthDailyMetrics metrics,
    _KgDailyContext context,
    Map<String, ScreenUsageDaily> screens,
  ) {
    final date = DateTime.tryParse(metrics.date) ?? DateTime.now();
    final screen = screens[metrics.date];
    final mood = context.moodByDate[metrics.date];
    final spend = context.spendByDate[metrics.date];
    final metadata = <String, dynamic>{
      'steps': metrics.steps,
      'active_minutes': metrics.activeMinutes,
      'sleep_minutes': metrics.sleepDurationMinutes,
      'sleep_score': metrics.sleepScore,
      'has_exercise': context.exerciseDates.contains(metrics.date),
    };
    if (metrics.sleepStartTime != null) metadata['sleep_start_time'] = metrics.sleepStartTime;
    if (metrics.avgHeartRate != null) metadata['avg_heart_rate'] = metrics.avgHeartRate;
    if (metrics.avgStress != null) metadata['avg_stress'] = metrics.avgStress;
    if (screen != null) metadata['screen_time_ms'] = screen.totalTimeMs;
    if (mood != null) metadata['mood'] = mood;
    if (spend != null) metadata['spend'] = spend;
    metadata['spend_p75'] = context.spendP75;

    return KgSourceDocument(
      sourceType: KgSourceType.health,
      sourceId: metrics.date,
      title: metrics.date,
      occurredAt: date,
      path: '/health/${metrics.date}.json',
      mood: mood,
      metadata: metadata,
    );
  }

  _KgDailyContext _buildDailyContext(List<DiaryRecord> records) {
    final moodSum = <String, int>{};
    final moodCount = <String, int>{};
    final spend = <String, double>{};
    final exercise = <String>{};

    for (final record in records) {
      final date = kgDateKey(record.getEffectiveDate());
      moodSum[date] = (moodSum[date] ?? 0) + record.mood;
      moodCount[date] = (moodCount[date] ?? 0) + 1;

      for (final entry in record.tagEntries) {
        if (entry.id == 'consumption' || entry.name == '记账') {
          final amount = _toDouble(entry.fields['amount'] ?? entry.fields['金额']);
          final category = (entry.fields['_category'] ?? entry.fields['category'] ?? '').toString();
          if (amount != null && category != 'income') {
            spend[date] = (spend[date] ?? 0) + amount;
          }
        }
        if (entry.id == 'activity' || entry.name == '活动') {
          final type = (entry.fields['type'] ?? entry.fields['类型'] ?? '').toString();
          if (type.contains('运动')) exercise.add(date);
        }
      }
      if (KgDictionaries.matchText(
        '${record.title}\n${record.content}',
        limit: 8,
      ).any((hit) => hit.type == KgEntityType.sport)) {
        exercise.add(date);
      }
    }

    final moodByDate = <String, int>{
      for (final entry in moodSum.entries)
        if ((moodCount[entry.key] ?? 0) > 0) entry.key: (entry.value / moodCount[entry.key]!).round(),
    };
    final spendValues = spend.values.where((value) => value > 0).toList()..sort();
    final spendP75 = spendValues.isEmpty
        ? 0.0
        : spendValues[((spendValues.length - 1) * 0.75).floor().clamp(0, spendValues.length - 1)];
    return _KgDailyContext(moodByDate: moodByDate, spendByDate: spend, exerciseDates: exercise, spendP75: spendP75);
  }

  String _documentHash(KgSourceDocument doc) {
    return kgContentHash({
      'v': kKgExtractorVersion,
      'title': doc.title,
      'body': doc.body,
      'analysis': doc.analysis,
      'tags': [
        for (final tag in doc.tagEntries) {'id': tag.id, 'name': tag.name, 'fields': tag.fields},
      ],
      'label_tags': doc.labelTags,
      'folder': doc.folderName,
      'mood': doc.mood,
      'metadata': doc.metadata,
      'occurred_at': doc.occurredAt?.toIso8601String(),
    });
  }

  static List<String> _splitTags(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return const [];
    if (trimmed.startsWith('[')) {
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is List) {
          return decoded.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
        }
      } catch (_) {
        // 非 JSON 的旧格式按分隔符继续解析
      }
    }
    return trimmed.split(RegExp(r'[,，、;；]+')).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
  }

  static double? _toDouble(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().trim());
  }

  // ==========================================
  // 对外操作：重建 / 清空 / 状态
  // ==========================================

  /// 清空图谱并按全量重新索引。实体别名与洞察会一起清掉（第一版没有用户手工维护数据）。
  ///
  /// 默认只跑规则建图；需要语义分析时由调用方传 `semantic: true` 并提供确认回调，
  /// 避免「重建」按钮静默消耗模型额度。
  Future<KgIndexReport> rebuildAll({
    bool semantic = false,
    Future<bool> Function(KgSemanticPlan plan)? confirmSemantic,
  }) {
    // 清空与重建放进同一个运行位里完成，避免清空过程中另一处又启动索引
    return run(forceFull: true, clearFirst: true, semantic: semantic, confirmSemantic: confirmSemantic);
  }

  Future<void> clear() async {
    if (_running) return;
    _running = true;
    try {
      await _repo.clearAll();
      _changes.add(null);
    } finally {
      _running = false;
    }
  }

  /// 轻量新鲜度查询：给 graph 工具与空态卡片判断「要不要提示用户更新」。
  Future<KgFreshness> freshness() async {
    final lastScan = await _repo.getMetaDate('last_scan_at');
    return KgFreshness(
      lastScan: lastScan,
      pendingRuleCount: await _countPendingSince(lastScan),
      hasSourceData: await _hasSourceData(),
    );
  }

  /// 粗略统计上次索引后发生变化的源记录数。
  ///
  /// 只做 `updated_at` 比较，不做内容 hash，可能比实际待处理数略多；
  /// 用于界面提示「有 N 条新记录」，真正更新时仍以 hash 为准。
  Future<int> _countPendingSince(DateTime? since) async {
    if (since == null) return -1; // 尚未建立过图谱
    final db = await DatabaseHelper.instance.database;
    // 增量扫描自身会向前多取 5 分钟作为安全重叠；这里再减 5 分钟会把
    // 刚扫过的记录误报成待整理，所以直接用扫描开始时间比较。
    final threshold = since.toIso8601String();
    var count = 0;
    for (final sql in const [
      'SELECT COUNT(*) FROM diary_records WHERE is_deleted = 0 AND updated_at > ?',
      'SELECT COUNT(*) FROM notes WHERE is_deleted = 0 AND updated_at > ?',
      'SELECT COUNT(*) FROM todos WHERE is_deleted = 0 AND updated_at > ?',
      'SELECT COUNT(*) FROM health_daily_metrics WHERE updated_at > ?',
      'SELECT COUNT(*) FROM screen_usage_daily WHERE updated_at > ?',
    ]) {
      final rows = await db.rawQuery(sql, [threshold]);
      count += rows.isEmpty ? 0 : (rows.first.values.first as num?)?.toInt() ?? 0;
    }
    return count;
  }

  /// 是否有任何可建图的源数据；用于区分「新用户」和「已用但尚未建图」
  Future<bool> _hasSourceData() async {
    final db = await DatabaseHelper.instance.database;
    for (final sql in const [
      'SELECT 1 FROM diary_records WHERE is_deleted = 0 LIMIT 1',
      'SELECT 1 FROM notes WHERE is_deleted = 0 LIMIT 1',
      'SELECT 1 FROM todos WHERE is_deleted = 0 LIMIT 1',
      'SELECT 1 FROM health_daily_metrics LIMIT 1',
      'SELECT 1 FROM screen_usage_daily LIMIT 1',
    ]) {
      final rows = await db.rawQuery(sql);
      if (rows.isNotEmpty) return true;
    }
    return false;
  }

  Future<Map<String, dynamic>> status() async {
    final stats = await _repo.stats();
    final topEntities = await _repo.topEntities(limit: 12);
    final fresh = await freshness();
    final today = kgDateKey(DateTime.now());
    final usageDate = await _repo.getMeta('llm_usage_date');
    final docsToday = usageDate == today ? int.tryParse(await _repo.getMeta('llm_usage_docs') ?? '') ?? 0 : 0;
    return {
      ...stats,
      'running': _running,
      'enabled': await KgConfig.isEnabled(),
      'semantic_enabled': await KgConfig.isSemanticEnabled(),
      'pending_rule_count': fresh.pendingRuleCount,
      'has_source_data': fresh.hasSourceData,
      'last_semantic_at': await _repo.getMeta('last_semantic_at'),
      'semantic_docs_today': docsToday,
      'semantic_limit': await KgConfig.dailyDocLimit(),
      'top_entities': [
        for (final row in topEntities)
          {
            'id': row['id'],
            'name': row['name'],
            'type': row['type'],
            'mention_count': row['mention_count'],
            'importance': row['importance'],
            'community_id': row['community_id'],
          },
      ],
    };
  }
}

class _KgRulePassResult {
  final int scanned;
  final int updated;
  final int failed;
  final List<KgSourceDocument> semanticCandidates;
  final bool hasMore;
  final bool cancelled;

  const _KgRulePassResult({
    required this.scanned,
    required this.updated,
    required this.failed,
    required this.semanticCandidates,
    required this.hasMore,
    required this.cancelled,
  });
}

class _KgDailyContext {
  final Map<String, int> moodByDate;
  final Map<String, double> spendByDate;
  final Set<String> exerciseDates;

  /// 近段有消费记录的日支出 75 分位；用于派生「消费偏高」状态
  final double spendP75;

  const _KgDailyContext({
    required this.moodByDate,
    required this.spendByDate,
    required this.exerciseDates,
    required this.spendP75,
  });
}
