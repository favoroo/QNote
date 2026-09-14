import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:qnote_flutter/core/storage/todo_repository.dart';
import 'package:qnote_flutter/core/utils/reminder_utils.dart';
import 'package:qnote_flutter/models/todo.dart';
import 'package:timezone/data/latest.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

class NotificationService {
  static final NotificationService instance = NotificationService._internal();
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final TodoRepository _todoRepository = TodoRepository();
  Timer? _reminderTimer;
  final Set<String> _notifiedReminderIds = {};

  NotificationService._internal();

  Future<void> init() async {
    if (kIsWeb) return;
    tz.initializeTimeZones();
    _setupLocalTimeZone();
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings =
        InitializationSettings(android: androidSettings, iOS: iosSettings);
    await _plugin.initialize(settings);
    await requestPermission();
  }

  void _setupLocalTimeZone() {
    try {
      final offsetHours = DateTime.now().timeZoneOffset.inHours;
      String tzName = 'UTC';
      switch (offsetHours) {
        case 8:
          tzName = 'Asia/Shanghai';
          break;
        case 9:
          tzName = 'Asia/Tokyo';
          break;
        case 7:
          tzName = 'Asia/Bangkok';
          break;
        case 5:
          tzName = 'Asia/Karachi';
          break;
        case 6:
          tzName = 'Asia/Dhaka';
          break;
        case 3:
          tzName = 'Europe/Moscow';
          break;
        case 1:
          tzName = 'Europe/London';
          break;
        case 2:
          tzName = 'Europe/Paris';
          break;
        case 0:
          tzName = 'UTC';
          break;
        case -5:
          tzName = 'America/New_York';
          break;
        case -6:
          tzName = 'America/Chicago';
          break;
        case -7:
          tzName = 'America/Denver';
          break;
        case -8:
          tzName = 'America/Los_Angeles';
          break;
        default:
          final platformName = DateTime.now().timeZoneName;
          if (platformName.isNotEmpty) {
            tzName = platformName;
          }
      }
      tz.setLocalLocation(tz.getLocation(tzName));
    } catch (_) {
      try {
        tz.setLocalLocation(tz.getLocation('Asia/Shanghai'));
      } catch (_) {
        tz.setLocalLocation(tz.UTC);
      }
    }
  }

  Future<void> requestPermission() async {
    if (kIsWeb) return;
    try {
      final androidPlugin = _plugin.resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>();
      await androidPlugin?.requestNotificationsPermission();
      const channel = AndroidNotificationChannel(
        'qnote_channel',
        'QNote Notifications',
        description: 'Notifications from QNote app',
        importance: Importance.defaultImportance,
      );
      await androidPlugin?.createNotificationChannel(channel);
      const scheduledChannel = AndroidNotificationChannel(
        'qnote_scheduled',
        'QNote Scheduled',
        description: 'Scheduled notifications from QNote',
        importance: Importance.defaultImportance,
      );
      await androidPlugin?.createNotificationChannel(scheduledChannel);
    } catch (_) {}
    try {
      final iosPlugin = _plugin.resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin>();
      await iosPlugin?.requestPermissions(
        alert: true,
        badge: true,
        sound: true,
      );
    } catch (_) {}
  }

  void startReminderCheck() {
    if (kIsWeb) return;
    _reminderTimer?.cancel();
    _reminderTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      _checkReminders();
    });
  }

  void stopReminderCheck() {
    _reminderTimer?.cancel();
    _reminderTimer = null;
  }

  Future<void> _checkReminders() async {
    try {
      final todos = await _todoRepository.getUpcomingReminders();
      final now = DateTime.now();
      for (final todo in todos) {
        if (todo.reminderTime == null) continue;
        if (_notifiedReminderIds.contains(todo.id)) continue;
        final reminderTime = _parseReminderTime(todo.reminderTime!);
        if (reminderTime == null) continue;
        final difference = reminderTime.difference(now);
        // Match window of +/- 60 seconds relative to current polling cycle to handle timer drifts
        if (difference.inSeconds.abs() < 60) {
          await showNotification(
            id: todo.id.hashCode,
            title: '待办提醒',
            body: todo.title.isEmpty ? '新待办' : todo.title,
            payload: todo.id,
          );
          _notifiedReminderIds.add(todo.id);
        }
      }
    } catch (e) {
      // Avoid letting timer checks throw uncaught exceptions
    }
  }

  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
    String? payload,
  }) async {
    if (kIsWeb) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'qnote_channel',
        'QNote Notifications',
        channelDescription: 'Notifications from QNote app',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      const iosDetails = DarwinNotificationDetails();
      const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _plugin.show(id, title, body, details, payload: payload);
    } catch (_) {
      // Safe guard against native initialization/permission crashes
    }
  }

  Future<void> scheduleNotification({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
    String? payload,
  }) async {
    if (kIsWeb) return;
    try {
      const androidDetails = AndroidNotificationDetails(
        'qnote_scheduled',
        'QNote Scheduled',
        channelDescription: 'Scheduled notifications from QNote',
        importance: Importance.defaultImportance,
        priority: Priority.defaultPriority,
      );
      const iosDetails = DarwinNotificationDetails();
      const details = NotificationDetails(android: androidDetails, iOS: iosDetails);
      await _plugin.zonedSchedule(
        id,
        title,
        body,
        tz.TZDateTime.from(scheduledTime, tz.local),
        details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        uiLocalNotificationDateInterpretation:
            UILocalNotificationDateInterpretation.absoluteTime,
        payload: payload,
      );
    } catch (_) {
      // Safe guard against native exact alarms / permission SecurityExceptions on Android 13/14
    }
  }

  Future<void> cancelNotification(int id) async {
    if (kIsWeb) return;
    try {
      await _plugin.cancel(id);
    } catch (_) {}
  }

  Future<void> cancelAllNotifications() async {
    if (kIsWeb) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {}
  }

  Future<void> showDiaryReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    await scheduleNotification(
      id: id,
      title: title,
      body: body,
      scheduledTime: scheduledTime,
    );
  }

  Future<void> showTodoReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledTime,
  }) async {
    await scheduleNotification(
      id: id,
      title: title,
      body: body,
      scheduledTime: scheduledTime,
    );
  }

  Future<void> scheduleTodoReminder(Todo todo) async {
    if (kIsWeb) return;
    if (todo.reminderTime == null || todo.isCompleted || todo.isDeleted) {
      await cancelNotification(todo.id.hashCode);
      return;
    }
    final scheduledTime = _parseReminderTime(todo.reminderTime!);
    if (scheduledTime == null) return;

    if (scheduledTime.isAfter(DateTime.now())) {
      await showTodoReminder(
        id: todo.id.hashCode,
        title: '待办提醒',
        body: todo.title.isEmpty ? '新待办' : todo.title,
        scheduledTime: scheduledTime,
      );
    } else {
      await cancelNotification(todo.id.hashCode);
    }
  }

  /// 解析提醒时间；兼容 `MM-DD HH:mm`、`YYYY-MM-DD HH:mm` 等写法。
  DateTime? _parseReminderTime(String timeStr) => ReminderUtils.parse(timeStr);
}
