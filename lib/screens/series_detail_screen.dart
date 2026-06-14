import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/series.dart';
import '../services/xtream_service.dart';
import '../services/history_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'player_screen.dart';

class SeriesDetailScreen extends StatefulWidget {
  final Series series;
  final XtreamService service;
  const SeriesDetailScreen({super.key, required this.series, required this.service});
  @override State<SeriesDetailScreen> createState() => _SeriesDetailScreenState();
}

class _SeriesDetailScreenState extends State<SeriesDetailScreen> {
  Map<String, dynamic>? _info;
  bool _loading = true;
  bool _isFavorite = false;
  // seasons: { "1": [ {episode}, ... ], "2": [...] }
  Map<String, List<Map<String, dynamic>>> _seasons = {};
  List<String> _seasonKeys = [];
  int _selectedSeason = 0;

  @override
  void initState() { super.initState(); _loadData(); }

  Future<void> _loadData() async {
    final results = await Future.wait([
      widget.service.getSeriesInfo(widget.series.id),
      HistoryService.isFavorite(HistoryService.series, widget.series.id),
    ]);
    if (!mounted) return;

    final raw = results[0] as Map<String, dynamic>?;
    final isFav = results[1] as bool;

    // Parse seasons/episodes
    final Map<String, List<Map<String, dynamic>>> seasons = {};
    if (raw != null) {
      final eps = raw['episodes'];
      if (eps is Map) {
        for (final key in eps.keys) {
          final list = eps[key];
          if (list is List) {
            seasons[key.toString()] = list.map<Map<String, dynamic>>((e) {
              if (e is Map) return Map<String, dynamic>.from(e);
              return {};
            }).where((e) => e.isNotEmpty).toList();
          }
        }
      }
    }

    // Sort season keys numerically
    final keys = seasons.keys.toList()
      ..sort((a, b) {
        final ai = int.tryParse(a) ?? 0;
        final bi = int.tryParse(b) ?? 0;
        return ai.compareTo(bi);
      });

    setState(() {
      _info = raw;
      _isFavorite = isFav;
      _seasons = seasons;
      _seasonKeys = keys;
      _loading = false;
    });
  }

  Future<void> _toggleFavorite() async {
    final newState = await HistoryService.toggleFavorite(
      HistoryService.series, widget.series.id,
      {'id': widget.series.id, 'name': widget.series.name, 'icon': widget.series.cover});
    if (mounted) setState(() => _isFavorite = newState);
  }

  Map<String, dynamic> get _infoMap =>
    (_info?['info'] as Map<String, dynamic>?) ?? {};

  String get _plot     => _infoMap['plot']?.toString() ?? '';
  String get _cast     => _infoMap['cast']?.toString() ?? '';
  String get _director => _infoMap['director']?.toString() ?? '';
  String get _genre    => _infoMap['genre']?.toString() ?? '';
  String get _release  => _infoMap['releaseDate']?.toString() ?? '';
  String get _rating   => _infoMap['rating']?.toString() ?? '';
  String get _cover    => _infoMap['cover_big']?.toString() ??
                          _infoMap['cover']?.toString() ??
                          widget.series.cover;

  List<Map<String, dynamic>> get _currentEpisodes =>
    _seasonKeys.isEmpty ? [] : (_seasons[_seasonKeys[_selectedSeason]] ?? []);

