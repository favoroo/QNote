import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/ai/free_model_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/agent/agent_tool_registry.dart';
import 'package:qnote_flutter/core/agent/engine/agent_events.dart';
import 'package:qnote_flutter/core/agent/engine/agent_loop.dart';
import 'package:qnote_flutter/core/agent/prompts/q_system_prompt.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/journal_service.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/free_model_config.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:uuid/uuid.dart';

class AiContextFilter {
  final String scope;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<String> selectedNoteIds;
  final List<String> selectedTodoIds;
  final List<String> selectedTags;

  const AiContextFilter({
    this.scope = 'all',
    this.startDate,
    this.endDate,
    this.selectedNoteIds = const [],
    this.selectedTodoIds = const [],
    this.selectedTags = const [],
  });

  AiContextFilter copyWith({
    String? scope,
    DateTime? startDate,
    DateTime? endDate,
    List<String>? selectedNoteIds,
    List<String>? selectedTodoIds,
    List<String>? selectedTags,
  }) {
    return AiContextFilter(
      scope: scope ?? this.scope,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      selectedNoteIds: selectedNoteIds ?? this.selectedNoteIds,
      selectedTodoIds: selectedTodoIds ?? this.selectedTodoIds,
      selectedTags: selectedTags ?? this.selectedTags,
    );
  }
}

final aiServiceProvider = Provider<AiService>((ref) {
  return AiService();
});

final aiRolesProvider = FutureProvider<AiRoles?>((ref) async {
  final repo = ConfigRepository.instance;
  return repo.getAiRoles();
});

final aiTemperaturesProvider = FutureProvider<AiTemperatures?>((ref) async {
  final repo = ConfigRepository.instance;
  return repo.getAiTemperatures();
});

// 免费模型相关 Provider
final freeModelsProvider =
    FutureProvider<List<FreeModelConfig>>((ref) async {
  return FreeModelService.instance.getCachedModels();
});

final freeModelsManifestProvider =
    FutureProvider<FreeModelsManifest?>((ref) async {
  return FreeModelService.instance.getCachedManifest();
});

final freeModelsLastUpdateProvider = FutureProvider<DateTime?>((ref) async {
  return FreeModelService.instance.getLastUpdateTime();
});

// 用户选择的主模型ID
final selectedFreeModelProvider = StateProvider<String?>((ref) => null);

// 免费模型更新状态
final freeModelUpdatingProvider = StateProvider<bool>((ref) => false);

final contextFilterProvider = StateProvider<AiContextFilter>(
  (ref) => const AiContextFilter(),
);

final aiConfigListProvider =
    AsyncNotifierProvider<AiConfigListNotifier, List<AiConfig>>(() {
      return AiConfigListNotifier();
    });

class AiConfigListNotifier extends AsyncNotifier<List<AiConfig>> {
  @override
  Future<List<AiConfig>> build() async {
    final repo = ConfigRepository.instance;
    return repo.getAllAiConfigs();
  }

  Future<void> refresh() async {
    final repo = ConfigRepository.instance;
    state = AsyncData(await repo.getAllAiConfigs());
  }

  Future<AiConfig> addConfig(AiConfig config) async {
    final repo = ConfigRepository.instance;
    await repo.insertAiConfig(config);
    // 内存增量更新，避免全表重查
    state = AsyncData([...(state.valueOrNull ?? []), config]);
    return config;
  }

  Future<void> updateConfig(AiConfig config) async {
    final repo = ConfigRepository.instance;
    await repo.updateAiConfig(config);
    // 内存替换目标项
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((c) => c.id == config.id ? config : c)
          .toList(),
    );
  }

  Future<void> deleteConfig(String id) async {
    final repo = ConfigRepository.instance;
    await repo.deleteAiConfig(id);
    // 内存移除
    state = AsyncData(
      (state.valueOrNull ?? []).where((c) => c.id != id).toList(),
    );
  }
}

final defaultAiConfigProvider = FutureProvider<AiConfig?>((ref) async {
  final repo = ConfigRepository.instance;
  return repo.getDefaultAiConfig();
});

Future<void> saveAiRoles(AiRoles roles) async {
  final repo = ConfigRepository.instance;
  await repo.saveAiRoles(roles);
}

Future<void> saveAiTemperatures(AiTemperatures temps) async {
  final repo = ConfigRepository.instance;
  await repo.saveAiTemperatures(temps);
}

