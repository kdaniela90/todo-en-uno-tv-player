import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:chewie/chewie.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel.dart';
import '../services/xtream_service.dart';
import '../services/web_tracks.dart';
import '../theme/app_theme.dart';
import '../widgets/hls_player.dart';

// TV D-pad seek amount
const _kSeekSecs = 10;

class PlayerScreen extends StatefulWidget {
  final String title;
  final String streamUrl;
  final String? epgTitle;
  final List<Channel>? channels;
  final int? channelIndex;
  final XtreamService? service;

  const PlayerScreen({
    super.key,
    required this.title,
    required this.streamUrl,
    this.epgTitle,
    this.channels,
    this.channelIndex,
    this.service,
  });

  @override State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _videoController; // null en web
  ChewieController? _chewieController;
  bool _hasError  = false;
  bool _showBar   = true;
  bool _webReady  = false; // true cuando HLS.js confirma que el stream está listo
  Timer? _hideTimer;

  // Canal actual
  late String _title;
  late String _streamUrl;
  String? _epgTitle;
  late int _chanIdx;

  // Banner de zapping
  bool _showBanner = false;
  Timer? _bannerTimer;
  Channel? _bannerChannel;

  // Pistas de subtítulos (solo en web)
  List<Map<String, dynamic>> _subtitleTracks = [];
  int _selectedSubtitleIdx = -1; // -1 = ninguno
  bool _hasSubtitles = false;
  Timer? _trackLoadTimer;

  bool get _canZap =>
    widget.channels != null &&
    widget.channels!.isNotEmpty &&
    widget.service != null;

