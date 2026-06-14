import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class HistoryService {
  static const live    = 'live';
  static const movies  = 'movies';
  static const series  = 'series';

  // IDs de categorías virtuales
  static const favCatId    = '__favorites__';
  static const recentCatId = '__recent__';

  static String _recentKey(String type)  => 'recent_$type';
  static String _favIdsKey(String type)  => 'fav_ids_$type';
  static String _favMetaKey(String type) => 'fav_meta_$type';

  // ─── Recientes ──────────────────────────────────────────────────────────────
  /// item: {'id','name','icon'} — campos mínimos para reconstruir la tarjeta
  static Future<void> addRecent(String type, Map<String, String> item) async {
    final prefs = await SharedPreferences.getInstance();
    List<String> raw = prefs.getStringList(_recentKey(type)) ?? [];
    raw.removeWhere((e) {
      try { return (jsonDecode(e) as Map)['id'] == item['id']; } catch (_) { return false; }
    });
    raw.insert(0, jsonEncode(item));
    if (raw.length > 30) raw = raw.sublist(0, 30);
    await prefs.setStringList(_recentKey(type), raw);
  }

  static Future<List<Map<String, String>>> getRecent(String type) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_recentKey(type)) ?? [])
      .map<Map<String, String>>((e) {
        try { return Map<String, String>.from(jsonDecode(e) as Map); }
        catch (_) { return {}; }
      }).where((m) => m.isNotEmpty).toList();
  }

  // ─── Favoritos ──────────────────────────────────────────────────────────────
  static Future<bool> isFavorite(String type, String id) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_favIdsKey(type)) ?? []).contains(id);
  }

  /// Devuelve el nuevo estado (true = ahora es favorito)
  static Future<bool> toggleFavorite(
      String type, String id, Map<String, String> meta) async {
    final prefs = await SharedPreferences.getInstance();
    final ids  = prefs.getStringList(_favIdsKey(type)) ?? [];
    final metas = prefs.getStringList(_favMetaKey(type)) ?? [];

    final wasFav = ids.contains(id);
    if (wasFav) {
      ids.remove(id);
      metas.removeWhere((e) {
        try { return (jsonDecode(e) as Map)['id'] == id; } catch (_) { return false; }
      });
    } else {
      ids.add(id);
      metas.removeWhere((e) {
        try { return (jsonDecode(e) as Map)['id'] == id; } catch (_) { return false; }
      });
      metas.add(jsonEncode(meta));
    }

    await prefs.setStringList(_favIdsKey(type), ids);
    await prefs.setStringList(_favMetaKey(type), metas);
    return !wasFav;
  }

  static Future<List<Map<String, String>>> getFavorites(String type) async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_favMetaKey(type)) ?? [])
      .map<Map<String, String>>((e) {
        try { return Map<String, String>.from(jsonDecode(e) as Map); }
        catch (_) { return {}; }
      }).where((m) => m.isNotEmpty).toList();
  }
}