final chatSessionListProvider =
    AsyncNotifierProvider<ChatSessionListNotifier, List<ChatSession>>(() {
      return ChatSessionListNotifier();
    });

class ChatSessionListNotifier extends AsyncNotifier<List<ChatSession>> {
  @override
  Future<List<ChatSession>> build() async {
    final repo = ConfigRepository.instance;
    return repo.getAllChatSessions();
  }

  Future<void> refresh() async {
    final repo = ConfigRepository.instance;
    state = AsyncData(await repo.getAllChatSessions());
  }

  Future<ChatSession> createSession({String? aiConfigId}) async {
    final repo = ConfigRepository.instance;
    final now = DateTime.now();
    final greeting = defaultSystemPrompts['assistant_greeting'] ?? '';
    final session = ChatSession(
      id: const Uuid().v4(),
      title: '新对话',
      aiConfigId: aiConfigId,
      messages: greeting.isNotEmpty
          ? [ChatMessage(role: 'assistant', content: greeting, timestamp: now)]
          : const [],
      createdAt: now,
      updatedAt: now,
    );
    await repo.insertChatSession(session);
    // 内存增量更新，避免全表重查
    state = AsyncData([...(state.valueOrNull ?? []), session]);
    return session;
  }

  Future<void> updateSession(ChatSession session) async {
    final repo = ConfigRepository.instance;
    await repo.updateChatSession(session);
    // 内存替换目标项
    state = AsyncData(
      (state.valueOrNull ?? [])
          .map((s) => s.id == session.id ? session : s)
          .toList(),
    );
  }

  Future<void> deleteSession(String id) async {
    final repo = ConfigRepository.instance;
    await repo.softDeleteChatSession(id);
    // 内存移除
    state = AsyncData(
      (state.valueOrNull ?? []).where((s) => s.id != id).toList(),
    );
  }
}

final currentChatProvider =
    StateNotifierProvider<CurrentChatNotifier, ChatSession?>((ref) {
      return CurrentChatNotifier(ref);
    });

final aiStreamingMessageProvider = StateProvider<String?>((ref) => null);

class CurrentChatNotifier extends StateNotifier<ChatSession?> {
  final Ref _ref;

  CurrentChatNotifier(this._ref) : super(null);

  final StringBuffer _streamingContent = StringBuffer();
  bool _isStreaming = false;

  bool get isStreaming => _isStreaming;

  void setSession(ChatSession? session) {
    state = session;
  }