  @override
  void initState() {
    super.initState();
    _title     = widget.title;
    _streamUrl = widget.streamUrl;
    _epgTitle  = widget.epgTitle;
    _chanIdx   = widget.channelIndex ?? 0;
    if (!kIsWeb) {
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
    WakelockPlus.enable();
    _initPlayer();
  }

  Future<void> _initPlayer() async {
    if (kIsWeb) {
      // En web: HlsPlayer maneja la reproducción vía HLS.js.
      // Reseteamos flags para que el widget se reconstruya con la nueva URL.
      if (mounted) setState(() { _hasError = false; _webReady = false; });
      return;
    }

    // ── Plataformas nativas (Android / TV) ──────────────────────────────────
    _videoController = VideoPlayerController.networkUrl(
      Uri.parse(_streamUrl),
      httpHeaders: {'User-Agent': 'Mozilla/5.0', 'Connection': 'keep-alive'},
    );
    try {
      await _videoController!.initialize();
      _chewieController = ChewieController(
        videoPlayerController: _videoController!,
        autoPlay: true,
        looping: false,
        allowFullScreen: true,
        allowMuting: true,
        showControlsOnInitialize: true,
        allowedScreenSleep: false,
        materialProgressColors: ChewieProgressColors(
          playedColor: AppColors.celeste,
          handleColor: AppColors.gradStart,
          bufferedColor: Colors.white30,
          backgroundColor: Colors.white12,
        ),
      );
      if (mounted) {
        setState(() {});
        _startHideTimer();
        _scheduleTrackLoad(); // intentar cargar pistas después de 2 s
      }
    } catch (e) {
      if (mounted) setState(() => _hasError = true);
    }
  }

  // ── Carga de pistas de subtítulos (web via textTracks API) ───────────────
  void _scheduleTrackLoad() {
    _trackLoadTimer?.cancel();
    _trackLoadTimer = Timer(const Duration(seconds: 2), _loadTracks);
  }

  void _loadTracks() {
    if (!mounted) return;
    final tracks = WebTracks.getTextTracks();
    setState(() {
      _subtitleTracks = tracks;
      _hasSubtitles   = tracks.isNotEmpty;
    });
    // Reintentar en 3 s si no hay nada aún (el stream puede tardar en cargar)
    if (tracks.isEmpty && (_chewieController != null)) {
      _trackLoadTimer = Timer(const Duration(seconds: 3), _loadTracks);
    }
  }

  void _openTrackSelector() {
    _loadTracks(); // refrescar antes de abrir
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0D1020),
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _TrackSelectorSheet(
        subtitleTracks: _subtitleTracks,
        selectedIdx: _selectedSubtitleIdx,
        onSubtitleSelected: (idx) {
          setState(() => _selectedSubtitleIdx = idx);
          if (idx == -1) {
            WebTracks.disableAllTextTracks();
          } else {
            WebTracks.enableTextTrack(idx);
          }
          Navigator.pop(context);
        },
      ),
    );
  }

  // ── Zapping ──────────────────────────────────────────────────────────────
  void _switchChannel(int delta) {
    if (!_canZap) return;
    final channels = widget.channels!;
    final newIdx = (_chanIdx + delta).clamp(0, channels.length - 1);
    if (newIdx == _chanIdx) return;

    final ch = channels[newIdx];
    setState(() {
      _chanIdx          = newIdx;
      _title            = ch.name;
      _streamUrl        = widget.service!.liveStreamUrl(ch.id);
      _epgTitle         = null;
      _hasError         = false;
      _showBanner       = true;
      _bannerChannel    = ch;
      _subtitleTracks   = [];
      _hasSubtitles     = false;
      _selectedSubtitleIdx = -1;
    });

    _hideTimer?.cancel();
    _trackLoadTimer?.cancel();
    if (!kIsWeb) {
      _chewieController?.dispose();
      _chewieController = null;
      _videoController?.dispose();
      _videoController = null;
    }
    _initPlayer();

    widget.service!.getShortEpg(ch.id).then((epg) {
      if (!mounted || epg.isEmpty) return;
      final now = DateTime.now();
      try {
        final cur = epg.firstWhere(
          (e) => e.start.isBefore(now) && e.end.isAfter(now),
          orElse: () => epg.first);
        if (mounted) setState(() => _epgTitle = cur.title);
      } catch (_) {}
    });

    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _showBanner = false);
    });
  }

  void _startHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => _showBar = false);
    });
  }

  void _onTapScreen() {
    setState(() => _showBar = true);
    _startHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _bannerTimer?.cancel();
    _trackLoadTimer?.cancel();
    WakelockPlus.disable();
    if (!kIsWeb) {
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    _chewieController?.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  // D-pad / keyboard handling
  KeyEventResult _onKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.channelUp) {
      _switchChannel(-1); return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown ||
        event.logicalKey == LogicalKeyboardKey.channelDown) {
      _switchChannel(1); return KeyEventResult.handled;
    }
    if (_videoController == null || _videoController!.value.duration == Duration.zero) {
      return KeyEventResult.ignored;
    }
    final pos = _videoController!.value.position;
    final dur = _videoController!.value.duration;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
        event.logicalKey == LogicalKeyboardKey.mediaFastForward) {
      final next = pos + const Duration(seconds: _kSeekSecs);
      _videoController!.seekTo(next < dur ? next : dur);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
        event.logicalKey == LogicalKeyboardKey.mediaRewind) {
      final prev = pos - const Duration(seconds: _kSeekSecs);
      _videoController!.seekTo(prev > Duration.zero ? prev : Duration.zero);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.space) {
      _videoController!.value.isPlaying
          ? _videoController!.pause()
          : _videoController!.play();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) => Focus(
    autofocus: true,
    onKeyEvent: _onKey,
    child: Scaffold(
      backgroundColor: Colors.black,
      body: Stack(children: [
        // ── Reproductor ──────────────────────────────────────────────────
        if (_hasError)
          _buildError()
        else if (kIsWeb)
          _buildWebPlayer()
        else if (_chewieController == null)
          const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(color: AppColors.celeste),
            SizedBox(height: 16),
            Text('Cargando stream...', style: TextStyle(color: Colors.white54)),
          ]))
        else
          Stack(children: [
            Chewie(controller: _chewieController!),
            // Zona tap para mostrar barra superior (parte superior del video)
            Positioned(
              top: 0, left: 0, right: 0,
              height: MediaQuery.of(context).size.height * 0.65,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _onTapScreen,
                child: const SizedBox.expand(),
              ),
            ),
          ]),

        // ── Barra superior con gear icon ─────────────────────────────────
        if (!_hasError)
          AnimatedPositioned(
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            top: _showBar ? 0 : -100,
            left: 0, right: 0,
            child: _TopBar(
              title: _title,
              epgTitle: _epgTitle,
              hasSubtitles: _hasSubtitles,
              onBack: () => Navigator.pop(context),
              onSettings: _openTrackSelector,
            ),
          ),

        // ── Banner de zapping ────────────────────────────────────────────
        if (_canZap && _showBanner && _bannerChannel != null)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: _ChannelBanner(
              channel: _bannerChannel!,
              epgTitle: _epgTitle,
              index: _chanIdx + 1,
              total: widget.channels!.length,
            ),
          ),
      ]),
    ),
  );

  // ── Player web con HLS.js ────────────────────────────────────────────────
  Widget _buildWebPlayer() => Stack(children: [
    // HlsPlayer ocupa toda la pantalla y llama onReady/onError desde JS
    HlsPlayer(
      url: _streamUrl,
      onReady: () {
        if (!mounted) return;
        setState(() => _webReady = true);
        _startHideTimer();
      },
      onError: () {
        if (!mounted) return;
        setState(() => _hasError = true);
      },
    ),
    // Spinner mientras HLS.js no confirma que el stream está listo
    if (!_webReady)
      const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: AppColors.celeste),
        SizedBox(height: 16),
        Text('Cargando stream...', style: TextStyle(color: Colors.white54)),
      ])),
    // Zona tap para mostrar la barra superior
    Positioned(
      top: 0, left: 0, right: 0,
      height: double.infinity,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _onTapScreen,
        child: const SizedBox.expand(),
      ),
    ),
  ]);

  Widget _buildError() => Center(child: Column(
    mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.error_outline, color: Colors.red, size: 60),
    const SizedBox(height: 16),
    const Text('No se pudo reproducir el stream',
      style: TextStyle(color: Colors.white, fontSize: 16)),
    const SizedBox(height: 8),
    const Text('Verifica tu conexión o intenta con otro canal',
      style: TextStyle(color: Colors.white54, fontSize: 13)),
    const SizedBox(height: 24),
    ElevatedButton.icon(
      onPressed: () { setState(() => _hasError = false); _initPlayer(); },
      icon: const Icon(Icons.refresh), label: const Text('Reintentar'),
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.celeste,
        foregroundColor: Colors.white,
      )),
  ]));
}

