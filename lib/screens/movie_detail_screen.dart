import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/movie.dart';
import '../services/xtream_service.dart';
import '../services/history_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'player_screen.dart';

class MovieDetailScreen extends StatefulWidget {
  final Movie movie;
  final XtreamService service;
  const MovieDetailScreen({super.key, required this.movie, required this.service});
  @override State<MovieDetailScreen> createState() => _MovieDetailScreenState();
}

class _MovieDetailScreenState extends State<MovieDetailScreen> {
  Map<String, dynamic>? _info;
  bool _loading = true;
  bool _isFavorite = false;

  @override
  void initState() { super.initState(); _loadData(); }

  Future<void> _loadData() async {
    final results = await Future.wait([
      widget.service.getVodInfo(widget.movie.id),
      HistoryService.isFavorite(HistoryService.movies, widget.movie.id),
    ]);
    if (!mounted) return;
    setState(() {
      _info = results[0] as Map<String, dynamic>?;
      _isFavorite = results[1] as bool;
      _loading = false;
    });
  }

  Future<void> _toggleFavorite() async {
    final newState = await HistoryService.toggleFavorite(
      HistoryService.movies, widget.movie.id,
      {'id': widget.movie.id, 'name': widget.movie.name,
       'icon': widget.movie.streamIcon, 'ext': widget.movie.containerExtension});
    if (mounted) setState(() => _isFavorite = newState);
  }

  // Helpers para extraer info
  Map<String, dynamic> get _infoMap => (_info?['info'] as Map<String, dynamic>?) ?? {};
  String get _plot       => _infoMap['plot']?.toString() ?? widget.movie.plot;
  String get _cast       => _infoMap['cast']?.toString() ?? widget.movie.cast;
  String get _director   => _infoMap['director']?.toString() ?? '';
  String get _genre      => _infoMap['genre']?.toString() ?? widget.movie.genre;
  String get _release    => _infoMap['releaseDate']?.toString() ?? widget.movie.releaseDate;
  String get _duration   => _infoMap['duration']?.toString() ?? '';
  String get _rating     => _infoMap['rating']?.toString() ?? widget.movie.rating;
  String get _coverBig   => _infoMap['cover_big']?.toString() ?? widget.movie.streamIcon;

  List<String> get _backdropPaths {
    try {
      final raw = _infoMap['backdrop_path'];
      if (raw is List) return raw.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      if (raw is String && raw.isNotEmpty) return [raw];
    } catch (_) {}
    return [];
  }

  double get _stars {
    try { return double.parse(_rating).clamp(0, 10) / 2; } catch (_) { return 0; }
  }

