import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel.dart';
import '../services/xtream_service.dart';
import '../theme/app_theme.dart';

// ─── Layout options ───────────────────────────────────────────────────────────
enum _MVLayout { two, four }

// ─── Per-panel state (plain class, not a widget) ──────────────────────────────
class _PanelState {
  Channel? channel;
  VideoPlayerController? controller;
  bool loading = false;
  bool error   = false;

  // ── Anti-freeze watchdog ─────────────────────────────────────────────────
  Timer?   watchdog;
  Duration lastPos     = Duration.zero;
  int      staleCount  = 0; // segundos acumulados sin progreso (umbral: 30 s)

  // ── Race-condition guard ─────────────────────────────────────────────────
  // Se incrementa en cada nueva carga; permite descartar callbacks obsoletos.
  int loadId = 0;

  bool get hasVideo =>
      controller != null && controller!.value.isInitialized;

  void dispose() {
    watchdog?.cancel();
    watchdog = null;
    controller?.dispose();
    controller = null;
  }
}

// ─── Main screen ──────────────────────────────────────────────────────────────
class MultiViewScreen extends StatefulWidget {
  final XtreamService service;
  const MultiViewScreen({super.key, required this.service});
  @override State<MultiViewScreen> createState() => _MultiViewScreenState();
}

class _MultiViewScreenState extends State<MultiViewScreen> {
  final List<_PanelState> _panels = List.generate(4, (_) => _PanelState());
  int      _focused = 0;
  _MVLayout _layout  = _MVLayout.two;

  // Channel list for picker — loaded lazily on first open
  List<Channel> _allChannels    = [];
  bool          _channelsLoaded  = false;
  bool          _channelsLoading = false;

  int get _count => _layout == _MVLayout.two ? 2 : 4;

  // ── Lifecycle ────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    for (final p in _panels) p.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // ── Channel loading ──────────────────────────────────────────────────────

  Future<void> _ensureChannels() async {
    if (_channelsLoaded || _channelsLoading) return;
    if (mounted) setState(() => _channelsLoading = true);
    final list = await widget.service.getLiveStreams();
    if (!mounted) return;
    setState(() {
      _allChannels    = list;
      _channelsLoaded  = true;
      _channelsLoading = false;
    });
  }

  // ── Video management ─────────────────────────────────────────────────────

  Future<void> _loadChannel(int idx, Channel ch) async {
    final panel = _panels[idx];

    // Cancelar carga anterior + watchdog
    panel.dispose();
    panel.loadId++;
    final myLoad = panel.loadId;

    setState(() {
      panel.channel    = ch;
      panel.loading    = true;
      panel.error      = false;
      panel.controller = null;
      panel.staleCount = 0;
      panel.lastPos    = Duration.zero;
    });

    final url  = widget.service.liveStreamUrl(ch.id);
    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );

    try {
      // Timeout de 20 s para no quedar pegado en "Conectando..."
      await ctrl.initialize().timeout(const Duration(seconds: 20));
      if (!mounted || panel.loadId != myLoad) { ctrl.dispose(); return; }

      await ctrl.setVolume(idx == _focused ? 1.0 : 0.0);
      await ctrl.play();

      setState(() {
        panel.controller = ctrl;
        panel.loading    = false;
      });

      // ── Listener de error: auto-reconexión a los 4 s ──────────────────
      ctrl.addListener(() {
        if (!mounted || panel.loadId != myLoad || panel.controller != ctrl) return;
        if (ctrl.value.hasError) {
          panel.watchdog?.cancel();
          if (mounted) setState(() { panel.loading = false; panel.error = true; });
          Future.delayed(const Duration(seconds: 4), () {
            if (mounted && panel.loadId == myLoad && panel.channel != null) {
              _loadChannel(idx, panel.channel!);
            }
          });
        }
      });

      // ── Watchdog: detecta stream verdaderamente congelado ────────────
      //
      // Se ejecuta cada 5 s y acumula tiempo "sin progreso".
      // Solo cuenta tiempo cuando el player NO está en buffering normal
      // (isBuffering = true significa que está cargando datos — eso es
      //  esperado en live TV y NO debe disparar una reconexión).
      // Reconecta únicamente si la posición lleva ≥ 30 s sin avanzar
      // Y el player no está en estado de buffering.
      // Durante reproducción normal, la posición avanza continuamente
      // → staleCount se reinicia a 0 y el watchdog nunca actúa.
      panel.watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
        if (!mounted || panel.loadId != myLoad || panel.controller != ctrl) return;
        if (!ctrl.value.isInitialized || !ctrl.value.isPlaying) {
          panel.staleCount = 0;
          return;
        }

        // Buffering normal (cargando segmento): esperar, no contar
        if (ctrl.value.isBuffering) return;

        final pos = ctrl.value.position;
        if (pos != panel.lastPos) {
          // Stream avanzando con normalidad — resetear contador
          panel.staleCount = 0;
          panel.lastPos    = pos;
        } else {
          // Posición sin cambio (y no buffering): posible congelamiento
          panel.staleCount += 5; // acumular segundos
          if (panel.staleCount >= 30) {
            // 30 segundos reales sin progreso → reconectar
            panel.staleCount = 0;
            if (panel.channel != null && mounted) _loadChannel(idx, panel.channel!);
          }
        }
      });

    } catch (_) {
      ctrl.dispose();
      if (!mounted || panel.loadId != myLoad) return;
      setState(() { panel.loading = false; panel.error = true; });
      // Auto-retry a los 5 s si el stream no responde
      Future.delayed(const Duration(seconds: 5), () {
        if (mounted && panel.loadId == myLoad && panel.channel != null) {
          _loadChannel(idx, panel.channel!);
        }
      });
    }
  }

  void _setFocused(int idx) {
    if (idx == _focused) return;
    // Mute all, unmute newly focused
    for (int i = 0; i < _count; i++) {
      _panels[i].controller?.setVolume(i == idx ? 1.0 : 0.0);
    }
    setState(() => _focused = idx);
  }

  void _switchLayout(_MVLayout layout) {
    if (layout == _layout) return;
    if (layout == _MVLayout.two) {
      _panels[2].dispose();
      _panels[3].dispose();
      // Keep focus in bounds
      if (_focused > 1) {
        _panels[0].controller?.setVolume(1.0);
        setState(() => _focused = 0);
      }
    }
    setState(() => _layout = layout);
  }

  // ── Channel picker ───────────────────────────────────────────────────────

  Future<void> _openPicker(int panelIdx) async {
    await _ensureChannels();
    if (!mounted) return;

    final ch = await showModalBottomSheet<Channel>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _ChannelPickerSheet(
        channels: _allChannels,
        loading:  _channelsLoading,
      ),
    );
    if (ch != null && mounted) _loadChannel(panelIdx, ch);
  }

  // ── D-pad navigation ─────────────────────────────────────────────────────

  KeyEventResult _onKey(FocusNode _, KeyEvent evt) {
    if (evt is! KeyDownEvent) return KeyEventResult.ignored;

    final k     = evt.logicalKey;
    final count = _count;

    if (k == LogicalKeyboardKey.arrowRight) {
      _setFocused((_focused + 1) % count);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      _setFocused((_focused - 1 + count) % count);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && _layout == _MVLayout.four) {
      _setFocused((_focused + 2) % 4);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp && _layout == _MVLayout.four) {
      _setFocused((_focused - 2 + 4) % 4);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter) {
      _openPicker(_focused);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          Positioned.fill(child: _buildGrid()),
          Positioned(top: 0, left: 0, right: 0, child: _buildTopBar()),
        ]),
      ),
    );
  }

  // ── Grid of panels ───────────────────────────────────────────────────────

  Widget _buildGrid() {
    if (_layout == _MVLayout.two) {
      return Row(children: [
        Expanded(child: _buildPanel(0)),
        Container(width: 2, color: Colors.black),
        Expanded(child: _buildPanel(1)),
      ]);
    }
    return Column(children: [
      Expanded(child: Row(children: [
        Expanded(child: _buildPanel(0)),
        Container(width: 2, color: Colors.black),
        Expanded(child: _buildPanel(1)),
      ])),
      Container(height: 2, color: Colors.black),
      Expanded(child: Row(children: [
        Expanded(child: _buildPanel(2)),
        Container(width: 2, color: Colors.black),
        Expanded(child: _buildPanel(3)),
      ])),
    ]);
  }

  // ── Single panel ─────────────────────────────────────────────────────────

  Widget _buildPanel(int idx) {
    final p       = _panels[idx];
    final focused = _focused == idx;

    return GestureDetector(
      onTap: () {
        _setFocused(idx);
        if (p.channel == null && !p.loading) _openPicker(idx);
      },
      onLongPress: () => _openPicker(idx),
      child: Stack(children: [

        // ── Background / Video ─────────────────────────────────────────
        if (p.hasVideo)
          Positioned.fill(
            child: ClipRect(
              child: FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width:  p.controller!.value.size.width,
                  height: p.controller!.value.size.height,
                  child: VideoPlayer(p.controller!),
                ),
              ),
            ),
          )
        else
          Positioned.fill(
            child: _EmptyPanel(
              loading: p.loading,
              error:   p.error,
              focused: focused,
              onRetry: p.channel != null ? () => _loadChannel(idx, p.channel!) : null,
            )),

        // ── Channel name bar ───────────────────────────────────────────
        if (p.channel != null)
          Positioned(
            left: 0, right: 0, bottom: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 7),
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end:   Alignment.topCenter,
                  colors: [Color(0xCC000000), Colors.transparent])),
              child: Row(children: [
                if (focused) ...[
                  Container(
                    margin: const EdgeInsets.only(right: 6),
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.celeste.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(3)),
                    child: const Icon(Icons.volume_up, color: Colors.white, size: 9)),
                ],
                Expanded(
                  child: Text(
                    p.channel!.name,
                    style: const TextStyle(
                      color: Colors.white, fontSize: 10,
                      shadows: [Shadow(color: Colors.black, blurRadius: 4)]),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                if (focused)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: Colors.red.withOpacity(0.5))),
                    child: const Text('● EN VIVO',
                      style: TextStyle(color: Colors.red, fontSize: 7,
                        fontWeight: FontWeight.bold))),
              ]),
            )),

        // ── Focused highlight border ───────────────────────────────────
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                border: Border.all(
                  color: focused ? AppColors.celeste : Colors.transparent,
                  width: 3))))),

        // ── Panel number badge ─────────────────────────────────────────
        Positioned(
          top: 6, left: 8,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 20, height: 20,
            decoration: BoxDecoration(
              color: focused
                  ? AppColors.celeste.withOpacity(0.85)
                  : Colors.black45,
              shape: BoxShape.circle),
            child: Center(
              child: Text('${idx + 1}',
                style: TextStyle(
                  color: focused ? Colors.white : Colors.white38,
                  fontSize: 10, fontWeight: FontWeight.bold))))),

        // ── "Mantén para cambiar" hint on active focused panel ─────────
        if (focused && p.channel != null)
          Positioned(
            top: 6, right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(5)),
              child: const Text('Mantén para cambiar canal',
                style: TextStyle(color: Colors.white38, fontSize: 8)))),
      ]),
    );
  }

  // ── Top bar ──────────────────────────────────────────────────────────────

  Widget _buildTopBar() => Container(
    decoration: const BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [Color(0xCC000000), Colors.transparent])),
    padding: const EdgeInsets.fromLTRB(4, 8, 12, 28),
    child: Row(children: [
      // Back
      IconButton(
        icon: const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 22),
        onPressed: () => Navigator.pop(context)),
      const SizedBox(width: 2),
      const Icon(Icons.grid_view_rounded, color: AppColors.celeste, size: 15),
      const SizedBox(width: 6),
      const Text('Multi-Vista',
        style: TextStyle(color: Colors.white, fontSize: 15,
          fontWeight: FontWeight.w600, letterSpacing: 0.3)),
      const Spacer(),
      // TV hint
      const Text('OK = elegir canal  •  Mantén = cambiar canal',
        style: TextStyle(color: Colors.white30, fontSize: 9)),
      const SizedBox(width: 12),
      // 2-panel button
      _LayoutToggle(
        label: '2', icon: Icons.view_stream_rounded,
        active: _layout == _MVLayout.two,
        onTap: () => _switchLayout(_MVLayout.two)),
      const SizedBox(width: 8),
      // 4-panel button
      _LayoutToggle(
        label: '4', icon: Icons.grid_view_rounded,
        active: _layout == _MVLayout.four,
        onTap: () => _switchLayout(_MVLayout.four)),
    ]),
  );
}