// ─── Selector de pistas ───────────────────────────────────────────────────────
class _TrackSelectorSheet extends StatelessWidget {
  final List<Map<String, dynamic>> subtitleTracks;
  final int selectedIdx;
  final void Function(int idx) onSubtitleSelected;

  const _TrackSelectorSheet({
    required this.subtitleTracks,
    required this.selectedIdx,
    required this.onSubtitleSelected,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          // Handle
          Container(width: 36, height: 4,
            decoration: BoxDecoration(
              color: Colors.white24,
              borderRadius: BorderRadius.circular(2))),
          const SizedBox(height: 16),

          // Título
          Row(children: [
            const Icon(Icons.subtitles_outlined, color: AppColors.celeste, size: 20),
            const SizedBox(width: 10),
            const Text('Subtítulos',
              style: TextStyle(color: Colors.white, fontSize: 16,
                fontWeight: FontWeight.bold)),
          ]),
          const SizedBox(height: 4),
          const Text(
            'Las pistas disponibles dependen del stream. '
            'La selección de audio no está disponible en la versión web.',
            style: TextStyle(color: Colors.white38, fontSize: 11),
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white12),

          if (subtitleTracks.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.info_outline, color: Colors.white24, size: 36),
                SizedBox(height: 10),
                Text('Este stream no incluye pistas de subtítulos.',
                  style: TextStyle(color: Colors.white38, fontSize: 13),
                  textAlign: TextAlign.center),
              ]),
            )
          else ...[
            // Opción "Sin subtítulos"
            _TrackTile(
              label: 'Sin subtítulos',
              language: '',
              isSelected: selectedIdx == -1,
              onTap: () => onSubtitleSelected(-1),
            ),
            // Pistas encontradas
            ...subtitleTracks.map((t) => _TrackTile(
              label: t['label'] as String,
              language: t['language'] as String,
              isSelected: selectedIdx == (t['index'] as int),
              onTap: () => onSubtitleSelected(t['index'] as int),
            )),
          ],
        ]),
      ),
    );
  }
}

class _TrackTile extends StatelessWidget {
  final String label;
  final String language;
  final bool isSelected;
  final VoidCallback onTap;

  const _TrackTile({
    required this.label, required this.language,
    required this.isSelected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    leading: Icon(
      isSelected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
      color: isSelected ? AppColors.celeste : Colors.white38, size: 20),
    title: Text(label,
      style: TextStyle(
        color: isSelected ? AppColors.celeste : Colors.white,
        fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
        fontSize: 14)),
    trailing: language.isNotEmpty
      ? Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(6)),
          child: Text(language,
            style: const TextStyle(color: Colors.white54, fontSize: 11)))
      : null,
    onTap: onTap,
  );
}