  void _playEpisode(Map<String, dynamic> ep) {
    final epId = ep['id']?.toString() ?? '';
    final ext  = ep['container_extension']?.toString() ?? 'mp4';
    final title = ep['title']?.toString() ??
                  'E${ep['episode_num']?.toString() ?? '?'}';
    if (epId.isEmpty) return;
    final url =
      '${widget.service.server}/series/${widget.service.username}/${widget.service.password}/$epId.$ext';
    Navigator.push(context, MaterialPageRoute(builder: (_) =>
      PlayerScreen(title: '${widget.series.name} · $title', streamUrl: url)));
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = R.isPhone(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(children: [
        // Fondo borroso con la portada
        if (_cover.isNotEmpty)
          Opacity(opacity: 0.12,
            child: CachedNetworkImage(imageUrl: _cover,
              width: double.infinity, height: double.infinity, fit: BoxFit.cover)),

        SafeArea(child: Column(children: [
          // AppBar
          _SeriesAppBar(
            title: widget.series.name,
            isFavorite: _isFavorite,
            onBack: () => Navigator.pop(context),
            onFavorite: _toggleFavorite,
          ),

          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.morado))
            : SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.all(isPhone ? 14 : 24),
                child: isPhone ? _mobileLayout(context) : _tvLayout(context),
              )),
        ])),
      ]),
    );
  }

  // ── TV: poster izq, info derecha, episodios debajo ──────────────────────────
  Widget _tvLayout(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Poster
        _Poster(url: _cover, width: 200, height: 300),
        const SizedBox(width: 28),
        // Info
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.series.name,
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          _StarRating(rating: _rating),
          const SizedBox(height: 14),
          _InfoGrid(director: _director, release: _release, genre: _genre),
          if (_cast.isNotEmpty) ...[const SizedBox(height: 12), _CastLine(cast: _cast)],
          if (_plot.isNotEmpty) ...[const SizedBox(height: 16), _Synopsis(text: _plot)],
        ])),
      ]),
      const SizedBox(height: 24),
      if (_seasonKeys.isNotEmpty) _SeasonsEpisodes(
        seasonKeys: _seasonKeys,
        selectedSeason: _selectedSeason,
        episodes: _currentEpisodes,
        onSeasonChanged: (i) => setState(() => _selectedSeason = i),
        onPlayEpisode: _playEpisode,
      ),
    ],
  );

  // ── Phone: vertical ─────────────────────────────────────────────────────────
  Widget _mobileLayout(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Poster(url: _cover, width: 110, height: 165),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.series.name,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _StarRating(rating: _rating),
          const SizedBox(height: 6),
          _InfoGrid(director: _director, release: _release, genre: _genre, compact: true),
        ])),
      ]),
      if (_cast.isNotEmpty) ...[const SizedBox(height: 14), _CastLine(cast: _cast)],
      if (_plot.isNotEmpty) ...[const SizedBox(height: 14), _Synopsis(text: _plot)],
      const SizedBox(height: 20),
      if (_seasonKeys.isNotEmpty) _SeasonsEpisodes(
        seasonKeys: _seasonKeys,
        selectedSeason: _selectedSeason,
        episodes: _currentEpisodes,
        onSeasonChanged: (i) => setState(() => _selectedSeason = i),
        onPlayEpisode: _playEpisode,
      ),
    ],
  );
}

// ─── AppBar ───────────────────────────────────────────────────────────────────
class _SeriesAppBar extends StatelessWidget {
  final String title;
  final bool isFavorite;
  final VoidCallback onBack, onFavorite;
  const _SeriesAppBar({required this.title, required this.isFavorite,
    required this.onBack, required this.onFavorite});

  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFF080B14),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 20),
          onPressed: onBack),
        Expanded(child: Text(title,
          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
          maxLines: 1, overflow: TextOverflow.ellipsis)),
        IconButton(
          icon: Icon(isFavorite ? Icons.favorite : Icons.favorite_border,
            color: isFavorite ? Colors.red : Colors.white54, size: 24),
          tooltip: isFavorite ? 'Quitar de favoritos' : 'Agregar a favoritos',
          onPressed: onFavorite),
      ]),
      const Divider(color: Colors.white10, height: 1),
    ]),
  );
}

// ─── Seasons + Episodes ───────────────────────────────────────────────────────
class _SeasonsEpisodes extends StatelessWidget {
  final List<String> seasonKeys;
  final int selectedSeason;
  final List<Map<String, dynamic>> episodes;
  final ValueChanged<int> onSeasonChanged;
  final ValueChanged<Map<String, dynamic>> onPlayEpisode;