// ─── Empty panel placeholder ──────────────────────────────────────────────────
class _EmptyPanel extends StatelessWidget {
  final bool loading, error, focused;
  final VoidCallback? onRetry;
  const _EmptyPanel({
    required this.loading, required this.error,
    required this.focused, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF050A14),
      child: Center(
        child: loading
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              SizedBox(
                width: 24, height: 24,
                child: CircularProgressIndicator(
                  color: AppColors.celeste, strokeWidth: 2)),
              const SizedBox(height: 10),
              const Text('Conectando...',
                style: TextStyle(color: Colors.white38, fontSize: 10)),
            ])
          : error
            ? Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.wifi_off_rounded, color: Colors.red, size: 24),
                const SizedBox(height: 4),
                const Text('Error · Reconectando…',
                  style: TextStyle(color: Colors.white38, fontSize: 9)),
                const SizedBox(height: 8),
                if (onRetry != null)
                  GestureDetector(
                    onTap: onRetry,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        border: Border.all(color: AppColors.celeste.withOpacity(0.5)),
                        borderRadius: BorderRadius.circular(6)),
                      child: const Text('Reintentar ahora',
                        style: TextStyle(color: AppColors.celeste, fontSize: 9)))),
              ])
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.add_circle_outline_rounded,
                  color: focused ? AppColors.celeste : Colors.white12,
                  size: 32),
                const SizedBox(height: 8),
                Text(
                  focused ? 'Presiona OK para elegir canal' : 'Panel vacío',
                  style: TextStyle(
                    color: focused
                        ? AppColors.celeste.withOpacity(0.8)
                        : Colors.white12,
                    fontSize: 10)),
              ]),
      ),
    );
  }
}

