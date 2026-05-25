import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:qnote_flutter/config/defaults.dart';
import 'package:qnote_flutter/core/ai/ai_service.dart';
import 'package:qnote_flutter/core/ai/ai_role_service.dart';
import 'package:qnote_flutter/core/logger/logger_service.dart';
import 'package:qnote_flutter/core/storage/config_repository.dart';
import 'package:qnote_flutter/core/storage/diary_repository.dart';
import 'package:qnote_flutter/core/storage/note_repository.dart';
import 'package:qnote_flutter/models/ai_config.dart';
import 'package:qnote_flutter/models/ai_roles.dart';
import 'package:qnote_flutter/models/chat_session.dart';
import 'package:qnote_flutter/models/diary_record.dart';
import 'package:qnote_flutter/models/note.dart';
import 'package:uuid/uuid.dart';

class AiContextFilter {
  final String scope;
  final DateTime? startDate;
  final DateTime? endDate;
  final List<String> selectedNoteIds;
  final List<String> selectedTags;

  const AiContextFilter({
    this.scope = 'all',
    this.startDate,
    this.endDate,
    this.selectedNoteIds = const [],
    this.selectedTags = const [],
  });

  AiContextFilter copyWith({
    String? scope,
    DateTime? startDate,
    DateTime? endDate,
    List<String>? selectedNoteIds,
    List<String>? selectedTags,
  }) {
    return AiContextFilter(
      scope: scope ?? this.scope,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      selectedNoteIds: selectedNoteIds ?? this.selectedNoteIds,
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
    await refresh();
    return config;
  }

  Future<void> updateConfig(AiConfig config) async {
    final repo = ConfigRepository.instance;
    await repo.updateAiConfig(config);
    await refresh();
  }

  Future<void> deleteConfig(String id) async {
    final repo = ConfigRepository.instance;
    await repo.deleteAiConfig(id);
    await refresh();
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
    await refresh();
    return session;
  }

  Future<void> updateSession(ChatSession session) async {
    final repo = ConfigRepository.instance;
    await repo.updateChatSession(session);
    await refresh();
  }

  Future<void> deleteSession(String id) async {
    final repo = ConfigRepository.instance;
    await repo.softDeleteChatSession(id);
    await refresh();
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

  Future<String> exportContext() async {
    final filter = _ref.read(contextFilterProvider);
    final diaryRepo = DiaryRepository();
    final buffer = StringBuffer();

    if (filter.scope == 'none') return '';

    List<DiaryRecord> filteredDiary = [];
    if (filter.scope == 'all' ||
        filter.scope == 'date' ||
        filter.scope == 'mixed') {
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
    } else if (filter.selectedTags.isNotEmpty) {
      for (final tag in filter.selectedTags) {
        final records = await diaryRepo.getByTag(tag);
        for (final r in records) {
          if (!filteredDiary.any((exist) => exist.id == r.id)) {
            filteredDiary.add(r);
          }
        }
      }
    }

    List<Note> filteredNotes = [];
    if (filter.scope == 'notes' || filter.scope == 'mixed') {
      if (filter.selectedNoteIds.isNotEmpty) {
        final noteRepo = NoteRepository();
        for (final id in filter.selectedNoteIds) {
          final note = await noteRepo.getById(id);
          if (note != null) {
            filteredNotes.add(note);
          }
        }
      }
    }

    buffer.writeln('请基于以下数据回答我的问题：\n');

    if (filteredDiary.isNotEmpty) {
      buffer.writeln('### 日记记录\n');
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

    final configRepo = ConfigRepository.instance;
    final userProfile = await configRepo.getUserProfile();
    if (userProfile != null &&
        ((userProfile.nickname != null && userProfile.nickname!.isNotEmpty) ||
            (userProfile.birthday != null &&
                userProfile.birthday!.isNotEmpty) ||
            userProfile.height != null ||
            userProfile.weightHistory.isNotEmpty ||
            (userProfile.otherInfo != null &&
                userProfile.otherInfo!.isNotEmpty))) {
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
      buffer.writeln();
    }

    return buffer.toString().trim();
  }

  String _formatDateTime(DateTime dt) {
    return DateFormat('yyyy-MM-dd HH:mm').format(dt);
  }

  Future<void> sendMessage(String content) async {
    if (state == null) return;

    final now = DateTime.now();
    final repo = ConfigRepository.instance;

    // 1. Append user message with raw content to active display/save history immediately
    final userMessage = ChatMessage(
      role: 'user',
      content: content,
      timestamp: now,
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
        final context = await exportContext();
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
      final assistantConfig = await AiRoleService.instance
          .getEffectiveConfigForRole('assistant');
      final roleSettings = await AiRoleService.instance.getSettingsForRole(
        'assistant',
      );
      aiService.updateConfig(
        assistantConfig,
        temperature: roleSettings.temperature,
        maxTokens: roleSettings.maxTokens,
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
      // Add the contextualized last user message
      messagesToSend.add(
        ChatMessage(
          role: 'user',
          content: userContent,
          timestamp: userMessage.timestamp,
        ),
      );

      _ref.read(aiStreamingMessageProvider.notifier).state = '';
      await for (final chunk in aiService.chatStream(messagesToSend)) {
        _streamingContent.write(chunk);
        _ref.read(aiStreamingMessageProvider.notifier).state = _streamingContent.toString();
      }
      
      final assistantMessage = ChatMessage(
        role: 'assistant',
        content: _streamingContent.toString(),
        timestamp: DateTime.now(),
      );
      state = state!.copyWith(
        messages: [...updatedMessages, assistantMessage],
      );
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