  Future<String> exportContext({
    List<String>? attachNoteIds,
    List<String>? attachTodoIds,
    List<String>? attachJournalIds,
  }) async {
    final filter = _ref.read(contextFilterProvider);
    final diaryRepo = DiaryRepository();
    final buffer = StringBuffer();

    if (filter.scope == 'none') return '';

    List<DiaryRecord> filteredDiary = [];
    List<DiaryRecord> records;
    if (filter.startDate != null && filter.endDate != null) {
      final start = DateTime(
        filter.startDate!.year,
        filter.startDate!.month,
        filter.startDate!.day,
      );
      final end = DateTime(
        filter.endDate!.year,
        filter.endDate!.month,
        filter.endDate!.day,
        23,
        59,
        59,
        999,
      );
      records = await diaryRepo.getByDateRange(start, end);
    } else {
      records = await diaryRepo.getAll();
    }

    if (filter.selectedTags.isNotEmpty) {
      filteredDiary = records.where((r) {
        return r.tags.any((t) => filter.selectedTags.contains(t));
      }).toList();
    } else {
      filteredDiary = records;
    }

    // 1. 自动获取日期范围内的每日长文日记（Journal Notes），并合并手动附加分享的日记
    final journalService = JournalService.instance;
    List<Note> rangeJournals = [];
    if (filter.startDate != null && filter.endDate != null) {
      rangeJournals = await journalService.getJournalsByDateRange(
        filter.startDate!,
        filter.endDate!,
      );
    } else {
      rangeJournals = await journalService.getAllJournals();
    }

    final allJournalNotes = <Note>[...rangeJournals];
    if (attachJournalIds != null && attachJournalIds.isNotEmpty) {
      final noteRepo = NoteRepository();
      for (final jId in attachJournalIds) {
        if (!allJournalNotes.any((n) => n.id == jId)) {
          final jNote = await noteRepo.getById(jId);
          if (jNote != null && !jNote.isDeleted && jNote.content.trim().isNotEmpty) {
            allJournalNotes.add(jNote);
          }
        }
      }
    }
    allJournalNotes.sort((a, b) => b.title.compareTo(a.title));

    // 2. 收集所有需要关联的普通笔记（排除日记，避免重复展示）
    final allNoteIds = <String>{
      if (filter.scope == 'notes' || filter.scope == 'mixed')
        ...filter.selectedNoteIds,
      if (attachNoteIds != null) ...attachNoteIds,
    };
    List<Note> filteredNotes = [];
    if (allNoteIds.isNotEmpty) {
      final noteRepo = NoteRepository();
      for (final id in allNoteIds) {
        if (JournalService.isJournalNote(id)) continue;
        final note = await noteRepo.getById(id);
        if (note != null && !note.isDeleted) {
          filteredNotes.add(note);
        }
      }
    }

    // 3. 收集所有需要关联的待办（包含上下文过滤与当次附加分享的待办）
    final allTodoIds = <String>{
      if (filter.scope == 'todos' || filter.scope == 'mixed')
        ...filter.selectedTodoIds,
      if (attachTodoIds != null) ...attachTodoIds,
    };
    List<Todo> filteredTodos = [];
    if (allTodoIds.isNotEmpty) {
      final todoRepo = TodoRepository();
      for (final id in allTodoIds) {
        final todo = await todoRepo.getById(id);
        if (todo != null && !todo.isDeleted) {
          filteredTodos.add(todo);
        }
      }
    }

    buffer.writeln('请基于以下数据回答我的问题：\n');

    // 拼接每日长篇日记
    if (allJournalNotes.isNotEmpty) {
      buffer.writeln('### 每日长篇日记\n');
      for (int i = 0; i < allJournalNotes.length; i++) {
        final j = allJournalNotes[i];
        buffer.writeln('#### 日记 ${i + 1} (${j.title})');
        if (j.tags.isNotEmpty) {
          buffer.writeln('- **标签**: ${j.tags}');
        }
        buffer.writeln('- **内容**:\n${j.content.trim()}\n');
      }
    }

    // 拼接时间线日记流水记录
    if (filteredDiary.isNotEmpty) {
      buffer.writeln('### 时间线流水记录\n');
      for (int i = 0; i < filteredDiary.length; i++) {
        final r = filteredDiary[i];
        buffer.writeln('#### 条目 ${i + 1}');
        buffer.writeln('- **时间**: ${_formatDateTime(r.time)}');
        if (r.startTime != null) {
          buffer.writeln('- **开始时间**: ${_formatDateTime(r.startTime!)}');
        }
        if (r.endTime != null) {
          buffer.writeln('- **结束时间**: ${_formatDateTime(r.endTime!)}');
        }
        if (r.weather.trim().isNotEmpty) {
          buffer.writeln('- **天气**: ${r.weather.trim()}');
        }
        if (r.mood > 0) {
          final stars = '⭐' * r.mood;
          buffer.writeln('- **心情**: $stars (${r.mood}分)');
        }
        if (r.displayTag.isNotEmpty) {
          buffer.writeln('- **类型**: ${r.displayTag}');
        }
        if (r.tags.isNotEmpty) {
          buffer.writeln('- **标签**: ${r.tags.join(', ')}');
        }
        if (r.bodyState != null && r.bodyState!.isNotEmpty) {
          final bs = r.bodyState!;
          final name = bs['name']?.toString() ?? '';
          final severity = bs['severity']?.toString() ?? '';
          final duration = bs['duration']?.toString() ?? '';
          final triggers = bs['triggers'] is List
              ? (bs['triggers'] as List).join('、')
              : (bs['triggers']?.toString() ?? '');
          final notes = bs['notes']?.toString() ?? '';

          String bsDesc = name;
          if (severity.isNotEmpty) bsDesc += ' (程度: $severity)';
          if (duration.isNotEmpty) bsDesc += ', 持续: $duration';
          if (triggers.isNotEmpty) bsDesc += ', 诱因: $triggers';
          if (notes.isNotEmpty) bsDesc += ', 备注: $notes';

          buffer.writeln('- **身体状态**: $bsDesc');
        }
        if (r.tagEntries.isNotEmpty) {
          for (final te in r.tagEntries) {
            if (te.fields.isNotEmpty) {
              final fieldParts = te.fields.entries
                  .where((e) => e.value != null && e.value.toString().isNotEmpty)
                  .map((e) => '${e.key}: ${e.value}')
                  .join(', ');
              if (fieldParts.isNotEmpty) {
                buffer.writeln('- **${te.name}**: $fieldParts');
              }
            }
          }
        }
        if (r.content.isNotEmpty) {
          buffer.writeln('- **内容**: ${r.content}');
        }
        buffer.writeln();
      }
    }

    if (filteredNotes.isNotEmpty) {
      buffer.writeln('### 相关笔记\n');
      for (int i = 0; i < filteredNotes.length; i++) {
        final n = filteredNotes[i];
        buffer.writeln('#### 条目 ${i + 1}');
        buffer.writeln('- **标题**: ${n.title}');
        if (n.tags.isNotEmpty) {
          buffer.writeln('- **标签**: ${n.tags}');
        }
        if (n.content.isNotEmpty) {
          buffer.writeln('- **内容**: ${n.content}');
        }
        buffer.writeln();
      }
    }

    if (filteredTodos.isNotEmpty) {
      buffer.writeln('### 相关待办\n');
      for (int i = 0; i < filteredTodos.length; i++) {
        final t = filteredTodos[i];
        buffer.writeln('#### 待办 ${i + 1}');
        buffer.writeln('- **内容**: ${t.title}');
        if (t.description.isNotEmpty) buffer.writeln('- **描述**: ${t.description}');
        buffer.writeln('- **状态**: ${t.isCompleted ? '已完成' : '未完成'}');
        buffer.writeln('- **优先级**: ${t.priority == 'high' ? '高' : (t.priority == 'important' ? '重要' : '普通')}');
        if (t.dueDate != null) buffer.writeln('- **到期日**: ${_formatDateTime(t.dueDate!)}');
        if (t.tags.isNotEmpty) buffer.writeln('- **标签**: ${t.tags}');
        buffer.writeln();
      }
    }

    final configRepo = ConfigRepository.instance;
    final userProfile = await configRepo.getUserProfile();
    if (userProfile != null &&
        ((userProfile.nickname != null && userProfile.nickname!.isNotEmpty) ||
            (userProfile.birthday != null &&
                userProfile.birthday!.isNotEmpty) ||
            userProfile.height != null ||
            userProfile.weightHistory.isNotEmpty ||
            (userProfile.otherInfo != null &&
                userProfile.otherInfo!.isNotEmpty) ||
            userProfile.customFields.values.any((v) => v.isNotEmpty))) {
      buffer.writeln('### 个人背景信息\n');
      if (userProfile.nickname != null && userProfile.nickname!.isNotEmpty) {
        buffer.writeln('- **昵称**: ${userProfile.nickname}');
      }
      if (userProfile.birthday != null && userProfile.birthday!.isNotEmpty) {
        buffer.writeln('- **生日**: ${userProfile.birthday}');
      }
      if (userProfile.height != null) {
        buffer.writeln('- **身高**: ${userProfile.height}cm');
      }
      if (userProfile.gender != null && userProfile.gender!.isNotEmpty) {
        String genderLabel = userProfile.gender!;
        if (genderLabel == 'male') {
          genderLabel = '男';
        } else if (genderLabel == 'female')
          genderLabel = '女';
        else if (genderLabel == 'other')
          genderLabel = '保密';
        buffer.writeln('- **性别**: $genderLabel');
      }
      if (userProfile.weightHistory.isNotEmpty) {
        buffer.writeln('- **体重记录**:');
        for (final w in userProfile.weightHistory) {
          buffer.writeln('  - ${_formatDateTime(w.time)}: ${w.weight}kg');
        }
      }
      if (userProfile.otherInfo != null && userProfile.otherInfo!.isNotEmpty) {
        buffer.writeln('- **其他信息**: ${userProfile.otherInfo}');
      }
      userProfile.customFields.forEach((key, value) {
        if (value.isNotEmpty) {
          buffer.writeln('- **$key**: $value');
        }
      });
      buffer.writeln();
    }

    return buffer.toString().trim();
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }

  Future<void> sendMessage(
    String content, {
    List<String>? images,
    List<String>? noteIds,
    List<String>? todoIds,
    List<String>? journalIds,
  }) async {
    if (state == null) return;

    final now = DateTime.now();
    final repo = ConfigRepository.instance;

    // 1. Append user message with raw content and optional images to active display/save history immediately
    final userMessage = ChatMessage(
      role: 'user',
      content: content,
      timestamp: now,
      images: images,
    );
    final updatedMessages = [...state!.messages, userMessage];

    // Determine the updated session title if it is default
    String newTitle = state!.title;
    if (state!.title == '新对话' ||
        state!.messages.isEmpty ||
        (state!.messages.length == 1 &&
            state!.messages.first.role == 'assistant')) {
      newTitle = content.substring(
        0,
        content.length > 20 ? 20 : content.length,
      );
    }

    state = state!.copyWith(title: newTitle, messages: updatedMessages);

    _isStreaming = true;
    _streamingContent.clear();

    try {
      // 2. Prepare Time Context (in Chinese format, e.g., "2026/05/17 星期日 09:31")
      const weekdays = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六'];
      final weekdayStr = weekdays[now.weekday % 7];
      final dateStr = DateFormat('yyyy/MM/dd').format(now);
      final timeStr = DateFormat('HH:mm').format(now);
      final timeContext = '$dateStr $weekdayStr $timeStr';

      // 3. Prepare User Info (enriched with calculated age and latest weight)
      final userProfile = await repo.getUserProfile();
      String? userInfo;
      if (userProfile != null &&
          ((userProfile.name != null && userProfile.name!.isNotEmpty) ||
              (userProfile.nickname != null &&
                  userProfile.nickname!.isNotEmpty) ||
              (userProfile.birthday != null &&
                  userProfile.birthday!.isNotEmpty))) {
        final Map<String, dynamic> enrichedProfile = {
          'id': userProfile.id,
          'name': userProfile.name,
          'nickname': userProfile.nickname,
          'birthday': userProfile.birthday,
          'height': userProfile.height,
          'gender': userProfile.gender,
          'otherInfo': userProfile.otherInfo,
          'customFields': userProfile.customFields,
        };

        if (userProfile.birthday != null && userProfile.birthday!.isNotEmpty) {
          try {
            final birthDate = DateTime.parse(userProfile.birthday!);
            enrichedProfile['age'] = now.year - birthDate.year;
          } catch (_) {}
        }

        if (userProfile.weightHistory.isNotEmpty) {
          final sortedWeights = [...userProfile.weightHistory]
            ..sort((a, b) => b.time.compareTo(a.time));
          enrichedProfile['latestWeight'] = sortedWeights.first.weight;
        }

        userInfo = const JsonEncoder.withIndent('  ').convert(enrichedProfile);
      }

      // 4. Prepare Data Context
      final filter = _ref.read(contextFilterProvider);
      String? dataContext;
      if (filter.scope != 'none') {
        final context = await exportContext(
          attachNoteIds: noteIds,
          attachTodoIds: todoIds,
          attachJournalIds: journalIds,
        );
        if (context.isNotEmpty) {
          dataContext = context.trim();
        }
      }

      // 5. Construct userContent for LLM (following the legacy structure exactly)
      String userContent = '';
      if (timeContext.isNotEmpty) {
        userContent += '==== [系统时间] ====\n$timeContext\n\n';
      }
      if (userInfo != null && userInfo.isNotEmpty) {
        userContent += '==== [用户信息] ====\n$userInfo\n\n';
      }
      if (dataContext != null && dataContext.isNotEmpty) {
        userContent += '==== [上下文数据] ====\n$dataContext\n\n';
      }
      userContent += '==== [用户指令] ====\n$content';

      final aiService = _ref.read(aiServiceProvider);
      final useFreeModel =
          await AiRoleService.instance.isFreeModelEnabled('assistant');
      final roleSettings = await AiRoleService.instance.getSettingsForRole(
        'assistant',
      );

      // 6. Build enriched messages history to send to LLM (with system instruction and contextualized last message)
      final List<ChatMessage> messagesToSend = [];
      final systemPrompt = defaultSystemPrompts['analysis_system'] ?? '';
      if (systemPrompt.isNotEmpty) {
        messagesToSend.add(ChatMessage(role: 'system', content: systemPrompt));
      }
      // Add all previous messages (except the last one which we send enriched)
      for (int i = 0; i < updatedMessages.length - 1; i++) {
        messagesToSend.add(updatedMessages[i]);
      }
      // Add the contextualized last user message (carrying images for vision understanding)
      messagesToSend.add(
        ChatMessage(
          role: 'user',
          content: userContent,
          timestamp: userMessage.timestamp,
          images: userMessage.images,
        ),
      );

      _ref.read(aiStreamingMessageProvider.notifier).state = '小Q正在思考并分析任务...';

      // 初始化工具分发器并构建 AgentLoop
      final dispatcher = AgentToolRegistry.createDefaultDispatcher();
      
      // 预先配置好 AiService
      if (useFreeModel) {
        final freeModels =
            await AiRoleService.instance.getFreeModelConfigsForRole('assistant');
        if (freeModels.isEmpty) {
          throw Exception('免费模型列表为空，请先在设置中更新免费模型');
        }
        final preferredId =
            await AiRoleService.instance.getPreferredFreeModelId();
        final ordered = FreeModelService.instance.getOrderedModels(freeModels, preferredId);
        if (ordered.isNotEmpty) {
          final config = FreeModelService.instance.toAiConfig(ordered.first);
          aiService.updateConfig(
            config,
            temperature: roleSettings.temperature,
            maxTokens: roleSettings.maxTokens,
          );
        }
      } else {
        final assistantConfig = await AiRoleService.instance
            .getEffectiveConfigForRole('assistant');
        aiService.updateConfig(
          assistantConfig,
          temperature: roleSettings.temperature,
          maxTokens: roleSettings.maxTokens,
        );
      }

      final agentLoop = AgentLoop(
        aiService: aiService,
        dispatcher: dispatcher,
        maxTurns: 8,
      );

      final List<ChatMessage> conversationHistory = [];
      for (int i = 0; i < updatedMessages.length - 1; i++) {
        conversationHistory.add(updatedMessages[i]);
      }
      conversationHistory.add(
        ChatMessage(
          role: 'user',
          content: userContent,
          timestamp: userMessage.timestamp,
          images: userMessage.images,
        ),
      );

      ChatMessage? finalResponse;
      final sessionMessages = [...updatedMessages];

      await for (final event in agentLoop.run(
        conversationHistory: conversationHistory,
        systemPrompt: QSystemPrompt.prompt,
      )) {
        switch (event.type) {
          case AgentEventType.turnStart:
            _ref.read(aiStreamingMessageProvider.notifier).state =
                '小Q正在思考中 (第 ${event.turn} 步)...';
            break;
          case AgentEventType.thoughtUpdate:
            if (event.text != null && event.text!.isNotEmpty) {
              _ref.read(aiStreamingMessageProvider.notifier).state =
                  '💭 思考过程:\n${event.text}';
            }
            break;
          case AgentEventType.toolExecuting:
            final toolName = event.toolCall?.name ?? '';
            _ref.read(aiStreamingMessageProvider.notifier).state =
                '⚡ 小Q正在执行操作: [$toolName]...';
            break;
          case AgentEventType.toolCompleted:
            // 每当工具执行完成后，若有对应的变更，推入中间消息
            if (event.message != null) {
              sessionMessages.add(event.message!);
              state = state!.copyWith(messages: List.from(sessionMessages));
            }
            break;
          case AgentEventType.assistantMessage:
            if (event.message != null) {
              sessionMessages.add(event.message!);
              state = state!.copyWith(messages: List.from(sessionMessages));
            }
            break;
          case AgentEventType.finished:
            finalResponse = event.message;
            break;
          case AgentEventType.error:
            throw Exception(event.error ?? 'Agent 执行异常');
        }
      }

      if (finalResponse != null) {
        // 如果最后一条不是 finalResponse，则追加
        if (sessionMessages.isEmpty || sessionMessages.last != finalResponse) {
          sessionMessages.add(finalResponse);
        }
        state = state!.copyWith(messages: sessionMessages);
      }
    } catch (e, stackTrace) {
      LoggerService.instance.logAI(
        'AI对话发送失败: $e',
        level: LogLevel.error,
        details: stackTrace.toString(),
      );
      final errorMessage = ChatMessage(
        role: 'assistant',
        content: '抱歉，发生了错误，请稍后重试。\n\n错误详情: $e',
        timestamp: DateTime.now(),
      );
      state = state!.copyWith(messages: [...updatedMessages, errorMessage]);
    } finally {
      _isStreaming = false;
      _ref.read(aiStreamingMessageProvider.notifier).state = null;
      if (state != null) {
        await repo.updateChatSession(state!);
      }
    }
  }
}