// ─── Layout toggle button ─────────────────────────────────────────────────────
class _LayoutToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  const _LayoutToggle({
    required this.label, required this.icon,
    required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active
              ? AppColors.celeste.withOpacity(0.2)
              : Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: active ? AppColors.celeste : Colors.white24,
            width: active ? 1.5 : 1)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon,
            color: active ? AppColors.celeste : Colors.white38, size: 13),
          const SizedBox(width: 4),
          Text(label,
            style: TextStyle(
              color: active ? AppColors.celeste : Colors.white38,
              fontSize: 11, fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

// ─── Channel picker bottom sheet ──────────────────────────────────────────────
class _ChannelPickerSheet extends StatefulWidget {
  final List<Channel> channels;
  final bool loading;
  const _ChannelPickerSheet({required this.channels, required this.loading});
  @override State<_ChannelPickerSheet> createState() => _ChannelPickerSheetState();
}

class _ChannelPickerSheetState extends State<_ChannelPickerSheet> {
  final _ctrl  = TextEditingController();
  final _focus = FocusNode();
  List<Channel> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = widget.channels;
    _ctrl.addListener(_onQuery);
    // Auto-focus search field on open
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() { _ctrl.dispose(); _focus.dispose(); super.dispose(); }

  void _onQuery() {
    final q = _ctrl.text.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? widget.channels
          : widget.channels.where((c) =>
              c.name.toLowerCase().contains(q)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.of(context).size.height * 0.75;

    return Container(
      height: h,
      decoration: const BoxDecoration(
        color: Color(0xFF0D1020),
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      child: Column(children: [

        // Handle bar
        Container(
          margin: const EdgeInsets.only(top: 10, bottom: 6),
          width: 36, height: 3,
          decoration: BoxDecoration(
            color: Colors.white24,
            borderRadius: BorderRadius.circular(2))),

        // Header
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
          child: Row(children: [
            const Icon(Icons.live_tv, color: AppColors.celeste, size: 18),
            const SizedBox(width: 8),
            const Text('Seleccionar canal',
              style: TextStyle(color: Colors.white,
                fontSize: 15, fontWeight: FontWeight.bold)),
            const Spacer(),
            if (widget.channels.isNotEmpty)
              Text('${widget.channels.length} canales',
                style: const TextStyle(color: Colors.white38, fontSize: 12)),
          ]),
        ),

        // Search field
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.celeste.withOpacity(0.3))),
            child: Row(children: [
              const Padding(
                padding: EdgeInsets.only(left: 12),
                child: Icon(Icons.search, color: AppColors.textSecondary, size: 18)),
              Expanded(
                child: TextField(
                  controller: _ctrl,
                  focusNode:  _focus,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                  decoration: const InputDecoration(
                    hintText: 'Buscar canal...',
                    hintStyle: TextStyle(color: AppColors.textSecondary),
                    border: InputBorder.none,
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10, vertical: 12)),
                )),
              if (_ctrl.text.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white38, size: 16),
                  onPressed: () { _ctrl.clear(); }),
            ]),
          )),

        const Divider(color: Colors.white10, height: 1),

        // Channel list or loading
        Expanded(
          child: widget.loading
            ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(color: AppColors.celeste),
                SizedBox(height: 12),
                Text('Cargando canales...',
                  style: TextStyle(color: Colors.white54, fontSize: 12)),
              ]))
            : _filtered.isEmpty
              ? const Center(child: Text('Sin resultados',
                  style: TextStyle(color: Colors.white38, fontSize: 13)))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: _filtered.length,
                  itemBuilder: (_, i) {
                    final ch = _filtered[i];
                    return _ChannelTile(
                      channel: ch,
                      onTap: () => Navigator.pop(context, ch),
                    );
                  },
                ),
        ),
      ]),
    );
  }
}