  const _SeasonsEpisodes({
    required this.seasonKeys, required this.selectedSeason,
    required this.episodes, required this.onSeasonChanged,
    required this.onPlayEpisode});

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Season selector chips
      SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        child: Row(children: List.generate(seasonKeys.length, (i) {
          final sel = i == selectedSeason;
          return GestureDetector(
            onTap: () => onSeasonChanged(i),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: EdgeInsets.only(right: 8, bottom: 14,
                left: i == 0 ? 0 : 0),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: sel ? AppColors.morado : Colors.white12,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: sel ? AppColors.morado : Colors.white24, width: 1.5)),
              child: Text('Temporada ${seasonKeys[i]}',
                style: TextStyle(color: sel ? Colors.white : Colors.white60,
                  fontSize: 13, fontWeight: sel ? FontWeight.bold : FontWeight.normal)),
            ),
          );
        })),
      ),

      // Episodes list
      if (episodes.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Center(child: Text('Sin episodios',
            style: TextStyle(color: Colors.white38))))
      else
        ListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: episodes.length,
          itemBuilder: (_, i) => _EpisodeTile(
            episode: episodes[i],
            onPlay: () => onPlayEpisode(episodes[i]),
          ),
        ),
    ],
  );
}

class _EpisodeTile extends StatefulWidget {
  final Map<String, dynamic> episode;
  final VoidCallback onPlay;
  const _EpisodeTile({required this.episode, required this.onPlay});
  @override State<_EpisodeTile> createState() => _EpisodeTileState();
}
class _EpisodeTileState extends State<_EpisodeTile> {
  bool _focused = false;
  final _fn = FocusNode();

  @override void initState() {
    super.initState();
    _fn.addListener(() { if (mounted) setState(() => _focused = _fn.hasFocus); });
  }
  @override void dispose() { _fn.dispose(); super.dispose(); }

  Map<String, dynamic> get _epInfo =>
    (widget.episode['info'] as Map<String, dynamic>?) ?? {};

  String get _title {
    final t = widget.episode['title']?.toString() ?? '';
    final num = widget.episode['episode_num']?.toString() ?? '';
    return t.isNotEmpty ? t : 'Episodio $num';
  }
  String get _epNum => widget.episode['episode_num']?.toString() ?? '';
  String get _duration => _epInfo['duration']?.toString() ?? '';
  String get _plot => _epInfo['plot']?.toString() ?? '';
  String get _thumb => _epInfo['movie_image']?.toString() ??
                       _epInfo['cover_big']?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    final isPhone = R.isPhone(context);
    return InkWell(
      focusNode: _fn,
      focusColor: Colors.transparent,
      onTap: widget.onPlay,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.only(bottom: 8),
        padding: EdgeInsets.symmetric(
          horizontal: isPhone ? 10 : 14, vertical: isPhone ? 10 : 12),
        decoration: BoxDecoration(
          color: _focused ? Colors.white10 : const Color(0xFF0D1020),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _focused ? AppColors.morado : Colors.white12,
            width: _focused ? 2 : 1)),
        child: Row(children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: _thumb.isNotEmpty
              ? CachedNetworkImage(imageUrl: _thumb, width: 100, height: 60, fit: BoxFit.cover,
                  placeholder: (_, __) => _phBox(),
                  errorWidget: (_, __, ___) => _phBox())
              : _phBox()),
          SizedBox(width: isPhone ? 10 : 14),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (_epNum.isNotEmpty) Container(
                margin: const EdgeInsets.only(right: 8),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.morado.withOpacity(0.3),
                  borderRadius: BorderRadius.circular(4)),
                child: Text('E$_epNum', style: const TextStyle(
                  color: AppColors.morado, fontSize: 10, fontWeight: FontWeight.bold))),
              Expanded(child: Text(_title,
                style: TextStyle(color: _focused ? Colors.white : Colors.white.withOpacity(0.87),
                  fontSize: R.fs(context, 13), fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
            if (_duration.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(_duration, style: const TextStyle(color: Colors.white38, fontSize: 11)),
            ],
            if (_plot.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(_plot, style: const TextStyle(color: Colors.white54, fontSize: 12),
                maxLines: 2, overflow: TextOverflow.ellipsis),
            ],
          ])),
          const SizedBox(width: 8),
          Icon(Icons.play_circle_outline,
            color: _focused ? AppColors.morado : Colors.white30,
            size: isPhone ? 28 : 34),
        ]),
      ),
    );
  }

  Widget _phBox() => Container(width: 100, height: 60, color: AppColors.card,
    child: const Icon(Icons.tv, color: AppColors.morado, size: 20));
}