// ─── Banner de zapping ────────────────────────────────────────────────────────
class _ChannelBanner extends StatelessWidget {
  final Channel channel;
  final String? epgTitle;
  final int index;
  final int total;

  const _ChannelBanner({
    required this.channel, required this.epgTitle,
    required this.index, required this.total,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.bottomCenter, end: Alignment.topCenter,
        colors: [Color(0xEE000000), Colors.transparent])),
    padding: const EdgeInsets.fromLTRB(20, 32, 20, 20),
    child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: channel.streamIcon.isNotEmpty
          ? CachedNetworkImage(
              imageUrl: channel.streamIcon,
              width: 60, height: 45, fit: BoxFit.contain,
              errorWidget: (_, __, ___) => _iconBox())
          : _iconBox(),
      ),
      const SizedBox(width: 16),
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Text('$index/$total',
              style: const TextStyle(color: AppColors.celeste, fontSize: 12,
                fontWeight: FontWeight.bold, letterSpacing: 0.5)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.red.withOpacity(0.2),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.red.withOpacity(0.6))),
              child: const Text('● EN VIVO',
                style: TextStyle(color: Colors.red, fontSize: 9,
                  fontWeight: FontWeight.bold))),
          ]),
          const SizedBox(height: 4),
          Text(channel.name,
            style: const TextStyle(color: Colors.white, fontSize: 20,
              fontWeight: FontWeight.bold,
              shadows: [Shadow(color: Colors.black87, blurRadius: 6)]),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          if (epgTitle != null && epgTitle!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Row(children: [
              const Icon(Icons.tv, color: AppColors.celeste, size: 13),
              const SizedBox(width: 5),
              Expanded(child: Text(epgTitle!,
                style: const TextStyle(color: AppColors.celeste, fontSize: 13),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ] else
            const Text('Cargando programa...',
              style: TextStyle(color: Colors.white38, fontSize: 12)),
        ],
      )),
    ]),
  );

  Widget _iconBox() => Container(
    width: 60, height: 45,
    decoration: BoxDecoration(
      color: const Color(0xFF0D1020),
      borderRadius: BorderRadius.circular(8)),
    child: const Icon(Icons.tv, color: AppColors.celeste, size: 24));
}

// ─── Top bar con gear icon ────────────────────────────────────────────────────
class _TopBar extends StatelessWidget {
  final String title;
  final String? epgTitle;
  final VoidCallback onBack;
  final VoidCallback? onSettings;
  final bool hasSubtitles;

  const _TopBar({
    required this.title,
    required this.onBack,
    this.epgTitle,
    this.onSettings,
    this.hasSubtitles = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(gradient: LinearGradient(
      begin: Alignment.topCenter, end: Alignment.bottomCenter,
      colors: [Color(0xDD000000), Colors.transparent])),
    padding: const EdgeInsets.fromLTRB(4, 8, 4, 28),
    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      // Botón atrás
      IconButton(
        icon: const Icon(Icons.arrow_back, color: Colors.white),
        onPressed: onBack),

      // Título + EPG
      Expanded(child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(title,
            style: const TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600,
              shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
            maxLines: 1, overflow: TextOverflow.ellipsis),
          if (epgTitle != null && epgTitle!.isNotEmpty) ...[
            const SizedBox(height: 3),
            Row(children: [
              const Icon(Icons.tv, color: AppColors.celeste, size: 12),
              const SizedBox(width: 4),
              Expanded(child: Text(epgTitle!,
                style: const TextStyle(
                  color: AppColors.celeste, fontSize: 12,
                  shadows: [Shadow(color: Colors.black54, blurRadius: 4)]),
                maxLines: 1, overflow: TextOverflow.ellipsis)),
            ]),
          ],
        ],
      )),

      // Gear icon con badge cyan si hay pistas disponibles
      if (onSettings != null)
        Stack(children: [
          IconButton(
            icon: const Icon(Icons.settings_rounded, color: Colors.white, size: 22),
            tooltip: 'Subtítulos',
            onPressed: onSettings,
          ),
          if (hasSubtitles)
            Positioned(
              top: 10, right: 10,
              child: Container(
                width: 7, height: 7,
                decoration: const BoxDecoration(
                  color: AppColors.celeste,
                  shape: BoxShape.circle))),
        ]),
    ]),
  );
}