  @override
  Widget build(BuildContext context) {
    final isPhone = R.isPhone(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      body: Stack(children: [
        // Fondo con backdrop borroso
        if (_backdropPaths.isNotEmpty)
          Opacity(opacity: 0.15,
            child: CachedNetworkImage(
              imageUrl: _backdropPaths.first,
              width: double.infinity, height: double.infinity, fit: BoxFit.cover)),

        SafeArea(child: Column(children: [
          // AppBar
          _DetailAppBar(
            title: widget.movie.name,
            isFavorite: _isFavorite,
            onBack: () => Navigator.pop(context),
            onFavorite: _toggleFavorite,
          ),

          // Contenido
          Expanded(child: _loading
            ? const Center(child: CircularProgressIndicator(color: AppColors.celeste))
            : SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: EdgeInsets.all(isPhone ? 14 : 24),
                child: isPhone
                  ? _mobileLayout(context)
                  : _tvLayout(context),
              )),
        ])),
      ]),
    );
  }

  // ── TV / Tablet: poster izq + info derecha ──────────────────────────────────
  Widget _tvLayout(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Poster
      _Poster(url: _coverBig, width: 200, height: 300),
      const SizedBox(width: 28),
      // Info
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(widget.movie.name,
          style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold)),
        const SizedBox(height: 10),
        _StarRating(stars: _stars, rating: _rating),
        const SizedBox(height: 14),
        _InfoGrid(director: _director, release: _release, duration: _duration, genre: _genre),
        const SizedBox(height: 14),
        if (_cast.isNotEmpty) _CastLine(cast: _cast),
        const SizedBox(height: 20),
        _PlayButton(onPlay: _play),
        const SizedBox(height: 20),
        if (_plot.isNotEmpty) _Synopsis(text: _plot),
        if (_backdropPaths.isNotEmpty) ...[
          const SizedBox(height: 20),
          _BackdropRow(paths: _backdropPaths),
        ],
      ])),
    ],
  );

  // ── Teléfono: apilado vertical ───────────────────────────────────────────────
  Widget _mobileLayout(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _Poster(url: _coverBig, width: 120, height: 180),
        const SizedBox(width: 14),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(widget.movie.name,
            style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          _StarRating(stars: _stars, rating: _rating),
          const SizedBox(height: 8),
          _InfoGrid(director: _director, release: _release, duration: _duration, genre: _genre, compact: true),
        ])),
      ]),
      const SizedBox(height: 16),
      _PlayButton(onPlay: _play),
      const SizedBox(height: 16),
      if (_cast.isNotEmpty) _CastLine(cast: _cast),
      if (_plot.isNotEmpty) ...[const SizedBox(height: 14), _Synopsis(text: _plot)],
      if (_backdropPaths.isNotEmpty) ...[const SizedBox(height: 16), _BackdropRow(paths: _backdropPaths)],
    ],
  );

  void _play() {
    HistoryService.addRecent(HistoryService.movies, {
      'id': widget.movie.id, 'name': widget.movie.name,
      'icon': widget.movie.streamIcon, 'ext': widget.movie.containerExtension,
    });
    Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(
      title: widget.movie.name,
      streamUrl: widget.service.vodStreamUrl(widget.movie.id, widget.movie.containerExtension))));
  }
}

// ─── AppBar con favorito ──────────────────────────────────────────────────────
class _DetailAppBar extends StatelessWidget {
  final String title;
  final bool isFavorite;
  final VoidCallback onBack, onFavorite;
  const _DetailAppBar({required this.title, required this.isFavorite,
    required this.onBack, required this.onFavorite});
  @override
  Widget build(BuildContext context) => Container(
    color: const Color(0xFF080B14),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        IconButton(icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 20), onPressed: onBack),
        Expanded(child: Text(title, style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600),
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
    child: const Icon(Icons.movie, color: AppColors.azul, size: 48));
}

// ─── Estrellas ────────────────────────────────────────────────────────────────
class _StarRating extends StatelessWidget {
  final double stars; final String rating;
  const _StarRating({required this.stars, required this.rating});
  @override Widget build(BuildContext context) => Row(children: [
    ...List.generate(5, (i) => Icon(
      i < stars.floor() ? Icons.star
        : (i < stars && stars % 1 >= 0.5 ? Icons.star_half : Icons.star_border),
      color: Colors.amber, size: 18)),
    const SizedBox(width: 6),
    if (rating.isNotEmpty) Text(rating, style: const TextStyle(color: Colors.white54, fontSize: 12)),
  ]);
}

// ─── Grid de info ─────────────────────────────────────────────────────────────
class _InfoGrid extends StatelessWidget {
  final String director, release, duration, genre;
  final bool compact;
  const _InfoGrid({required this.director, required this.release,
    required this.duration, required this.genre, this.compact = false});
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (director.isNotEmpty) _Row('Dirección', director, compact),
      if (release.isNotEmpty) _Row('Estreno', release, compact),
      if (duration.isNotEmpty) _Row('Duración', duration, compact),
      if (genre.isNotEmpty) _Row('Género', genre, compact),
    ]);
  Widget _Row(String label, String value, bool compact) => Padding(
    padding: EdgeInsets.symmetric(vertical: compact ? 3 : 5),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SizedBox(width: compact ? 70 : 90,
        child: Text('$label:', style: TextStyle(color: Colors.white54,
          fontSize: compact ? 11 : 13, fontWeight: FontWeight.w500))),
      Expanded(child: Text(value, style: TextStyle(color: Colors.white,
        fontSize: compact ? 11 : 13), maxLines: 2, overflow: TextOverflow.ellipsis)),
    ]));
}

