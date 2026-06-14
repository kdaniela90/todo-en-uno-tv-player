import 'package:shared_preferences/shared_preferences.dart';

class StorageService {
  static const _keyUsername = 'username';
  static const _keyPassword = 'password';
  static const _keyServer   = 'server';
  static const _keyExpDate  = 'exp_date';

  static Future<void> saveCredentials({
    required String username,
    required String password,
    required String server,
    String? expDate,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyUsername, username);
    await prefs.setString(_keyPassword, password);
    await prefs.setString(_keyServer, server);
    if (expDate != null) await prefs.setString(_keyExpDate, expDate);
  }

  static Future<Map<String, String>?> getCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    final u = prefs.getString(_keyUsername);
    final p = prefs.getString(_keyPassword);
    final s = prefs.getString(_keyServer);
    if (u == null || p == null || s == null) return null;
    return {'username': u, 'password': p, 'server': s, 'exp_date': prefs.getString(_keyExpDate) ?? ''};
  }

  static Future<void> clearCredentials() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyUsername);
    await prefs.remove(_keyPassword);
    await prefs.remove(_keyServer);
    await prefs.remove(_keyExpDate);
  }
}