// ─── Poster ───────────────────────────────────────────────────────────────────
class _Poster extends StatelessWidget {
  final String url; final double width, height;
  const _Poster({required this.url, required this.width, required this.height});
  @override Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(12),
    child: url.isNotEmpty
      ? CachedNetworkImage(imageUrl: url, width: width, height: height, fit: BoxFit.cover,
          placeholder: (_, __) => _box(), errorWidget: (_, __, ___) => _box())
      : _box());
  Widget _box() => Container(width: width, height: height, color: AppColors.card,
    child: const Icon(Icons.tv_outlined, color: AppColors.morado, size: 48));
}

// ─── Star rating ─────────────────────────────────────────────────────────────
class _StarRating extends StatelessWidget {
  final String rating;
  const _StarRating({required this.rating});
  @override Widget build(BuildContext context) {
    double stars = 0;
    try { stars = double.parse(rating).clamp(0, 10) / 2; } catch (_) {}
    return Row(children: [
      ...List.generate(5, (i) => Icon(
        i < stars.floor() ? Icons.star
          : (i < stars && stars % 1 >= 0.5 ? Icons.star_half : Icons.star_border),
        color: Colors.amber, size: 16)),
      const SizedBox(width: 6),
      if (rating.isNotEmpty) Text(rating,
        style: const TextStyle(color: Colors.white54, fontSize: 12)),
    ]);
  }
}

// ─── Info grid ────────────────────────────────────────────────────────────────
class _InfoGrid extends StatelessWidget {
  final String director, release, genre;
  final bool compact;
  const _InfoGrid({required this.director, required this.release,
    required this.genre, this.compact = false});

  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (director.isNotEmpty) _Row('Dirección', director, compact),
      if (release.isNotEmpty)  _Row('Estreno',  release, compact),
      if (genre.isNotEmpty)    _Row('Género',   genre, compact),
    ]);

  Widget _Row(String label, String value, bool compact) => Padding(
    padding: EdgeInsets.symmetric(vertical: compact ? 2 : 4),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: compact ? 70 : 85,
        child: Text('$label:', style: TextStyle(
          color: Colors.white54, fontSize: compact ? 11 : 13,
          fontWeight: FontWeight.w500))),
      Expanded(child: Text(value,
        style: TextStyle(color: Colors.white, fontSize: compact ? 11 : 13),
        maxLines: 2, overflow: TextOverflow.ellipsis)),
    ]));
}

// ─── Cast ─────────────────────────────────────────────────────────────────────
class _CastLine extends StatelessWidget {
  final String cast;
  const _CastLine({required this.cast});
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Reparto', style: TextStyle(color: AppColors.morado,
      fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    const SizedBox(height: 6),
    Text(cast, style: const TextStyle(color: Colors.white70, fontSize: 13),
      maxLines: 3, overflow: TextOverflow.ellipsis),
  ]);
}

// ─── Synopsis ─────────────────────────────────────────────────────────────────
class _Synopsis extends StatefulWidget {
  final String text;
  const _Synopsis({required this.text});
  @override State<_Synopsis> createState() => _SynopsisState();
}
class _SynopsisState extends State<_Synopsis> {
  bool _expanded = false;
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Sinopsis', style: TextStyle(color: AppColors.morado,
      fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    const SizedBox(height: 6),
    Text(widget.text,
      style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
      maxLines: _expanded ? null : 4,
      overflow: _expanded ? null : TextOverflow.ellipsis),
    if (widget.text.length > 200)
      GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(_expanded ? 'Ver menos' : '...Leer más',
            style: const TextStyle(color: AppColors.morado,
              fontSize: 12, fontWeight: FontWeight.bold)))),
  ]);
}
