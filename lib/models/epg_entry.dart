import 'dart:convert';

class EpgEntry {
  final String title;
  final String description;
  final DateTime start;
  final DateTime end;

  const EpgEntry({
    required this.title,
    required this.description,
    required this.start,
    required this.end,
  });

  /// Devuelve una copia con los tiempos ajustados por [hours] horas (zona horaria)
  EpgEntry withOffset(int hours) => EpgEntry(
    title: title, description: description,
    start: start.add(Duration(hours: hours)),
    end:   end.add(Duration(hours: hours)),
  );

  /// Porcentaje de avance del programa actual (0.0 – 1.0)
  double get progress {
    final now = DateTime.now();
    if (now.isBefore(start)) return 0.0;
    if (now.isAfter(end))    return 1.0;
    final total   = end.difference(start).inSeconds;
    final elapsed = now.difference(start).inSeconds;
    return total > 0 ? (elapsed / total).clamp(0.0, 1.0) : 0.0;
  }

  String get timeRange =>
    '${_hm(start)} – ${_hm(end)}';

  String _hm(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  /// Los títulos en la API de Xtream vienen en base64
  static String _decode(String raw) {
    if (raw.isEmpty) return '';
    try { return utf8.decode(base64.decode(raw)); }
    catch (_) { return raw; }
  }

  factory EpgEntry.fromJson(Map<String, dynamic> j) {
    final startTs = int.tryParse(j['start_timestamp']?.toString() ?? '');
    final stopTs  = int.tryParse(j['stop_timestamp']?.toString()  ?? '');

    final start = (startTs != null && startTs > 0)
        ? DateTime.fromMillisecondsSinceEpoch(startTs * 1000)
        : _parseDateTime(j['start']?.toString() ?? '')
          ?? DateTime.now();

    final end = (stopTs != null && stopTs > 0)
        ? DateTime.fromMillisecondsSinceEpoch(stopTs * 1000)
        : _parseDateTime(j['end']?.toString() ?? j['stop']?.toString() ?? '')
          ?? DateTime.now().add(const Duration(hours: 1));

    return EpgEntry(
      title:       _decode(j['title']?.toString() ?? ''),
      description: _decode(j['description']?.toString() ?? ''),
      start: start,
      end: end,
    );
  }

  /// Parsea "2023-05-01 20:00:00" o "2023-05-01T20:00:00"
  static DateTime? _parseDateTime(String s) {
    if (s.isEmpty) return null;
    try { return DateTime.parse(s.contains('T') ? s : s.replaceFirst(' ', 'T')); }
    catch (_) { return null; }
  }
}
