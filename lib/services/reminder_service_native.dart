// Native (Android/iOS) implementation — uses flutter_local_notifications
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;

final _plugin = FlutterLocalNotificationsPlugin();

Future<void> initNotifications() async {
  const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
  const initSettings = InitializationSettings(android: androidInit);
  await _plugin.initialize(initSettings);
  await _plugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.requestNotificationsPermission();
}

Future<void> scheduleNotification({
  required int id,
  required String channelName,
  required String programTitle,
  required int minutesBefore,
  required DateTime fireAt,
}) async {
  final whenLabel = minutesBefore == 0
      ? 'Inicia ahora'
      : minutesBefore == 1
          ? 'Inicia en 1 min'
          : 'Inicia en $minutesBefore min';

  await _plugin.zonedSchedule(
    id,
    '$whenLabel — $channelName',
    programTitle,
    tz.TZDateTime.from(fireAt, tz.local),
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'program_reminders',
        'Recordatorios de Programas',
        channelDescription: 'Alertas antes de que inicie un programa de TV',
        importance: Importance.high,
        priority: Priority.high,
        enableLights: true,
        icon: '@mipmap/ic_launcher',
        styleInformation: BigTextStyleInformation(''),
      ),
    ),
    androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
    uiLocalNotificationDateInterpretation:
        UILocalNotificationDateInterpretation.absoluteTime,
  );
}

Future<void> cancelNotification(int id) async {
  await _plugin.cancel(id);
}
