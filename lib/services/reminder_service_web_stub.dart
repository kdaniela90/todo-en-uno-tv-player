// Web stub — flutter_local_notifications no está disponible en web.
// Los recordatorios se guardan en storage pero no generan notificaciones push.

Future<void> initNotifications() async {}

Future<void> scheduleNotification({
  required int id,
  required String channelName,
  required String programTitle,
  required int minutesBefore,
  required DateTime fireAt,
}) async {
  // No-op en web: el recordatorio se persiste en SharedPreferences
  // pero no se puede programar una notificación local nativa.
}

Future<void> cancelNotification(int id) async {}
