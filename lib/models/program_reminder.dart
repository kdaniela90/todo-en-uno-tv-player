import 'dart:convert';

class ProgramReminder {
  final int      notificationId;
  final String   streamId;
  final String   channelName;
  final String   programTitle;
  final DateTime programStart;
  final DateTime programEnd;
  final int      minutesBefore; // 0 = at start, 5, 15, etc.

  const ProgramReminder({
    required this.notificationId,
    required this.streamId,
    required this.channelName,
    required this.programTitle,
    required this.programStart,
    required this.programEnd,
    required this.minutesBefore,
  });

  DateTime get fireAt =>
      programStart.subtract(Duration(minutes: minutesBefore));

  bool get isExpired => fireAt.isBefore(DateTime.now());
  bool get isProgramLive {
    final now = DateTime.now();
    return programStart.isBefore(now) && programEnd.isAfter(now);
  }

  Map<String, dynamic> toJson() => {
    'id':       notificationId,
    'sid':      streamId,
    'ch':       channelName,
    'prog':     programTitle,
    'start':    programStart.millisecondsSinceEpoch,
    'end':      programEnd.millisecondsSinceEpoch,
    'before':   minutesBefore,
  };

  factory ProgramReminder.fromJson(Map<String, dynamic> j) => ProgramReminder(
    notificationId: j['id'] as int,
    streamId:       j['sid'] as String,
    channelName:    j['ch']  as String,
    programTitle:   j['prog'] as String,
    programStart:   DateTime.fromMillisecondsSinceEpoch(j['start'] as int),
    programEnd:     DateTime.fromMillisecondsSinceEpoch(j['end']   as int),
    minutesBefore:  j['before'] as int,
  );

  static List<ProgramReminder> decodeList(String raw) {
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list.map((e) => ProgramReminder.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) { return []; }
  }

  static String encodeList(List<ProgramReminder> reminders) =>
      json.encode(reminders.map((r) => r.toJson()).toList());
}