// ─── Reparto ──────────────────────────────────────────────────────────────────
class _CastLine extends StatelessWidget {
  final String cast;
  const _CastLine({required this.cast});
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Reparto', style: TextStyle(color: AppColors.celeste,
      fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    const SizedBox(height: 6),
    Text(cast, style: const TextStyle(color: Colors.white70, fontSize: 13),
      maxLines: 3, overflow: TextOverflow.ellipsis),
  ]);
}

// ─── Sinopsis ─────────────────────────────────────────────────────────────────
class _Synopsis extends StatefulWidget {
  final String text;
  const _Synopsis({required this.text});
  @override State<_Synopsis> createState() => _SynopsisState();
}
class _SynopsisState extends State<_Synopsis> {
  bool _expanded = false;
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Sinopsis', style: TextStyle(color: AppColors.celeste,
      fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    const SizedBox(height: 6),
    Text(widget.text,
      style: const TextStyle(color: Colors.white70, fontSize: 13, height: 1.5),
      maxLines: _expanded ? null : 4, overflow: _expanded ? null : TextOverflow.ellipsis),
    if (widget.text.length > 200)
      GestureDetector(
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(padding: const EdgeInsets.only(top: 4),
          child: Text(_expanded ? 'Ver menos' : '...Leer más',
            style: const TextStyle(color: AppColors.celeste, fontSize: 12, fontWeight: FontWeight.bold)))),
  ]);
}

// ─── Botón Play ───────────────────────────────────────────────────────────────
class _PlayButton extends StatefulWidget {
  final VoidCallback onPlay;
  const _PlayButton({required this.onPlay});
  @override State<_PlayButton> createState() => _PlayButtonState();
}
class _PlayButtonState extends State<_PlayButton> {
  bool _focused = false;
  final _fn = FocusNode();
  @override void initState() {
    super.initState();
    _fn.addListener(() { if (mounted) setState(() => _focused = _fn.hasFocus); });
  }
  @override void dispose() { _fn.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => InkWell(
    focusNode: _fn, focusColor: Colors.transparent, onTap: widget.onPlay,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 14),
      decoration: BoxDecoration(
        gradient: AppColors.buttonGradient,
        borderRadius: BorderRadius.circular(12),
        boxShadow: _focused ? [BoxShadow(color: AppColors.celeste.withOpacity(0.5), blurRadius: 16)] : [],
        border: Border.all(color: _focused ? Colors.white : Colors.transparent, width: 2),
      ),
      child: const Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.play_arrow_rounded, color: Colors.white, size: 26),
        SizedBox(width: 8),
        Text('REPRODUCIR', style: TextStyle(color: Colors.white, fontSize: 14,
          fontWeight: FontWeight.bold, letterSpacing: 1.2)),
      ]),
    ));
}

// ─── Backdrops / Fotos ────────────────────────────────────────────────────────
class _BackdropRow extends StatelessWidget {
  final List<String> paths;
  const _BackdropRow({required this.paths});
  @override Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, children: [
    const Text('Imágenes', style: TextStyle(color: AppColors.celeste,
      fontSize: 13, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
    const SizedBox(height: 10),
    SizedBox(height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: paths.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) => ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: CachedNetworkImage(imageUrl: paths[i], width: 180, height: 110, fit: BoxFit.cover,
            placeholder: (_, __) => Container(width: 180, height: 110, color: AppColors.card),
            errorWidget: (_, __, ___) => Container(width: 180, height: 110, color: AppColors.card))),
      )),
  ]);
}
