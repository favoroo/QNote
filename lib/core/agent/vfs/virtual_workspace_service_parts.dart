part of 'virtual_workspace_service.dart';

/// 虚拟工作区写入端点（todo/note/timeline/journal/memory/quick_prompts/skills/
/// folders/chats/settings/stats）及其私有辅助方法。
///
/// 通过 part 与主文件共享同一 library，可访问 [VirtualWorkspaceService] 的私有字段与私有方法；
/// 这些方法仅在 [VirtualWorkspaceService.writeFile] 内部派发使用，不是公共 API。
extension _VirtualWorkspaceWrites on VirtualWorkspaceService {
  Future<Map<String, dynamic>> _writeTodoFile(String path, String content) async {
    final segments = path.substring('/todos/'.length).split('/');
    String folderName = '今日';
    if (segments.length >= 2) {
      folderName = segments[0].trim();
    }
    final title = todoTitleFromPath(path);

    // 1. 解析 Frontmatter
    final parsed = _parseFrontmatter(content);
    final meta = parsed.meta;
    final description = parsed.body.trim();

    final status = (meta['status'] as String? ?? '').toLowerCase();
    final isCompleted = status == 'completed' || status == 'done' || path.contains('[x]');
    final rawPriority = (meta['priority'] as String? ?? 'normal').toLowerCase();
    final priority = (rawPriority == 'important' || rawPriority == 'high') ? 'important' : 'normal';
    final isLongTerm = meta['is_long_term'] == true || folderName == '长期';

    // 重复规则
    final rawRepeat = (meta['repeat_rule'] ?? meta['repeat'] ?? '').toString().trim().toLowerCase();
    String repeatRule = 'none';
    if (rawRepeat == 'daily' || rawRepeat == '每天' || rawRepeat == '每日') {
      repeatRule = 'daily';
    } else if (rawRepeat == 'workday' || rawRepeat == '工作日') {
      repeatRule = 'workday';
    } else if (rawRepeat == 'weekly' || rawRepeat == '每周') {
      repeatRule = 'weekly';
    } else if (rawRepeat == 'monthly' || rawRepeat == '每月') {
      repeatRule = 'monthly';
    } else if (rawRepeat == 'yearly' || rawRepeat == '每年') {
      repeatRule = 'yearly';
    } else if (['daily', 'workday', 'weekly', 'monthly', 'yearly', 'none'].contains(rawRepeat)) {
      repeatRule = rawRepeat;
    }

    // 标签
    String tags = '';
    if (meta['tags'] != null) {
      if (meta['tags'] is List) {
        tags = (meta['tags'] as List).map((e) => e.toString().trim()).join(',');
      } else {
        tags = meta['tags'].toString().replaceAll('[', '').replaceAll(']', '').replaceAll('"', '').trim();
      }
    }

    DateTime? dueDate;
    if (meta['due_date'] != null) {
      try {
        dueDate = DateTime.parse(meta['due_date'].toString().replaceAll('"', ''));
      } catch (_) {
        // 忽略：待办 meta 里的 due_date 非法时按无截止日期处理
      }
    }

    // 提醒时间：归一化为 MM-DD HH:mm 存储，这是一切通知的唯一触发源
    // （due_date 仅作记录，不会触发通知、应用内也不展示）
    final String? reminderTime = ReminderUtils.normalize(
      meta['reminder_time'] ?? meta['remind_at'] ?? meta['reminder'],
    );

    // 2. 解析或自动创建分类
    final folderId = await _resolveTodoFolder(folderName, isLongTerm: isLongTerm);

    // 3. 判断是更新还是创建
    final allTodos = await _todoRepo.getAll();
    final existingId = meta['id']?.toString().replaceAll('"', '');
    Todo? existing;
    if (existingId != null && existingId.isNotEmpty) {
      existing = allTodos.where((t) => t.id == existingId).firstOrNull;
      // 撤回恢复场景：id 命中已软删除的记录时复活，否则被删待办写回后仍然不可见
      if (existing == null) {
        final allWithDeleted = await _todoRepo.getAll(includeDeleted: true);
        existing = allWithDeleted.where((t) => t.id == existingId && t.isDeleted).firstOrNull;
      }
    }
    existing ??= allTodos.where((t) => t.title.trim() == title && t.folderId == folderId).firstOrNull;

    // 路径末段直接是实体 id 的 canonical 形态（/todos/<分类>/<id>.md：grep 命中、撤回快照、
    // 页面上下文提示都会产出这种路径）。两条防护缺一不可：
    // 1) 必须命中既有实体，否则会新建一条 UUID 标题的脏待办；
    // 2) 标题必须沿用既有标题——撤回恢复的正文自带 `id:`，会先按 id 命中并原样保留路径末段
    //    作为新标题，若照写就会把 UUID 顶成标题（历史脏数据的真实成因）。
    final isEntityIdPath = isUuidPathSegment(title);
    if (existing == null && isEntityIdPath) {
      existing = allTodos.where((t) => t.id == title).firstOrNull;
      if (existing == null) {
        throw Exception('未找到待办: $path（路径末段为实体 id，但对应待办不存在，请先 grep 确认现状）');
      }
    }
    final effectiveTitle = isEntityIdPath ? existing!.title : title;

    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        title: effectiveTitle.isNotEmpty ? effectiveTitle : existing.title,
        description: description,
        isCompleted: isCompleted,
        priority: priority,
        dueDate: dueDate ?? existing.dueDate,
        reminderTime: reminderTime ?? existing.reminderTime,
        repeatRule: repeatRule != 'none' ? repeatRule : existing.repeatRule,
        tags: tags.isNotEmpty ? tags : existing.tags,
        folderId: folderId,
        isLongTerm: isLongTerm,
        isDeleted: false,
        updatedAt: now,
      );
      await _todoRepo.update(updated);
      await NotificationService.instance.scheduleTodoReminder(updated);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updated);
      return {
        'status': 'updated',
        'path': path,
        'id': updated.id,
        'title': updated.title,
        'folder': folderName,
        'folder_id': folderId,
        'is_completed': updated.isCompleted,
        'due_date': _formatDueForDisplay(updated.dueDate),
        'reminder_time': updated.reminderTime,
        'repeat_rule': updated.repeatRule,
        'tags': updated.tags,
      };
    } else {
      final newTodo = Todo(
        id: const Uuid().v4(),
        title: effectiveTitle,
        description: description,
        isCompleted: isCompleted,
        priority: priority,
        dueDate: dueDate,
        folderId: folderId,
        isLongTerm: isLongTerm,
        reminderTime: reminderTime,
        repeatRule: repeatRule,
        tags: tags,
        sortOrder: now.millisecondsSinceEpoch,
        createdAt: now,
        updatedAt: now,
      );
      await _todoRepo.insert(newTodo);
      await NotificationService.instance.scheduleTodoReminder(newTodo);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.created, newTodo);
      return {
        'status': 'created',
        'path': path,
        'id': newTodo.id,
        'title': newTodo.title,
        'folder': folderName,
        'folder_id': folderId,
        'is_completed': newTodo.isCompleted,
        'due_date': _formatDueForDisplay(newTodo.dueDate),
        'reminder_time': newTodo.reminderTime,
        'repeat_rule': newTodo.repeatRule,
        'tags': newTodo.tags,
      };
    }
  }

  /// 供工具返回结果展示的截止时间文本（应用内提醒实际依赖 reminder_time）
  String? _formatDueForDisplay(DateTime? due) => formatWorkspaceDueTime(due);

  Future<String> _resolveTodoFolder(String folderName, {bool isLongTerm = false}) async {
    final folders = await _folderRepo.getByType('todo');
    final trimmed = folderName.trim();

    if (trimmed == '今日' || trimmed == 'today') {
      final today = folders.where((f) => f.id == 'todo_default_today' || f.name == '今日').firstOrNull;
      if (today != null) return today.id;
    }
    if (trimmed == '长期' || trimmed == 'longterm' || isLongTerm) {
      final longterm = folders.where((f) => f.id == 'todo_default_longterm' || f.name == '长期').firstOrNull;
      if (longterm != null) return longterm.id;
    }

    final matched = folders.where((f) => f.name.toLowerCase() == trimmed.toLowerCase()).firstOrNull;
    if (matched != null) return matched.id;

    // 不存在则自动新建待办分类
    final now = DateTime.now();
    final newFolder = Folder(
      id: const Uuid().v4(),
      name: trimmed,
      type: 'todo',
      sortOrder: folders.length,
      createdAt: now,
      updatedAt: now,
    );
    await _folderRepo.insert(newFolder);
    return newFolder.id;
  }

  /// 按名称解析笔记本目录 id，不存在则自动创建（写入与移动共用同一套归属规则）
  Future<String> _resolveOrCreateNoteFolder(String folderName) async {
    final trimmed = folderName.trim();
    final noteFolders = await _folderRepo.getByType('note');
    final matched = noteFolders.where((f) => f.name == trimmed).firstOrNull;
    if (matched != null) return matched.id;

    final now = DateTime.now();
    final newFolder = Folder(
      id: const Uuid().v4(),
      name: trimmed,
      type: 'note',
      sortOrder: noteFolders.length,
      createdAt: now,
      updatedAt: now,
    );
    await _folderRepo.insert(newFolder);
    return newFolder.id;
  }

  Future<Map<String, dynamic>> _writeNoteFile(String path, String content) async {
    final segments = path.substring('/notes/'.length).split('/');
    String? folderName;
    String titleWithExt;
    if (segments.length >= 2) {
      folderName = segments[0].trim();
      titleWithExt = segments.sublist(1).join('/');
    } else {
      titleWithExt = segments[0];
    }
    final title = titleWithExt.replaceAll('.md', '').trim();

    final parsed = _parseFrontmatter(content);
    final meta = parsed.meta;
    final noteContent = parsed.body;

    final String? folderId = (folderName != null && folderName.isNotEmpty)
        ? await _resolveOrCreateNoteFolder(folderName)
        : null;

    final allNotes = await _noteRepo.getAll();
    final existingId = meta['id']?.toString().replaceAll('"', '');
    Note? existing;
    if (existingId != null && existingId.isNotEmpty) {
      existing = allNotes.where((n) => n.id == existingId).firstOrNull;
      // 撤回恢复场景：id 命中已软删除的记录时复活，否则被删笔记写回后仍然不可见
      if (existing == null) {
        final allWithDeleted = await _noteRepo.getAll(includeDeleted: true);
        existing = allWithDeleted.where((n) => n.id == existingId && n.isDeleted).firstOrNull;
      }
    }
    existing ??= allNotes.where((n) => n.title.trim() == title && n.folderId == folderId).firstOrNull;

    // 路径末段是笔记 id 的 canonical 形态（/notes/<id>.md）时，命中既有实体且标题沿用原值，
    // 避免把 id 顶成笔记标题（撤回恢复的正文自带 `id:`，重写路径时会走到这里）；
    // 原分类由下方 copyWith 的 `folderId ?? existing.folderId` 兜底保留
    final isEntityIdPath = isUuidPathSegment(title);
    if (existing == null && isEntityIdPath) {
      existing = allNotes.where((n) => n.id == title).firstOrNull;
      if (existing == null) {
        throw Exception('未找到笔记: $path（路径末段为实体 id，但对应笔记不存在，请先 grep 确认现状）');
      }
    }
    final effectiveTitle = isEntityIdPath ? existing!.title : title;

    final tagsStr = meta['tags'] is List ? (meta['tags'] as List).join(', ') : (meta['tags']?.toString() ?? '');

    // 从 Markdown 正文提取图片链接回填 images 索引列：
    // WebDAV 同步只认 notes.images 列收集活动图片，不回填会导致小Q插入的
    // 生成图片/外链图片被视为孤儿文件而在同步时被清理
    final extractedImages = _extractImagesFromMarkdown(noteContent);

    final now = DateTime.now();
    if (existing != null) {
      final updated = existing.copyWith(
        title: effectiveTitle.isNotEmpty ? effectiveTitle : existing.title,
        content: noteContent,
        folderId: folderId ?? existing.folderId,
        isPinned: meta['pinned'] == true,
        tags: tagsStr.isNotEmpty ? tagsStr : existing.tags,
        images: extractedImages.isNotEmpty ? extractedImages : existing.images,
        isDeleted: false,
        updatedAt: now,
      );
      await _noteRepo.update(updated);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updated);
      return {'status': 'updated', 'path': path, 'id': updated.id, 'title': updated.title};
    } else {
      final newNote = Note(
        id: const Uuid().v4(),
        title: effectiveTitle,
        content: noteContent,
        folderId: folderId,
        isPinned: meta['pinned'] == true,
        tags: tagsStr,
        images: extractedImages,
        createdAt: now,
        updatedAt: now,
      );
      await _noteRepo.insert(newNote);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.created, newNote);
      return {'status': 'created', 'path': path, 'id': newNote.id, 'title': newNote.title};
    }
  }

  /// 从 Markdown 正文提取图片链接路径（`![...](路径)`），保持出现顺序并去重
  ///
  /// 与笔记编辑器的图片段识别规则一致：仅匹配独立成行的图片语法；
  /// data URI（Web 端内嵌图）体积过大且无需同步，跳过不入索引。
  static List<String> _extractImagesFromMarkdown(String content) => extractWorkspaceMarkdownImages(content);

  Future<Map<String, dynamic>> _writeTimelineFile(String path, String content) async {
    final dateStr = path.substring('/timeline/'.length).replaceAll('.md', '').trim();
    DateTime baseDate;
    try {
      baseDate = DateTime.parse(dateStr);
    } catch (_) {
      baseDate = DateTime.now();
    }

    // 获取当天数据库中现存的所有活跃记录，用于差量比对（Diff Deletion）
    final existingRecords = await _diaryRepo.getByDate(baseDate);

    // 解析 markdown 块。支持时间点 ## [HH:MM] 与时间段 ## [HH:MM - HH:MM]
    final blockRegex = RegExp(
      r'##\s*\[(\d{1,2}:\d{2})(?:\s*[-~至到]\s*(\d{1,2}:\d{2}))?\]\s*([^\n]+)(?:<!--\s*id:\s*([^\s>]+)\s*-->)?([\s\S]*?)(?=##\s*\[|(?![\s\S]))',
    );
    final matches = blockRegex.allMatches(content);

    // 记录本次写回中保留或新建的记录 ID
    final retainedIds = <String>{};
    int count = 0;
    int updatedCount = 0;
    int createdCount = 0;

    for (final m in matches) {
      final startTimeStr = m.group(1)!.trim();
      final endTimeStr = m.group(2)?.trim();
      var title = m.group(3) ?? '';
      final inlineId = RegExp(r'<!--\s*id:\s*([^\s>]+)\s*-->').firstMatch(title);
      final recordId = inlineId?.group(1)?.trim() ?? m.group(4)?.trim();
      title = title.replaceAll(RegExp(r'<!--.*?-->'), '').trim();
      final body = m.group(5)?.trim() ?? '';

      final timeParts = startTimeStr.split(':');
      final recordTime = DateTime(
        baseDate.year,
        baseDate.month,
        baseDate.day,
        int.parse(timeParts[0]),
        int.parse(timeParts[1]),
      );

      DateTime? endDateTime;
      if (endTimeStr != null && endTimeStr.isNotEmpty) {
        final endParts = endTimeStr.split(':');
        endDateTime = DateTime(
          baseDate.year,
          baseDate.month,
          baseDate.day,
          int.parse(endParts[0]),
          int.parse(endParts[1]),
        );
      }

      String category = '日常';
      int? mood;
      String detail = '';
      String weather = '';
      final photos = <String>[];
      final customFields = <String, dynamic>{};
      final explicitTags = <String>[];

      for (final line in body.split('\n')) {
        final l = line.trim().replaceAll('：', ':');
        if (l.startsWith('- 分类:') || l.startsWith('- category:')) {
          category = _fieldValue(l);
        } else if (l.startsWith('- 标签:') || l.startsWith('- tags:') || l.startsWith('- tag:')) {
          final tStr = _fieldValue(l);
          for (final part in tStr.split(RegExp('[,，、 ]+'))) {
            final t = part.trim();
            if (t.isNotEmpty && !explicitTags.contains(t)) {
              explicitTags.add(t);
            }
          }
        } else if (l.startsWith('- 心情:') || l.startsWith('- mood:')) {
          mood = int.tryParse(_fieldValue(l));
        } else if (l.startsWith('- 天气:') || l.startsWith('- weather:')) {
          weather = _fieldValue(l);
        } else if (l.startsWith('- 标记颜色:') || l.startsWith('- 颜色标记:') || l.startsWith('- color_mark:')) {
          final colorVal = _fieldValue(l);
          if (colorVal.isNotEmpty) {
            String hexColor = '#FFFF3B30';
            if (colorVal == 'green' || colorVal == '绿色') {
              hexColor = '#FF34C759';
            } else if (colorVal == 'blue' || colorVal == '蓝色') {
              hexColor = '#FF007AFF';
            } else if (colorVal == 'orange' || colorVal == '橙色') {
              hexColor = '#FFFF9500';
            } else if (colorVal == 'purple' || colorVal == '紫色') {
              hexColor = '#FFAF52DE';
            } else if (colorVal == 'red' || colorVal == '红色') {
              hexColor = '#FFFF3B30';
            } else {
              final c = _parseColor(colorVal);
              if (c != null) {
                hexColor = '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
              }
            }
            _colorMarkRepo.insert(DateColorMark(id: const Uuid().v4(), date: baseDate, color: hexColor));
            WorkspaceEventBus.instance.emit('/settings/color_marks.json', WorkspaceChangeType.updated, {
              'date': dateStr,
              'color': hexColor,
            });
          }
        } else if (l.startsWith('- 图片:') || l.startsWith('- photo:') || l.startsWith('- photos:')) {
          final pStr = _fieldValue(l);
          for (final p in pStr.split(',')) {
            // 读取时行尾附加了 view_image 提示标注，写回解析时剥离，避免混入图片路径
            final item = p.trim().replaceAll(RegExp('（可调用[^）]*）'), '').trim();
            if (item.isNotEmpty) photos.add(item);
          }
        } else if (l.startsWith('- 详情:') ||
            l.startsWith('- detail:') ||
            l.startsWith('- 内容:') ||
            l.startsWith('- content:')) {
          detail = _fieldValue(l);
        } else if (l.startsWith('- ') && l.contains(':')) {
          // 结构化指标识别（如「- 饮水: 500ml」、「- 消费金额: 35」）
          final key = l.substring(2, l.indexOf(':')).trim();
          final val = _fieldValue(l);
          if (key.isNotEmpty && val.isNotEmpty) {
            customFields[key] = val;
          }
        } else if (l.isNotEmpty) {
          detail += (detail.isEmpty ? '' : '\n') + l;
        }
      }

      // 分类与标签规整化：如果分类仍为默认日常，但已提供标准语义分类或 explicitTags
      if (category == '日常' && explicitTags.isNotEmpty) {
        final stdCats = ['饮食', '活动', '睡眠', '健康', '记账'];
        for (final sc in stdCats) {
          if (explicitTags.contains(sc)) {
            category = sc;
            break;
          }
        }
      }

      // 饮食/活动常见二级字段标准化兼容：
      if (category == '饮食') {
        if (!customFields.containsKey('rating') && !customFields.containsKey('评价')) {
          if (customFields.containsKey('健康度')) {
            customFields['评价'] = customFields.remove('健康度');
          } else if (customFields.containsKey('健康评价')) {
            customFields['评价'] = customFields.remove('健康评价');
          }
        }
      } else if (category == '活动') {
        if (!customFields.containsKey('type') && !customFields.containsKey('类型')) {
          if (customFields.containsKey('活动类型')) {
            customFields['类型'] = customFields.remove('活动类型');
          } else if (customFields.containsKey('项目')) {
            customFields['类型'] = customFields.remove('项目');
          }
        }
      }

      final tagEntries = <TagEntry>[];
      if (customFields.isNotEmpty) {
        tagEntries.add(
          TagEntry(
            id: const Uuid().v4(),
            name: category,
            fields: customFields,
            time: '${recordTime.hour.toString().padLeft(2, '0')}:${recordTime.minute.toString().padLeft(2, '0')}',
          ),
        );
      }

      final recordTags = <String>[category];
      for (final t in explicitTags) {
        if (!recordTags.contains(t)) {
          recordTags.add(t);
        }
      }

      final now = DateTime.now();
      DiaryRecord? existing;
      if (recordId != null && recordId.isNotEmpty) {
        existing = await _diaryRepo.getById(recordId);
      }
      existing ??= await _findTimelineRecord(baseDate, recordTime, title);

      if (existing != null) {
        final updated = existing.copyWith(
          title: title.isNotEmpty ? title : existing.title,
          content: detail,
          displayTag: category,
          tags: recordTags,
          time: recordTime,
          startTime: recordTime,
          endTime: endDateTime ?? existing.endTime,
          mood: mood ?? existing.mood,
          weather: weather.isNotEmpty ? weather : existing.weather,
          photos: photos.isNotEmpty ? photos : existing.photos,
          tagEntries: tagEntries.isNotEmpty ? tagEntries : existing.tagEntries,
          // 撤回恢复场景：id 命中已软删除的记录（getById 不过滤软删）时复活，否则写回后仍不可见
          isDeleted: false,
          updatedAt: now,
        );
        await _diaryRepo.update(updated);
        retainedIds.add(existing.id);
        count++;
        updatedCount++;
        continue;
      }

      final newRecord = DiaryRecord(
        id: const Uuid().v4(),
        title: title,
        content: detail,
        displayTag: category,
        tags: recordTags,
        time: recordTime,
        startTime: recordTime,
        endTime: endDateTime,
        mood: mood ?? 3,
        weather: weather,
        photos: photos,
        tagEntries: tagEntries,
        createdAt: now,
        updatedAt: now,
      );
      await _diaryRepo.insert(newRecord);
      retainedIds.add(newRecord.id);
      count++;
      createdCount++;
    }

    // 差量比对：软删除本次写回中已被移除的原有记录
    int deletedCount = 0;
    if (count > 0) {
      for (final oldRecord in existingRecords) {
        if (!retainedIds.contains(oldRecord.id)) {
          await _diaryRepo.softDelete(oldRecord.id);
          WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, oldRecord);
          deletedCount++;
        }
      }
    } else {
      // count == 0: 检查是否属于显式清空意图（剥除文件标题、提示引述行和空行）
      final remainingLines = content.split('\n').where((line) {
        final t = line.trim();
        if (t.isEmpty) return false;
        if (t.startsWith('#')) return false;
        if (t.startsWith('>')) return false;
        return true;
      }).toList();

      if (remainingLines.isEmpty) {
        // 显式清空：若当天有记录，则全部软删除
        for (final oldRecord in existingRecords) {
          await _diaryRepo.softDelete(oldRecord.id);
          WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.deleted, oldRecord);
          deletedCount++;
        }
        WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {
          'date': dateStr,
          'count': 0,
          'deleted': deletedCount,
        });
        return {
          'status': 'success',
          'path': path,
          'records_processed': 0,
          'records_deleted': deletedCount,
          'message': '已清空 $dateStr 的全部时间线流水',
        };
      }

      // 若还有其它非格式内容，说明模型误用了纯文本或 Frontmatter 写入，必须拦截避免静默失败
      throw Exception(
        '未在 /timeline/ 内容中识别到任何时间线事件块，本次写入已被拒绝（避免静默失败）。\n'
        '时间线必须使用二级标题「时间块」格式，且严禁使用 YAML Frontmatter：\n\n'
        '## [HH:MM] 事件标题\n'
        '- 分类: 饮食          （可选，默认「日常」）\n'
        '- 心情: 4             （可选，1~5）\n'
        '- 详情: 具体内容      （可选）\n\n'
        '示例：\n'
        '## [12:00] 午餐\n'
        '- 分类: 饮食\n'
        '- 详情: 中午吃了一碗方便面\n',
      );
    }

    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {
      'date': dateStr,
      'count': count,
      'created': createdCount,
      'updated': updatedCount,
      'deleted': deletedCount,
    });
    return {
      'status': 'success',
      'path': path,
      'records_processed': count,
      'records_created': createdCount,
      'records_updated': updatedCount,
      'records_deleted': deletedCount,
    };
  }

  /// 按「同一天 + 同一时刻 + 同一标题」查找已有时间线记录，作为 id 注释丢失时的去重兜底
  Future<DiaryRecord?> _findTimelineRecord(DateTime date, DateTime recordTime, String title) async {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return null;
    final records = await _diaryRepo.getByDate(date);
    return records.where((r) {
      return r.time.hour == recordTime.hour && r.time.minute == recordTime.minute && r.title.trim() == trimmed;
    }).firstOrNull;
  }

  /// 取「字段名: 值」中第一个冒号之后的全部内容（值本身可含冒号，不能用 split 取固定下标）
  String _fieldValue(String line) => workspaceFieldValue(line);

  Future<Map<String, dynamic>> _writeJournalFile(String path, String content) async {
    final dateStr = path.substring('/journal/'.length).replaceAll('.md', '').trim();
    DateTime date;
    try {
      date = DateTime.parse(dateStr);
    } catch (_) {
      date = DateTime.now();
    }
    await _journalService.saveJournal(date, content);
    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {'date': dateStr});
    return {'status': 'saved', 'path': path, 'date': dateStr};
  }

  /// 写入小Q长期记忆文档：校验分类与容量上限，保存并广播事件。
  /// 容量超限直接抛错（对齐 Hermes 有界记忆），引导小Q先整合再写入
  Future<Map<String, dynamic>> _writeMemoryFile(String path, String content) async {
    final category = AgentMemoryCategory.fromPath(path);
    if (category == null) {
      throw Exception('未知的记忆文件: $path（仅支持 /memory/user.md 与 /memory/agent.md）');
    }
    final normalized = content.trim();
    final maxChars = AgentMemoryCategory.maxChars(category);
    if (normalized.length > maxChars) {
      throw Exception('记忆容量已超限（${normalized.length}/$maxChars 字符）。请先 read_file 查阅现有条目，整合或删除过时内容后再写入。');
    }
    final doc = AgentMemoryDocument(category: category, content: normalized);
    await _configRepo.saveAgentMemory(doc);
    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, doc.toMap());
    return {'status': 'updated', 'path': path, 'usage': '${doc.usagePercent}%（${normalized.length}/$maxChars 字符）'};
  }

  /// 写入常用提示词列表：`/quick_prompts/prompts.md`
  ///
  /// 每行解析为一条提示词，以 "- " 开头的行自动剥离前缀；
  /// 空行自动跳过。全量覆写替换整个列表。
  Future<Map<String, dynamic>> _writeQuickPromptsFile(String path, String content) async {
    final name = path.substring('/quick_prompts/'.length).trim();
    if (name != 'prompts.md' && name.isNotEmpty) {
      throw Exception('未知的提示词文件: $path（仅支持 /quick_prompts/prompts.md）');
    }
    final prompts = content
        .split('\n')
        .map((line) => line.replaceFirst(RegExp(r'^-\s*'), '').trim())
        .where((line) => line.isNotEmpty)
        .toList();
    await QuickPromptService.instance.setPrompts(prompts);
    WorkspaceEventBus.instance.emit('/quick_prompts/prompts.md', WorkspaceChangeType.updated, {
      'count': prompts.length,
    });
    return {'status': 'updated', 'path': '/quick_prompts/prompts.md', 'count': prompts.length};
  }

  /// 写入用户自定义技能：`/skills/<名称>.md`（内置技能只读，直接拒绝）
  ///
  /// 正文为 Markdown 手册，frontmatter 的 `description` 作为技能索引描述；
  /// 缺失时回退取正文首个非空非标题行截断，避免索引里出现空描述。
  Future<Map<String, dynamic>> _writeSkillFile(String path, String content) async {
    final name = path.substring('/skills/'.length).trim();
    if (name.isEmpty || !name.endsWith('.md') || name.contains('/')) {
      throw Exception('非法的技能路径: $path（应为 /skills/<名称>.md，不支持子目录）');
    }
    final skillName = name.replaceAll(RegExp(r'\.md$'), '').trim();
    if (_skillRegistry.isBuiltinSkill(skillName)) {
      throw Exception(
        '「$skillName」是内置技能，不可修改。请用新的名称创建自定义技能，'
        '或直接创建同名以外的技能文件。',
      );
    }

    final parsed = _parseFrontmatter(content);
    final body = parsed.body.trim();
    if (body.isEmpty) {
      throw Exception('技能手册正文不能为空');
    }

    // frontmatter 未提供 description 时，从正文首个非标题行提取摘要；
    // 正文只有标题时退而取首个标题文本，避免索引里出现空描述
    var description = (parsed.meta['description'] as String? ?? '').trim();
    if (description.isEmpty) {
      final lines = body.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
      var fallback = lines.firstWhere(
        (l) => !l.startsWith('#'),
        orElse: () => lines.isEmpty ? '' : lines.first.replaceFirst(RegExp(r'^#+\s*'), ''),
      );
      if (fallback.length > 80) fallback = '${fallback.substring(0, 80)}…';
      description = fallback;
    }

    final existed = _skillRegistry.getUserSkill(skillName) != null;
    await _skillRegistry.saveUserSkill(AgentSkill(name: skillName, description: description, content: body));
    WorkspaceEventBus.instance.emit(AgentSkill.pathOf(skillName), WorkspaceChangeType.updated, {'name': skillName});
    return {
      'status': existed ? 'updated' : 'created',
      'path': AgentSkill.pathOf(skillName),
      'name': skillName,
      'description': description,
    };
  }

  Future<Map<String, dynamic>> _writeSettingsFile(String path, String content) async {
    final name = path.substring('/settings/'.length).trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('配置文件必须为合法 JSON 格式: $e');
    }

    if (name == 'appearance.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('appearance.json 必须是 JSON 对象');
      }
      final prefs = await SharedPreferences.getInstance();
      final hasBackgroundStyle = decoded.containsKey('backgroundStyle');
      final hasCustomColor = decoded.containsKey('customBackgroundColor') || decoded.containsKey('backgroundColor');

      // 兼容旧字段：只有没显式指定 backgroundStyle 时，themeMode 才回落成基础背景预设
      if (!hasBackgroundStyle && decoded.containsKey('themeMode')) {
        final mode = _parseThemeMode(decoded['themeMode']);
        final preset = switch (mode) {
          ThemeMode.light => AppBackgroundPreset.light,
          ThemeMode.dark => AppBackgroundPreset.dark,
          ThemeMode.system => AppBackgroundPreset.system,
        };
        await prefs.setInt('background_preset', preset.index);
      }

      if (hasCustomColor) {
        final rawColor = decoded['customBackgroundColor'] ?? decoded['backgroundColor'];
        final color = _parseColor(rawColor);
        if (color != null) {
          await prefs.setInt('background_custom_color', color.toARGB32());
          // 只给颜色、没指定风格和 themeMode 时，默认切到自定义背景
          if (!hasBackgroundStyle && !decoded.containsKey('themeMode')) {
            await prefs.setInt('background_preset', AppBackgroundPreset.custom.index);
          }
        }
      }

      if (hasBackgroundStyle) {
        final preset = _parseBackgroundPreset(decoded['backgroundStyle']);
        await prefs.setInt('background_preset', preset.index);
      }

      if (decoded.containsKey('accentColor')) {
        final color = _parseColor(decoded['accentColor']);
        if (color != null) {
          await prefs.setInt('accent_color', color.toARGB32());
        }
      }

      final currentPresetIndex = prefs.getInt('background_preset');
      final currentPreset = currentPresetIndex == null
          ? switch (prefs.getInt('theme_mode') ?? 0) {
              1 => AppBackgroundPreset.light,
              2 => AppBackgroundPreset.dark,
              _ => AppBackgroundPreset.system,
            }
          : AppBackgroundPreset.values[currentPresetIndex.clamp(0, AppBackgroundPreset.values.length - 1)];
      final currentAccentVal = prefs.getInt('accent_color') ?? 0xFF005BCB;
      final currentAccent = Color(currentAccentVal);
      final currentCustomVal =
          prefs.getInt('background_custom_color') ?? AppBackgroundSetting.defaultCustomColor.toARGB32();
      final setting = AppBackgroundSetting(preset: currentPreset, customColor: Color(currentCustomVal));
      final resolvedCanvas = currentPreset == AppBackgroundPreset.system
          ? null
          : setting.resolveCanvas(accentColor: currentAccent, platformBrightness: Brightness.light);
      final legacyThemeMode = resolvedCanvas == null
          ? ThemeMode.system
          : (AppContrast.onColor(resolvedCanvas) == AppContrast.lightInk ? ThemeMode.dark : ThemeMode.light);
      // 旧读取方仍看 theme_mode，这里按实际画布亮度回写，保持兼容
      await prefs.setInt('theme_mode', legacyThemeMode.index);

      final updatedData = {
        'themeMode': _themeModeToString(legacyThemeMode),
        'backgroundStyle': workspaceBackgroundPresetToString(currentPreset),
        'customBackgroundColor': _colorToHex(Color(currentCustomVal)),
        'accentColor': _colorToHex(currentAccent),
      };
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updatedData);
      return {'status': 'updated', 'path': path, 'data': updatedData};
    }

    if (name == 'health.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('health.json 必须是 JSON 对象');
      }
      final prefs = await SharedPreferences.getInstance();
      if (decoded.containsKey('dailyStepTarget')) {
        final target = decoded['dailyStepTarget'];
        final parsed = target is num ? target.toInt() : int.tryParse('$target');
        if (parsed == null || parsed < 1000 || parsed > 100000) {
          throw Exception('dailyStepTarget 必须为 1000-100000 之间的整数步');
        }
        await prefs.setInt(HealthSyncService.keyDailyStepTarget, parsed);
      }
      if (decoded.containsKey('autoSync')) {
        if (decoded['autoSync'] is! bool) {
          throw Exception('autoSync 必须为布尔值 true/false');
        }
        await prefs.setBool(HealthSyncService.keyAutoSync, decoded['autoSync'] as bool);
      }
      final currentTarget =
          prefs.getInt(HealthSyncService.keyDailyStepTarget) ?? HealthSyncService.defaultDailyStepTarget;
      final currentAutoSync = prefs.getBool(HealthSyncService.keyAutoSync) ?? true;
      final updatedData = {'dailyStepTarget': currentTarget, 'autoSync': currentAutoSync};
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updatedData);
      return {'status': 'updated', 'path': path, 'data': updatedData};
    }

    if (name == 'ai.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('ai.json 必须是 JSON 对象');
      }
      // 1. 更新 roles（绑定值为「厂商id::模型名」，写 null 清空绑定）
      if (decoded.containsKey('roles') && decoded['roles'] is Map<String, dynamic>) {
        final rolesMap = decoded['roles'] as Map<String, dynamic>;
        var currentRoles = await _configRepo.getAiRoles() ?? const AiRoles();
        if (rolesMap.containsKey('assistant') && rolesMap['assistant'] is Map<String, dynamic>) {
          final ast = rolesMap['assistant'] as Map<String, dynamic>;
          if (ast.containsKey('model')) {
            currentRoles = currentRoles.copyWith(assistant: AiModelRef.tryParse(ast['model'] as String?));
          }
        }
        if (rolesMap.containsKey('timelineOptimization') && rolesMap['timelineOptimization'] is Map<String, dynamic>) {
          final tlo = rolesMap['timelineOptimization'] as Map<String, dynamic>;
          if (tlo.containsKey('model')) {
            currentRoles = currentRoles.copyWith(timelineOptimization: AiModelRef.tryParse(tlo['model'] as String?));
          }
        }
        if (rolesMap.containsKey('imageGeneration') && rolesMap['imageGeneration'] is Map<String, dynamic>) {
          final img = rolesMap['imageGeneration'] as Map<String, dynamic>;
          if (img.containsKey('model')) {
            currentRoles = currentRoles.copyWith(imageGeneration: AiModelRef.tryParse(img['model'] as String?));
          }
        }
        await _configRepo.saveAiRoles(currentRoles);
      }

      // 2. 更新 temperatures
      if (decoded.containsKey('temperatures') && decoded['temperatures'] is Map<String, dynamic>) {
        final tempsMap = decoded['temperatures'] as Map<String, dynamic>;
        var currentTemps = await _configRepo.getAiTemperatures() ?? const AiTemperatures();
        if (tempsMap.containsKey('assistant') && tempsMap['assistant'] is Map<String, dynamic>) {
          final ast = tempsMap['assistant'] as Map<String, dynamic>;
          currentTemps = currentTemps.copyWith(
            assistant: currentTemps.assistant.copyWith(
              temperature: (ast['temperature'] as num?)?.toDouble() ?? currentTemps.assistant.temperature,
              maxTokens: (ast['maxTokens'] as num?)?.toInt() ?? currentTemps.assistant.maxTokens,
            ),
          );
        }
        if (tempsMap.containsKey('timelineOptimization') && tempsMap['timelineOptimization'] is Map<String, dynamic>) {
          final tlo = tempsMap['timelineOptimization'] as Map<String, dynamic>;
          currentTemps = currentTemps.copyWith(
            timelineOptimization: currentTemps.timelineOptimization.copyWith(
              temperature: (tlo['temperature'] as num?)?.toDouble() ?? currentTemps.timelineOptimization.temperature,
              maxTokens: (tlo['maxTokens'] as num?)?.toInt() ?? currentTemps.timelineOptimization.maxTokens,
              extractImages: (tlo['extractImages'] as bool?) ?? currentTemps.timelineOptimization.extractImages,
            ),
          );
        }
        await _configRepo.saveAiTemperatures(currentTemps);
      }

      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, decoded);
      return {'status': 'updated', 'path': path};
    }

    if (name == 'personality.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('personality.json 必须是 JSON 对象');
      }
      await QPersonalityService.instance.applyPartialConfig(decoded);
      final updatedData = {'activeId': await QPersonalityService.instance.getActiveId(), 'note': '个性已更新，下轮对话生效'};
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, updatedData);
      return {'status': 'updated', 'path': path, 'data': updatedData};
    }

    if (name == 'shortcuts.json') {
      List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['shortcuts'] is List) {
        list = decoded['shortcuts'] as List;
      } else if (decoded is Map<String, dynamic>) {
        list = [decoded];
      } else {
        throw Exception('shortcuts.json 必须是快捷按钮数组或包含 shortcuts 字段的对象');
      }

      final current = await _configRepo.getAllShortcutConfigs();
      final currentMap = {for (final s in current) s.id: s};

      for (int i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map<String, dynamic>) continue;
        final map = Map<String, dynamic>.from(item);
        final id = map['id']?.toString() ?? const Uuid().v4();
        map['id'] = id;

        final now = DateTime.now();
        final config = ShortcutConfig(
          id: id,
          name: (map['name'] ?? map['label'] ?? '未命名快捷键').toString(),
          hasPopup: map['has_popup'] == 1 || map['hasPopup'] == true,
          sortOrder: (map['sort_order'] ?? map['sortOrder'] as num?)?.toInt() ?? i,
          isVisible: map['is_visible'] != 0 && map['isVisible'] != false,
          createdAt: currentMap[id]?.createdAt ?? now,
          updatedAt: now,
        );

        if (currentMap.containsKey(id)) {
          await _configRepo.updateShortcutConfig(config);
        } else {
          await _configRepo.insertShortcutConfig(config);
        }
      }

      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, list);
      return {'status': 'updated', 'path': path, 'count': list.length};
    }

    if (name == 'fixed_events.json') {
      List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['events'] is List) {
        list = decoded['events'] as List;
      } else if (decoded is Map<String, dynamic>) {
        list = [decoded];
      } else {
        throw Exception('fixed_events.json 必须是固定事件数组');
      }

      final repo = FixedEventRepository.instance;
      final current = await repo.getAll();
      final currentMap = {for (final e in current) e.id: e};

      for (int i = 0; i < list.length; i++) {
        final item = list[i];
        if (item is! Map<String, dynamic>) continue;
        final map = Map<String, dynamic>.from(item);
        final id = map['id']?.toString() ?? const Uuid().v4();
        map['id'] = id;
        final now = DateTime.now();
        final name = (map['name'] ?? map['title'] ?? '未命名习惯').toString();
        final isTimePoint = map['is_time_point'] == 1 || map['isTimePoint'] == true;
        final content = map['content']?.toString();
        final isEnabled = map['is_enabled'] != 0 && map['isEnabled'] != false;
        final sortOrder = (map['sort_order'] ?? map['sortOrder'] as num?)?.toInt() ?? i;

        // 解析多时间段（兼顾标准 timePeriods、下划线 time_periods，以及模型自拟的 timeSlots / periods）
        final List<TimePeriod> periods = [];
        dynamic rawPeriods = map['timePeriods'] ?? map['time_periods'] ?? map['timeSlots'] ?? map['periods'];
        if (rawPeriods is String && rawPeriods.isNotEmpty) {
          try {
            rawPeriods = jsonDecode(rawPeriods);
          } catch (_) {
            // 忽略：time_periods 存储为非法 JSON 时按非列表处理，回退到顶层起止时间
          }
        }
        if (rawPeriods is List) {
          for (final p in rawPeriods) {
            if (p is Map) {
              final s = (p['startTime'] ?? p['start_time'] ?? p['start'] ?? '08:00').toString();
              final e = (p['endTime'] ?? p['end_time'] ?? p['end'] ?? '').toString();
              periods.add(TimePeriod(startTime: s, endTime: isTimePoint ? '' : e));
            }
          }
        }

        // 如果没有提供多时段数组，则使用顶层的 start_time/startTime 与 end_time/endTime
        final fallbackStart = (map['start_time'] ?? map['startTime'] ?? '08:00').toString();
        final fallbackEnd = (map['end_time'] ?? map['endTime'] ?? '').toString();

        if (periods.isEmpty) {
          periods.add(TimePeriod(startTime: fallbackStart, endTime: isTimePoint ? '' : fallbackEnd));
        }

        final startTime = periods.first.startTime;
        final endTime = isTimePoint ? '' : periods.first.endTime;

        List<String> tags = currentMap[id]?.tags ?? [];
        if (map['tags'] is List) {
          tags = (map['tags'] as List).map((e) => e.toString()).toList();
        } else if (map['tags'] is String && (map['tags'] as String).isNotEmpty) {
          try {
            final decodedTags = jsonDecode(map['tags'] as String);
            if (decodedTags is List) {
              tags = decodedTags.map((e) => e.toString()).toList();
            }
          } catch (_) {
            // 忽略：tags 不是合法 JSON 时保留该固定事件原有标签
          }
        }

        final template = FixedEventTemplate(
          id: id,
          name: name,
          startTime: startTime,
          endTime: endTime,
          isTimePoint: isTimePoint,
          content: content,
          tags: tags,
          tagFields: currentMap[id]?.tagFields ?? {},
          sortOrder: sortOrder,
          isEnabled: isEnabled,
          timePeriods: periods,
          createdAt: currentMap[id]?.createdAt ?? now,
          updatedAt: now,
        );

        if (currentMap.containsKey(id)) {
          await repo.update(template);
        } else {
          await repo.insert(template);
        }
      }

      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, list);
      return {'status': 'updated', 'path': path, 'count': list.length};
    }

    if (name == 'weight.json') {
      double? newWeight;
      DateTime time = DateTime.now();
      if (decoded is Map<String, dynamic>) {
        newWeight = (decoded['weight'] as num?)?.toDouble();
        if (decoded['time'] != null) {
          try {
            time = DateTime.parse(decoded['time'].toString());
          } catch (_) {
            // 忽略：weight.json 的 time 非法时按当前时间记录
          }
        }
      } else if (decoded is num) {
        newWeight = decoded.toDouble();
      }
      if (newWeight == null || newWeight <= 0) {
        throw Exception('weight.json 必须包含有效的 weight 数值（例如: {"weight": 68.5}）');
      }
      final profile =
          await _configRepo.getUserProfile() ??
          UserProfile(id: const Uuid().v4(), createdAt: DateTime.now(), updatedAt: DateTime.now());
      final record = WeightRecord(id: const Uuid().v4(), weight: newWeight, time: time);
      final updatedProfile = profile.copyWith(weightHistory: [...profile.weightHistory, record]);
      await _configRepo.saveUserProfile(updatedProfile);
      WorkspaceEventBus.instance.emit('/settings/profile.json', WorkspaceChangeType.updated, updatedProfile);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, record);
      return {'status': 'created', 'path': path, 'weight': newWeight, 'time': time.toIso8601String()};
    }

    if (name == 'profile.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('profile.json 必须是 JSON 对象');
      }
      final existing = await _configRepo.getUserProfile();
      final mergedMap = Map<String, dynamic>.from(existing?.toMap() ?? {});
      mergedMap.addAll(decoded);

      // 类型归一化：若模型传入原生 List/Map，转换为 JSON 字符串以防 ClassCastException
      if (mergedMap['weight_history'] != null && mergedMap['weight_history'] is! String) {
        mergedMap['weight_history'] = jsonEncode(mergedMap['weight_history']);
      }
      if (mergedMap['custom_fields'] != null && mergedMap['custom_fields'] is! String) {
        mergedMap['custom_fields'] = jsonEncode(mergedMap['custom_fields']);
      }

      mergedMap['id'] = existing?.id ?? const Uuid().v4();
      mergedMap['updated_at'] = DateTime.now().toIso8601String();
      if (!mergedMap.containsKey('created_at')) {
        mergedMap['created_at'] = DateTime.now().toIso8601String();
      }

      final profile = UserProfile.fromMap(mergedMap);
      await _configRepo.saveUserProfile(profile);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, profile);
      return {'status': 'updated', 'path': path, 'name': profile.name};
    }

    if (name == 'color_marks.json') {
      List<dynamic> list;
      if (decoded is List) {
        list = decoded;
      } else if (decoded is Map<String, dynamic> && decoded['marks'] is List) {
        list = decoded['marks'] as List;
      } else if (decoded is Map<String, dynamic>) {
        list = [decoded];
      } else {
        throw Exception('color_marks.json 必须是标记数组或包含 marks 字段的对象');
      }

      int processed = 0;
      for (final item in list) {
        if (item is! Map<String, dynamic>) continue;
        final dateStr = item['date']?.toString().trim();
        final rawColor = item['color']?.toString().trim().toLowerCase();
        if (dateStr == null || dateStr.isEmpty) continue;

        DateTime date;
        try {
          date = DateTime.parse(dateStr);
        } catch (_) {
          continue;
        }

        if (rawColor == null || rawColor.isEmpty || rawColor == 'none' || rawColor == 'clear' || rawColor == '清除') {
          await _colorMarkRepo.deleteByDate(date);
          processed++;
          continue;
        }

        // 解析颜色
        String hexColor = '#FFFF3B30'; // 默认红色
        if (rawColor == 'red' || rawColor == '红色') {
          hexColor = '#FFFF3B30';
        } else if (rawColor == 'green' || rawColor == '绿色') {
          hexColor = '#FF34C759';
        } else if (rawColor == 'blue' || rawColor == '蓝色') {
          hexColor = '#FF007AFF';
        } else if (rawColor == 'orange' || rawColor == '橙色') {
          hexColor = '#FFFF9500';
        } else if (rawColor == 'purple' || rawColor == '紫色') {
          hexColor = '#FFAF52DE';
        } else {
          final c = _parseColor(rawColor);
          if (c != null) {
            hexColor = '#${c.toARGB32().toRadixString(16).padLeft(8, '0').toUpperCase()}';
          }
        }

        final mark = DateColorMark(id: const Uuid().v4(), date: date, color: hexColor);
        await _colorMarkRepo.insert(mark);
        processed++;
      }

      WorkspaceEventBus.instance.emit('/settings/color_marks.json', WorkspaceChangeType.updated, {'count': processed});
      WorkspaceEventBus.instance.emit('/timeline/', WorkspaceChangeType.updated, {'count': processed});
      return {'status': 'updated', 'path': path, 'count': processed};
    }

    if (name == 'webdav.json') {
      if (decoded is! Map<String, dynamic>) {
        throw Exception('webdav.json 必须是 JSON 对象');
      }
      final existing = await _configRepo.getWebdavConfig();
      final mergedMap = Map<String, dynamic>.from(existing?.toMap() ?? {});
      mergedMap.addAll(decoded);
      if (!mergedMap.containsKey('id')) {
        mergedMap['id'] = existing?.id ?? const Uuid().v4();
      }
      mergedMap['updated_at'] = DateTime.now().toIso8601String();

      final webdav = WebdavConfig.fromMap(mergedMap);
      await _configRepo.upsertWebdavConfig(webdav);
      WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, webdav);
      return {'status': 'updated', 'path': path};
    }

    throw Exception('不支持修改此配置: $path');
  }

  Future<Map<String, dynamic>> _writeFoldersFile(String path, String content) async {
    final name = path.substring('/folders/'.length).trim();
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('分类配置必须为合法 JSON 格式: $e');
    }

    final type = name == 'todos.json' ? 'todo' : (name == 'notes.json' ? 'note' : null);
    if (type == null) {
      throw Exception('不支持修改的分类配置: $path');
    }

    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map<String, dynamic> && decoded['folders'] is List) {
      list = decoded['folders'] as List;
    } else if (decoded is Map<String, dynamic>) {
      list = [decoded];
    } else {
      throw Exception('分类配置必须为数组或包含 folders 字段的对象');
    }

    final existingFolders = await _folderRepo.getByType(type);
    final existingMap = {for (final f in existingFolders) f.id: f};
    int count = 0;

    for (int i = 0; i < list.length; i++) {
      final item = list[i];
      if (item is! Map<String, dynamic>) continue;
      final map = Map<String, dynamic>.from(item);
      final rawName = (map['name'] ?? map['title'] ?? '').toString().trim();
      if (rawName.isEmpty) continue;

      final id = map['id']?.toString() ?? const Uuid().v4();
      final parentId = map['parentId']?.toString() ?? map['parent_id']?.toString();
      final sortOrder = (map['sortOrder'] ?? map['sort_order'] as num?)?.toInt() ?? i;
      final isExpanded = map['isExpanded'] != false && map['is_expanded'] != 0;
      final now = DateTime.now();

      final folder = Folder(
        id: id,
        name: rawName,
        parentId: parentId,
        type: type,
        sortOrder: sortOrder,
        isExpanded: isExpanded,
        createdAt: existingMap[id]?.createdAt ?? now,
        updatedAt: now,
      );

      if (existingMap.containsKey(id)) {
        await _folderRepo.update(folder);
      } else {
        await _folderRepo.insert(folder);
      }
      count++;
    }

    WorkspaceEventBus.instance.emit(path, WorkspaceChangeType.updated, {'type': type, 'count': count});
    return {'status': 'updated', 'path': path, 'type': type, 'count': count};
  }

  Future<Map<String, dynamic>> _writeChatsFile(String path, String content) async {
    final name = path.substring('/chats/'.length).trim();
    if (name != 'sessions.json') {
      throw Exception('不支持修改的会话文件: $path');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('会话配置必须为合法 JSON 格式: $e');
    }

    List<dynamic> list;
    if (decoded is List) {
      list = decoded;
    } else if (decoded is Map<String, dynamic> && decoded['sessions'] is List) {
      list = decoded['sessions'] as List;
    } else if (decoded is Map<String, dynamic>) {
      list = [decoded];
    } else {
      throw Exception('会话配置必须为数组或包含 sessions 字段的对象');
    }

    int updatedCount = 0;
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id']?.toString();
      final newTitle = item['title']?.toString().trim();
      if (id == null || id.isEmpty || newTitle == null || newTitle.isEmpty) {
        continue;
      }

      final existing = await _configRepo.getChatSession(id);
      if (existing != null) {
        final updated = existing.copyWith(title: newTitle, updatedAt: DateTime.now());
        await _configRepo.updateChatSession(updated);
        updatedCount++;
      }
    }

    WorkspaceEventBus.instance.emit('/chats/sessions.json', WorkspaceChangeType.updated, {'count': updatedCount});
    return {'status': 'updated', 'path': path, 'updated_count': updatedCount};
  }

  /// 写入 /stats/ 下的评分数据
  Future<Map<String, dynamic>> _writeStatsFile(String path, String content) async {
    if (path == VirtualWorkspaceService.kStatsAdjustPath) {
      return await _writeStatsAdjustFile(content);
    }
    if (!path.startsWith('/stats/scores/')) {
      throw Exception(
        '当前统计路径不支持直接覆写: $path（宏观汇总 summary.json / daily_scores.json 仅供读取，若要给某天评分或修改分数，请写入单日路径: /stats/scores/YYYY-MM-DD.json）',
      );
    }

    final dateStr = path.substring('/stats/scores/'.length).replaceAll('.json', '').trim();
    DateTime date;
    try {
      date = DateTime.parse(dateStr);
    } catch (_) {
      throw Exception('无效的评分日期格式: $dateStr（正确格式应为 YYYY-MM-DD.json）');
    }

    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('评分数据必须是合法的 JSON 格式: $e');
    }

    if (decoded is! Map<String, dynamic>) {
      throw Exception('评分数据必须是 JSON 对象');
    }

    // 未出现的字段一律不改：缺省的总分不再兜成 60，缺失的维度不再被总分覆盖
    final rawTotal = decoded['totalScore'] ?? decoded['total_score'] ?? decoded['score'];
    final int? totalScore = rawTotal is num ? rawTotal.toInt() : null;

    final rawDims = decoded['dimensionScores'] ?? decoded['dimension_scores'] ?? decoded['dimensions'];
    final Map<String, int> dimensionScores = {};
    if (rawDims is Map) {
      for (final entry in rawDims.entries) {
        final key = entry.key.toString().trim();
        final val = entry.value;
        if (val is num) {
          dimensionScores[key] = val.toInt();
        }
      }
    }

    // 总结与建议
    final summary = (decoded['summary'] ?? '').toString().trim();
    final suggestions = (decoded['suggestions'] ?? decoded['suggestion'] ?? '').toString().trim();

    // 记录数量：payload 未给时按当天流水数；0 视为未提供，保留库里原值
    int? recordCount;
    final rawCount = decoded['recordCount'] ?? decoded['record_count'];
    if (rawCount is num) {
      recordCount = rawCount.toInt();
    } else {
      final records = await _diaryRepo.getByDate(date);
      if (records.isNotEmpty) recordCount = records.length;
    }

    final result = await DailyScoreService.instance.upsertFromPayload(
      date: date,
      totalScore: totalScore,
      dimensionScores: dimensionScores,
      summary: summary,
      suggestions: suggestions,
      recordCount: recordCount,
    );

    // 回显刻意不含 summary：批量改分时逐日评语原文会白白吃掉大量上下文
    return {
      'status': result.status,
      'path': path,
      'id': result.saved.id,
      'date': dateStr,
      'totalScore': result.saved.totalScore,
      'dimensionScores': result.saved.dimensionScores,
    };
  }

  /// 范围批量调整历史评分：一次调用改完一段日期区间。
  ///
  /// 为什么不逐天 write_file：那等于把上百个整数加减交给模型心算，算错了既不
  /// 报错也看不出来；加减分统一由 [applyScoreAdjust] 计算并钳位。
  Future<Map<String, dynamic>> _writeStatsAdjustFile(String content) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(content);
    } catch (e) {
      throw Exception('评分调整指令必须是合法的 JSON 格式: $e');
    }
    if (decoded is! Map<String, dynamic>) {
      throw Exception('评分调整指令必须是 JSON 对象');
    }

    final from = _parseStatsDate(decoded['dateFrom'] ?? decoded['from'] ?? decoded['start'], 'dateFrom');
    final to = _parseStatsDate(decoded['dateTo'] ?? decoded['to'] ?? decoded['end'], 'dateTo');
    final fields = _parseScoreFields(decoded['fields']);

    final rawDelta = decoded['delta'] ?? decoded['offset'];
    final rawSet = decoded['setValue'] ?? decoded['set'];
    if ((rawDelta is num) == (rawSet is num)) {
      throw Exception('delta（加减分）与 setValue（设为固定值）必须且只能提供一个');
    }
    final spec = rawDelta is num
        ? ScoreAdjustSpec(delta: rawDelta.toInt(), fields: fields)
        : ScoreAdjustSpec(setValue: (rawSet as num).toInt(), fields: fields);
    final dryRun = decoded['dryRun'] == true;

    final service = DailyScoreService.instance;
    if (!dryRun) {
      // 先算一遍拿到「实际会变更的日期」，逐天补捕撤回快照
      final preview = await service.adjustRange(from: from, to: to, spec: spec, dryRun: true);
      for (final outcome in preview.outcomes) {
        await _captureUndoState('/stats/scores/${_statsDateKey(outcome.before.date)}.json');
      }
    }

    final adjusted = await service.adjustRange(from: from, to: to, spec: spec, dryRun: dryRun);
    return {
      'status': dryRun ? 'preview' : 'adjusted',
      'range': '${_statsDateKey(from)} ~ ${_statsDateKey(to)}',
      'applied': adjusted.applied,
      'scoredDays': adjusted.scoredDays,
      'missingDays': adjusted.missingDays,
      'clampedDays': adjusted.clamped,
      'summary': adjusted.preview,
      'changes': adjusted.outcomes
          .take(8)
          .map(
            (o) => {
              'date': _statsDateKey(o.before.date),
              'fields': o.changes.map((c) => '${c.field.label} ${c.before ?? '—'}→${c.after}').toList(),
            },
          )
          .toList(),
    };
  }

  /// 评分端点里的日期归一化为 `YYYY-MM-DD`
  String _statsDateKey(DateTime date) => workspaceStatsDateKey(date);

  DateTime _parseStatsDate(dynamic raw, String label) => parseWorkspaceStatsDate(raw, label);

  Set<ScoreField> _parseScoreFields(dynamic raw) {
    if (raw is! List || raw.isEmpty) return kAllScoreFields;
    final fields = <ScoreField>{};
    for (final entry in raw) {
      final field = ScoreField.fromKey(entry.toString());
      if (field == null) {
        throw Exception('未知的评分字段: $entry（可选 total/sleep/diet/activity/health/screen）');
      }
      fields.add(field);
    }
    return fields;
  }

  /// 颜色解析辅助方法（支持 hex #RRGGBB、#AARRGGBB 与常见颜色别名）
  Color? _parseColor(dynamic raw) => parseWorkspaceColor(raw);

  /// 将 Color 转为标准 #RRGGBB 十六进制字符串
  String _colorToHex(Color color) => workspaceColorToHex(color);

  /// 解析 ThemeMode（支持 system, light, dark 及其中文别名）
  ThemeMode _parseThemeMode(dynamic raw) => parseWorkspaceThemeMode(raw);

  /// 将 ThemeMode 转为字符串
  String _themeModeToString(ThemeMode mode) => workspaceThemeModeToString(mode);

  /// 解析背景预设（支持 system/light/dark/oled/accent/custom 及其中文别名）
  AppBackgroundPreset _parseBackgroundPreset(dynamic raw) => parseWorkspaceBackgroundPreset(raw);
}
