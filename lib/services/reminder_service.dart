import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;
import '../models/epg_entry.dart';
import '../models/channel.dart';
import '../models/program_reminder.dart';

// flutter_local_notifications solo se importa en plataformas nativas (no web)
import 'reminder_service_native.dart'
    if (dart.library.js_interop) 'reminder_service_web_stub.dart'
    as _native;

class ReminderService {
  static const _kRemindersKey = 'program_reminders_v1';
  static bool _initialized = false;

  // ── Init ─────────────────────────────────────────────────────────────────

  static Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    if (!kIsWeb) {
      tz_data.initializeTimeZones();
      try {
        final offset = DateTime.now().timeZoneOffset;
        final hours  = offset.inHours;
        final sign   = hours >= 0 ? '+' : '';
        tz.setLocalLocation(tz.getLocation('UTC$sign$hours'));
      } catch (_) {
        tz.setLocalLocation(tz.UTC);
      }
      await _native.initNotifications();
    }

    await _pruneExpired();
  }

  // ── Schedule ─────────────────────────────────────────────────────────────

  /// On native: schedules a local notification.
  /// On web: saves the reminder to storage only (no push notification).
  static Future<bool> schedule({
    required EpgEntry  program,
    required Channel   channel,
    required int       minutesBefore,
  }) async {
    final fireAt = program.start.subtract(Duration(minutes: minutesBefore));
    if (fireAt.isBefore(DateTime.now())) return false;

    final id = _genId(channel.id, program.start);

    if (!kIsWeb) {
      await _native.scheduleNotification(
        id: id,
        channelName: channel.name,
        programTitle: program.title,
        minutesBefore: minutesBefore,
        fireAt: fireAt,
      );
    }

    // Always persist the reminder
    final reminders = await load();
    reminders.removeWhere((r) => r.notificationId == id);
    reminders.add(ProgramReminder(
      notificationId: id,
      streamId:       channel.id,
      channelName:    channel.name,
      programTitle:   program.title,
      programStart:   program.start,
      programEnd:     program.end,
      minutesBefore:  minutesBefore,
    ));
    await _save(reminders);
    return true;
  }

  // ── Cancel ───────────────────────────────────────────────────────────────

  static Future<void> cancel(int notificationId) async {
    if (!kIsWeb) await _native.cancelNotification(notificationId);
    final reminders = await load();
    reminders.removeWhere((r) => r.notificationId == notificationId);
    await _save(reminders);
  }

  static Future<void> cancelForProgram(String streamId, DateTime start) async {
    await cancel(_genId(streamId, start));
  }

  // ── Query ────────────────────────────────────────────────────────────────

  static Future<bool> hasReminder(String streamId, DateTime start) async {
    final id = _genId(streamId, start);
    final reminders = await load();
    return reminders.any((r) => r.notificationId == id);
  }

  static Future<List<ProgramReminder>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kRemindersKey) ?? '[]';
    final all = ProgramReminder.decodeList(raw);
    all.sort((a, b) => a.fireAt.compareTo(b.fireAt));
    return all;
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  static Future<void> _save(List<ProgramReminder> list) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRemindersKey, ProgramReminder.encodeList(list));
  }

  static Future<void> _pruneExpired() async {
    final all = await load();
    final active = all.where((r) => !r.isExpired).toList();
    if (active.length < all.length) await _save(active);
  }

  static int _genId(String streamId, DateTime start) =>
      (streamId + start.millisecondsSinceEpoch.toString()).hashCode.abs() % 99999 + 1;
}
