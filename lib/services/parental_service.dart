import 'package:shared_preferences/shared_preferences.dart';

class ParentalService {
  static const _keyPin     = 'parental_pin';
  static const _keyLive    = 'parental_blocked_live';
  static const _keyMovies  = 'parental_blocked_movies';
  static const _keySeries  = 'parental_blocked_series';

  static String _blockedKey(String type) {
    if (type == 'live')    return _keyLive;
    if (type == 'movies')  return _keyMovies;
    return _keySeries;
  }

  // ── PIN ──────────────────────────────────────────────────────
  static Future<bool> hasPin() async {
    final p = await SharedPreferences.getInstance();
    final pin = p.getString(_keyPin) ?? '';
    return pin.isNotEmpty;
  }

  static Future<void> setPin(String pin) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_keyPin, pin);
  }

  static Future<bool> checkPin(String pin) async {
    final p = await SharedPreferences.getInstance();
    return (p.getString(_keyPin) ?? '') == pin;
  }

  // ── Blocked categories ───────────────────────────────────────
  static Future<Set<String>> getBlocked(String type) async {
    final p = await SharedPreferences.getInstance();
    return (p.getStringList(_blockedKey(type)) ?? []).toSet();
  }

  static Future<bool> isBlocked(String type, String catId) async {
    final blocked = await getBlocked(type);
    return blocked.contains(catId);
  }

  static Future<void> setBlocked(String type, String catId, bool block) async {
    final p    = await SharedPreferences.getInstance();
    final set  = (p.getStringList(_blockedKey(type)) ?? []).toSet();
    if (block) set.add(catId); else set.remove(catId);
    await p.setStringList(_blockedKey(type), set.toList());
  }

  static Future<void> clearAll() async {
    final p = await SharedPreferences.getInstance();
    await p.remove(_keyPin);
    await p.remove(_keyLive);
    await p.remove(_keyMovies);
    await p.remove(_keySeries);
  }
}