// ─── Channel tile inside the picker ──────────────────────────────────────────
class _ChannelTile extends StatefulWidget {
  final Channel channel;
  final VoidCallback onTap;
  const _ChannelTile({required this.channel, required this.onTap});
  @override State<_ChannelTile> createState() => _ChannelTileState();
}
class _ChannelTileState extends State<_ChannelTile> {
  bool _focused = false;
  final _fn = FocusNode();

  @override void initState() {
    super.initState();
    _fn.addListener(() {
      if (mounted) setState(() => _focused = _fn.hasFocus);
    });
  }
  @override void dispose() { _fn.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => InkWell(
    focusNode: _fn,
    focusColor: Colors.transparent,
    onTap: widget.onTap,
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        color: _focused ? Colors.white10 : Colors.transparent,
        border: Border(
          left: BorderSide(
            color: _focused ? AppColors.celeste : Colors.transparent,
            width: 3))),
      child: Row(children: [
        // Logo
        ClipRRect(
          borderRadius: BorderRadius.circular(5),
          child: widget.channel.streamIcon.isNotEmpty
            ? CachedNetworkImage(
                imageUrl: widget.channel.streamIcon,
                width: 36, height: 27, fit: BoxFit.contain,
                errorWidget: (_, __, ___) => _iconFallback())
            : _iconFallback()),
        const SizedBox(width: 12),
        Expanded(child: Text(
          widget.channel.name,
          style: TextStyle(
            color: _focused ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: _focused ? FontWeight.w600 : FontWeight.normal),
          maxLines: 1, overflow: TextOverflow.ellipsis)),
        Icon(Icons.play_arrow_rounded,
          color: _focused ? AppColors.celeste : Colors.transparent, size: 18),
      ]),
    ),
  );

  Widget _iconFallback() => Container(
    width: 36, height: 27,
    color: AppColors.card,
    child: const Icon(Icons.tv, color: AppColors.celeste, size: 14));
}
