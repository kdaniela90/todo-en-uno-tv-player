import 'package:shared_preferences/shared_preferences.dart';
import 'xtream_service.dart';

/// Limpia todos los cachés de sesión una vez cada 24 horas.
/// Llamar en HubScreen.initState → devuelve true si se limpió.
class ContentRefreshService {
  static const _kLastRefresh = 'content_last_refresh_ms';
  static const _kIntervalHours = 24;

  /// Verifica si han pasado más de 24h desde el último refresh.
  /// Si es así, limpia los cachés y actualiza el timestamp.
  /// Devuelve true si se limpió (útil para mostrar snackbar).
  static Future<bool> checkAndRefresh() async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_kLastRefresh) ?? 0;
    final now    = DateTime.now().millisecondsSinceEpoch;
    final diff   = Duration(milliseconds: now - lastMs);

    if (diff.inHours >= _kIntervalHours) {
      XtreamService.clearAllCaches();
      await prefs.setInt(_kLastRefresh, now);
      return true;
    }
    return false;
  }

  /// Fuerza un refresh inmediato (igual que el botón manual del hub).
  static Future<void> forceRefresh() async {
    XtreamService.clearAllCaches();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kLastRefresh, DateTime.now().millisecondsSinceEpoch);
  }
}
