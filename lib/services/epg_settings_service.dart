import 'package:shared_preferences/shared_preferences.dart';
import 'xtream_service.dart';

/// Persiste el ajuste de zona horaria del EPG (offset en horas, -12..+12)
class EpgSettingsService {
  static const _kOffset = 'epg_offset_hours';
  static int _offset = 0;

  /// Llama una vez al iniciar la app
  static Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _offset = prefs.getInt(_kOffset) ?? 0;
  }

  static int get offsetHours => _offset;

  static Future<void> setOffset(int hours) async {
    _offset = hours.clamp(-12, 12);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kOffset, _offset);
    // Limpiar caché para que el nuevo offset se aplique al recargar
    XtreamService.clearEpgCache();
  }
}
