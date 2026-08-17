import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Shows local, on-device reminders.
///
/// On Android the reminder is scheduled with the OS so it fires even if the
/// app is closed or the device reboots. Linux's notification system has no
/// scheduler API, so there we fall back to an in-app timer that shows the
/// notification when the time arrives (the app must be running).
class ReminderService {
  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  int _nextId = 1000;

  Future<void> _ensureReady() async {
    if (_ready) return;
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (_) {
      // Rare fallback; reminders may be off by the UTC offset in this case.
      tz.setLocalLocation(tz.UTC);
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    const linux = LinuxInitializationSettings(defaultActionName: 'Open');
    await _plugin.initialize(
      settings: const InitializationSettings(android: android, linux: linux),
    );

    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    }
    _ready = true;
  }

  Future<void> scheduleReminder(DateTime when, String message) async {
    await _ensureReady();

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'reminders',
        'Reminders',
        channelDescription: 'Reminders you ask Nexus to set',
        importance: Importance.high,
        priority: Priority.high,
      ),
      linux: LinuxNotificationDetails(),
    );

    if (Platform.isAndroid) {
      final scheduled = tz.TZDateTime.from(when, tz.local);
      await _plugin.zonedSchedule(
        id: _nextId++,
        title: 'Nexus reminder',
        body: message,
        scheduledDate: scheduled,
        notificationDetails: details,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      );
    } else {
      var delay = when.difference(DateTime.now());
      if (delay.isNegative) delay = Duration.zero;
      Timer(
        delay,
        () => _plugin.show(
          id: _nextId++,
          title: 'Nexus reminder',
          body: message,
          notificationDetails: details,
        ),
      );
    }
  }
}
