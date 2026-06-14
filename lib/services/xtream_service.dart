import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/category.dart';
import '../models/channel.dart';
import '../models/epg_entry.dart';
import '../models/movie.dart';
import '../models/series.dart';
import 'epg_settings_service.dart';

class XtreamService {
  final String server;
  final String username;
  final String password;

  XtreamService({required this.server, required this.username, required this.password});

  String get _base => '$server/player_api.php?username=$username&password=$password';

  Future<Map<String, dynamic>?> login() async {
    try {
      final response = await http.get(Uri.parse(_base)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return json.decode(response.body);
    } catch (_) {}
    return null;
  }

  Future<List<Category>> getLiveCategories() => _fetchCategories('get_live_categories');
  Future<List<Category>> getMovieCategories() => _fetchCategories('get_vod_categories');
  Future<List<Category>> getSeriesCategories() => _fetchCategories('get_series_categories');

  Future<List<Category>> _fetchCategories(String action) async {
    try {
      final response = await http.get(Uri.parse('$_base&action=$action')).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map((e) => Category.fromJson(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<List<Channel>> getLiveStreams({String? categoryId}) async {
    try {
      String url = '$_base&action=get_live_streams';
      if (categoryId != null) url += '&category_id=$categoryId';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map((e) => Channel.fromJson(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<List<Movie>> getMovies({String? categoryId}) async {
    try {
      String url = '$_base&action=get_vod_streams';
      if (categoryId != null) url += '&category_id=$categoryId';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map((e) => Movie.fromJson(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  Future<List<Series>> getSeries({String? categoryId}) async {
    try {
      String url = '$_base&action=get_series';
      if (categoryId != null) url += '&category_id=$categoryId';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 20));
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        return data.map((e) => Series.fromJson(e)).toList();
      }
    } catch (_) {}
    return [];
  }

  // Alias so movies_screen can call getVodCategories()
  Future<List<Category>> getVodCategories() => getMovieCategories();

  String liveStreamUrl(String streamId) => '$server/live/$username/$password/$streamId.ts';
  String vodStreamUrl(String streamId, String ext) => '$server/movie/$username/$password/$streamId.$ext';
  String movieStreamUrl(String streamId, String ext) => vodStreamUrl(streamId, ext);

  // ── Cast index (session cache) ───────────────────────────────────────────
  // Poblado cada vez que se llama getVodInfo (al abrir detalle de película)
  static final Map<String, String> _castIndex = {};

  /// Devuelve el cast de una película si ya fue cargado antes.
  static String cachedCast(String movieId) => _castIndex[movieId] ?? '';

  Future<Map<String, dynamic>?> getVodInfo(String streamId) async {
    try {
      final url = '$_base&action=get_vod_info&vod_id=$streamId';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        // Indexar cast para búsquedas futuras
        final cast = data['info']?['cast']?.toString() ??
                     data['movie_data']?['cast']?.toString() ?? '';
        if (cast.isNotEmpty) _castIndex[streamId] = cast;
        return data;
      }
    } catch (_) {}
    return null;
  }

  /// Pre-carga vod_info de una lista de películas en background (para el buscador).
  /// [onProgress] recibe (cargadas, total).
  Future<void> prefetchCast(
    List<Movie> movies, {
    void Function(int done, int total)? onProgress,
  }) async {
    final pending = movies.where((m) => !_castIndex.containsKey(m.id)).toList();
    int done = 0;
    const batchSize = 15;
    for (int i = 0; i < pending.length; i += batchSize) {
      final batch = pending.sublist(i, (i + batchSize).clamp(0, pending.length));
      await Future.wait(batch.map((m) async {
        try {
          final url = '$_base&action=get_vod_info&vod_id=${m.id}';
          final res = await http.get(Uri.parse(url))
              .timeout(const Duration(seconds: 10));
          if (res.statusCode == 200) {
            final data = json.decode(res.body) as Map<String, dynamic>;
            final cast = data['info']?['cast']?.toString() ??
                         data['movie_data']?['cast']?.toString() ?? '';
            _castIndex[m.id] = cast; // guarda aunque esté vacío para no re-intentar
          }
        } catch (_) {}
      }));
      done += batch.length;
      onProgress?.call(done, pending.length);
      await Future.delayed(const Duration(milliseconds: 80));
    }
  }

  // ── EPG ─────────────────────────────────────────────────────────────────────
  // Cache de sesión: evita llamadas repetidas al mismo canal
  static final Map<String, List<EpgEntry>> _epgCache = {};

  Future<List<EpgEntry>> getShortEpg(String streamId) async {
    if (_epgCache.containsKey(streamId)) return _epgCache[streamId]!;
    try {
      final url = '$_base&action=get_short_epg&stream_id=$streamId&limit=4';
      final res = await http.get(Uri.parse(url))
        .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final body = json.decode(res.body) as Map<String, dynamic>;
        final raw  = body['epg_listings'];
        if (raw is List && raw.isNotEmpty) {
          final offset = EpgSettingsService.offsetHours;
          final entries = raw
            .map((e) => EpgEntry.fromJson(e as Map<String, dynamic>)
                .withOffset(offset))
            .toList();
          _epgCache[streamId] = entries;
          return entries;
        }
      }
    } catch (_) {}
    _epgCache[streamId] = [];
    return [];
  }

  /// Limpia el cache EPG completo
  static void clearEpgCache() => _epgCache.clear();

  /// Limpia todos los cachés de sesión (EPG + cast index).
  static void clearAllCaches() { _epgCache.clear(); _castIndex.clear(); }

  /// Limpia el cache de un canal específico (para auto-refresh al terminar programa)
  static void clearEpgCacheForChannel(String streamId) => _epgCache.remove(streamId);

  /// Busca en el EPG ya cacheado. Devuelve pares (streamId, EpgEntry).
  /// Solo busca en canales cuyo EPG ya fue descargado.
  static List<({String streamId, EpgEntry entry})> searchEpgCache(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return [];
    final results = <({String streamId, EpgEntry entry})>[];
    for (final kv in _epgCache.entries) {
      for (final e in kv.value) {
        if (e.title.toLowerCase().contains(q) ||
            e.description.toLowerCase().contains(q)) {
          results.add((streamId: kv.key, entry: e));
        }
      }
    }
    // Ordenar por hora de inicio
    results.sort((a, b) => a.entry.start.compareTo(b.entry.start));
    return results;
  }

  Future<Map<String, dynamic>?> getSeriesInfo(String seriesId) async {
    try {
      final url = '$_base&action=get_series_info&series_id=$seriesId';
      final response = await http.get(Uri.parse(url)).timeout(const Duration(seconds: 15));
      if (response.statusCode == 200) return json.decode(response.body);
    } catch (_) {}
    return null;
  }
}
