import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import '../models/category.dart';
import '../models/channel.dart';
import '../models/epg_entry.dart';
import '../services/xtream_service.dart';
import '../services/history_service.dart';
import '../services/parental_service.dart';
import '../services/epg_settings_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'player_screen.dart';
import 'epg_search_screen.dart';
import '../widgets/reminder_button.dart';

class LiveScreen extends StatefulWidget {
  final XtreamService service;
  const LiveScreen({super.key, required this.service});
  @override State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  List<Category> _categories = [];
  List<Channel> _channels = [];
  int _selectedCatIndex = 0;
  bool _loadingCats = true, _loadingChannels = false;
  final _catFocusNodes = <FocusNode>[];
  final _channelFocusNodes = <FocusNode>[];

  // ── Búsqueda de canales ──────────────────────────────────────────────────
  bool _showSearch = false;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();
  List<Channel> _allChannels = [];   // todos los canales de la sección
  bool _loadingAll = false;

  // ── Panel de previsualización ─────────────────────────────────────────────
  Channel? _previewChannel;
  int _previewChannelIdx = 0;

  List<Channel> get _visibleChannels {
    if (_searchQuery.isEmpty) return _channels;
    final pool = _allChannels.isNotEmpty ? _allChannels : _channels;
    return pool.where((c) =>
        c.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
  }

  static final _virtualCats = [
    Category(id: HistoryService.recentCatId, name: 'Recientes'),
    Category(id: HistoryService.favCatId,    name: 'Favoritos'),
  ];

  @override void initState() { super.initState(); _loadCategories(); }

  @override void dispose() {
    for (final n in [..._catFocusNodes, ..._channelFocusNodes]) n.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final results = await Future.wait([
      widget.service.getLiveCategories(),
      ParentalService.getBlocked('live'),
    ]);
    if (!mounted) return;
    final cats    = results[0] as List<Category>;
    final blocked = results[1] as Set<String>;
    final visible = cats.where((c) => !blocked.contains(c.id)).toList();
    final all = [..._virtualCats, ...visible];
    _catFocusNodes.addAll(List.generate(all.length, (_) => FocusNode()));
    setState(() { _categories = all; _loadingCats = false; });
    if (all.isNotEmpty) _selectCategory(all[0], 0);
  }

  void _onChannelFocused(Channel ch, int idx) {
    if (_previewChannel?.id != ch.id) {
      setState(() { _previewChannel = ch; _previewChannelIdx = idx; });
    }
  }

  /// En teléfono: muestra un bottom sheet con preview de video + guía EPG completa.
  void _showChannelDetail(BuildContext ctx, Channel ch, int idx) {
    showModalBottomSheet(
      context: ctx,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.88,
        child: Container(
          decoration: const BoxDecoration(
            color: Color(0xFF0D1020),
            borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
          child: Column(children: [
            // Handle
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 2),
              width: 36, height: 4,
              decoration: BoxDecoration(
                color: Colors.white24, borderRadius: BorderRadius.circular(2))),
            // Panel de preview + EPG (reutilizamos el mismo widget)
            Expanded(child: _PreviewPanel(
              key: ValueKey(ch.id),
              channel: ch,
              service: widget.service,
              channels: _channels,
              channelIndex: idx,
            )),
          ]),
        ),
      ),
    );
  }

  Future<void> _selectCategory(Category cat, int index) async {
    _searchCtrl.clear();
    setState(() {
      _selectedCatIndex = index; _loadingChannels = true;
      _channels = []; _searchQuery = ''; _previewChannel = null;
    });
    for (final n in _channelFocusNodes) n.dispose();
    _channelFocusNodes.clear();

    List<Channel> ch;
    if (cat.id == HistoryService.recentCatId) {
      final data = await HistoryService.getRecent(HistoryService.live);
      ch = data.map((m) => Channel(id: m['id']!, name: m['name']!, streamType: 'live',
        streamIcon: m['icon'] ?? '', categoryId: '', epgChannelId: '')).toList();
    } else if (cat.id == HistoryService.favCatId) {
      final data = await HistoryService.getFavorites(HistoryService.live);
      ch = data.map((m) => Channel(id: m['id']!, name: m['name']!, streamType: 'live',
        streamIcon: m['icon'] ?? '', categoryId: '', epgChannelId: '')).toList();
    } else {
      ch = await widget.service.getLiveStreams(categoryId: cat.id);
    }
    if (!mounted) return;
    _channelFocusNodes.addAll(List.generate(ch.length, (_) => FocusNode()));
    setState(() { _channels = ch; _loadingChannels = false; });
  }

  Future<void> _loadAllChannels() async {
    if (_allChannels.isNotEmpty || _loadingAll) return;
    setState(() => _loadingAll = true);
    final all = await widget.service.getLiveStreams();
    if (!mounted) return;
    setState(() { _allChannels = all; _loadingAll = false; });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.background,
    appBar: _liveAppBar(context),
    body: Column(children: [
      // ── Barra de búsqueda de canales ─────────────────────────────────
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        child: _showSearch
          ? _buildSearchBar(context, AppColors.celeste)
          : const SizedBox.shrink(),
      ),
      // ── Contenido principal ─────────────────────────────────────────
      Expanded(child: Builder(builder: (context) {
        final isPhone = R.isPhone(context);
        return Row(children: [
          // Columna de categorías
          SizedBox(width: R.catPanelW(context),
            child: _loadingCats
              ? const Center(child: CircularProgressIndicator(color: AppColors.celeste))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _categories.length,
                  itemBuilder: (_, i) {
                    final isVirtual = i < _virtualCats.length;
                    return CatTile(
                      name: _categories[i].name,
                      isSelected: _selectedCatIndex == i,
                      accentColor: isVirtual ? Colors.amber : AppColors.celeste,
                      focusNode: _catFocusNodes[i],
                      autofocus: i == 0,
                      onSelect: () => _selectCategory(_categories[i], i),
                    );
                  })),
          Container(width: 1, color: Colors.white10),
          // Columna de canales
          Expanded(child: (_loadingChannels || (_loadingAll && _searchQuery.isNotEmpty))
            ? const Center(child: CircularProgressIndicator(color: AppColors.celeste))
            : _visibleChannels.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_searchQuery.isNotEmpty ? Icons.search_off : Icons.tv_off,
                    color: Colors.white24, size: 40),
                  const SizedBox(height: 10),
                  Text(_searchQuery.isNotEmpty
                    ? 'Sin resultados para "$_searchQuery"'
                    : (_selectedCatIndex < _virtualCats.length
                      ? 'Aún no hay nada aquí' : 'Sin canales'),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                ]))
              : ListView.builder(
                  padding: EdgeInsets.symmetric(vertical: 8, horizontal: R.padding(context)),
                  itemCount: _visibleChannels.length,
                  itemBuilder: (ctx, i) {
                    final ch = _visibleChannels[i];
                    return _ChannelTile(
                      channel: ch, service: widget.service,
                      channels: _channels,
                      channelIndex: _channels.indexOf(ch),
                      focusNode: i < _channelFocusNodes.length ? _channelFocusNodes[i] : FocusNode(),
                      autofocus: i == 0,
                      onFocused: () => _onChannelFocused(ch, i),
                      // Teléfono: tap → bottom sheet con preview + EPG
                      // TV/Tablet: onSelect es null → onTap usa onFocused (3ª columna)
                      onSelect: isPhone
                          ? () => _showChannelDetail(ctx, ch, i)
                          : null,
                      onFavChanged: () => _selectCategory(_categories[_selectedCatIndex], _selectedCatIndex),
                    );
                  })),
          // Columna de previsualización + EPG (solo en tablet/TV)
          if (!isPhone) ...[
            Container(width: 1, color: Colors.white10),
            SizedBox(
              width: 320,
              child: _PreviewPanel(
                key: ValueKey(_previewChannel?.id ?? ''),
                channel: _previewChannel,
                service: widget.service,
                channels: _channels,
                channelIndex: _previewChannelIdx,
              ),
            ),
          ],
        ]);
      })),
    ]),
  );

  PreferredSizeWidget _liveAppBar(BuildContext context) => AppBar(
    backgroundColor: const Color(0xFF080B14),
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 20),
      focusColor: AppColors.celeste.withOpacity(0.2),
      onPressed: () => Navigator.pop(context),
    ),
    title: Row(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.live_tv, color: AppColors.celeste, size: 20),
      const SizedBox(width: 8),
      Text('En Vivo', style: TextStyle(color: Colors.white,
        fontSize: R.fs(context, 17), fontWeight: FontWeight.w600)),
    ]),
    actions: [
      // Búsqueda de canales (inline)
      IconButton(
        icon: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: Icon(
            _showSearch ? Icons.search_off_rounded : Icons.search_rounded,
            key: ValueKey(_showSearch),
            color: _showSearch ? AppColors.celeste : Colors.white70, size: 22)),
        tooltip: 'Buscar canal',
        onPressed: () {
          final opening = !_showSearch;
          setState(() {
            _showSearch = !_showSearch;
            if (!_showSearch) { _searchCtrl.clear(); _searchQuery = ''; }
          });
          if (opening) _loadAllChannels();
        },
      ),
      // Búsqueda en EPG
      IconButton(
        icon: const Icon(Icons.manage_search_rounded, color: Colors.white70, size: 22),
        tooltip: 'Buscar en EPG',
        onPressed: () => Navigator.push(context, MaterialPageRoute(
          builder: (_) => EpgSearchScreen(service: widget.service, channels: _channels))),
      ),
      // Ajuste de zona horaria
      IconButton(
        icon: const Icon(Icons.schedule_rounded, color: Colors.white70, size: 22),
        tooltip: 'Zona horaria EPG',
        onPressed: () => _showTimezoneSheet(context),
      ),
    ],
    bottom: const PreferredSize(preferredSize: Size.fromHeight(1),
      child: Divider(color: Colors.white10, height: 1)),
  );

  // ── Barra de búsqueda inline reutilizable ────────────────────────────────
  Widget _buildSearchBar(BuildContext ctx, Color accentColor) {
    final p = R.padding(ctx);
    return Container(
      color: const Color(0xFF080B14),
      padding: EdgeInsets.fromLTRB(p + 6, 8, p + 6, 8),
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: accentColor.withOpacity(0.35))),
        child: Row(children: [
          Padding(
            padding: EdgeInsets.only(left: p),
            child: Icon(Icons.search, color: accentColor, size: 18)),
          Expanded(child: TextField(
            controller: _searchCtrl,
            autofocus: true,
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: const InputDecoration(
              hintText: 'Buscar...',
              hintStyle: TextStyle(color: AppColors.textSecondary),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
            onChanged: (q) => setState(() => _searchQuery = q),
          )),
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white38, size: 16),
              onPressed: () {
                _searchCtrl.clear();
                setState(() => _searchQuery = '');
              }),
        ]),
      ),
    );
  }

  void _showTimezoneSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _EpgTimezoneSheet(
        currentOffset: EpgSettingsService.offsetHours,
        onChanged: (offset) async {
          await EpgSettingsService.setOffset(offset);
          if (!mounted) return;
          // Recargar EPG de todos los canales visibles
          setState(() {});
          for (final n in _channelFocusNodes) n.dispose();
          _channelFocusNodes.clear();
          if (_categories.isNotEmpty) {
            _selectCategory(_categories[_selectedCatIndex], _selectedCatIndex);
          }
        },
      ),
    );
  }

  Widget _emptyState(bool isVirtual) => Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
    Icon(isVirtual ? Icons.inbox_outlined : Icons.tv_off, color: Colors.white24, size: 48),
    const SizedBox(height: 12),
    Text(isVirtual ? 'Aún no hay nada aquí' : 'Sin canales',
      style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
  ]));
}

// ─── Shared AppBar ────────────────────────────────────────────────────────────
PreferredSizeWidget sectionAppBar(
  BuildContext ctx,
  String title,
  IconData icon,
  Color color, {
  List<Widget>? actions,
}) =>
  AppBar(
    backgroundColor: const Color(0xFF080B14),
    leading: IconButton(
      icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 20),
      focusColor: AppColors.celeste.withOpacity(0.2),
      onPressed: () => Navigator.pop(ctx),
    ),
    title: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, color: color, size: 20), const SizedBox(width: 8),
      Text(title, style: TextStyle(color: Colors.white,
        fontSize: R.fs(ctx, 17), fontWeight: FontWeight.w600)),
    ]),
    actions: actions,
    bottom: const PreferredSize(preferredSize: Size.fromHeight(1),
      child: Divider(color: Colors.white10, height: 1)),
  );

// ─── Shared CatTile (público para reutilizar) ─────────────────────────────────
class CatTile extends StatefulWidget {
  final String name;
  final bool isSelected;
  final Color accentColor;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback onSelect;
  const CatTile({required this.name, required this.isSelected, required this.accentColor,
    required this.focusNode, required this.autofocus, required this.onSelect});
  @override State<CatTile> createState() => CatTileState();
}
class CatTileState extends State<CatTile> {
  bool _focused = false;

  void _onFocusChange() {
    if (mounted) setState(() => _focused = widget.focusNode.hasFocus);
  }

  @override void initState() {
    super.initState();
    _focused = widget.focusNode.hasFocus;
    widget.focusNode.addListener(_onFocusChange);
  }

  @override void didUpdateWidget(CatTile old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      old.focusNode.removeListener(_onFocusChange);
      widget.focusNode.addListener(_onFocusChange);
      _focused = widget.focusNode.hasFocus;
    }
  }

  @override void dispose() {
    widget.focusNode.removeListener(_onFocusChange);
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final active = widget.isSelected || _focused;
    final isPhone = R.isPhone(context);
    return InkWell(
      focusNode: widget.focusNode, autofocus: widget.autofocus,
      focusColor: Colors.transparent, onTap: widget.onSelect,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: EdgeInsets.symmetric(horizontal: isPhone ? 4 : 6, vertical: 3),
        padding: EdgeInsets.symmetric(horizontal: isPhone ? 8 : 12, vertical: isPhone ? 9 : 11),
        decoration: BoxDecoration(
          gradient: widget.isSelected ? AppColors.buttonGradient : null,
          color: widget.isSelected ? null : (_focused ? Colors.white12 : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _focused ? widget.accentColor : Colors.transparent, width: 2),
        ),
        child: Text(widget.name, style: TextStyle(
          color: active ? Colors.white : AppColors.textSecondary,
          fontSize: R.fs(context, 12),
          fontWeight: active ? FontWeight.w600 : FontWeight.normal)),
      ),
    );
  }
}

// ─── Channel Tile ─────────────────────────────────────────────────────────────
class _ChannelTile extends StatefulWidget {
  final Channel channel;
  final XtreamService service;
  final List<Channel> channels;
  final int channelIndex;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback? onFocused;
  /// Callback para el tap explícito (toque/OK del mando).
  /// Si es null, el comportamiento por defecto es llamar [onFocused].
  final VoidCallback? onSelect;
  final VoidCallback onFavChanged;
  const _ChannelTile({required this.channel, required this.service,
    required this.channels, required this.channelIndex,
    required this.focusNode, this.autofocus = false,
    this.onFocused, this.onSelect, required this.onFavChanged});
  @override State<_ChannelTile> createState() => _ChannelTileState();
}
class _ChannelTileState extends State<_ChannelTile> {
  bool _focused = false, _isFav = false;
  List<EpgEntry> _epg = [];
  bool _epgLoaded = false;
  Timer? _epgRefreshTimer;

  @override void initState() {
    super.initState();
    widget.focusNode.addListener(() {
      if (mounted) {
        setState(() => _focused = widget.focusNode.hasFocus);
        if (widget.focusNode.hasFocus) widget.onFocused?.call();
      }
    });
    _loadFav();
    _loadEpg();
  }

  Future<void> _loadFav() async {
    final fav = await HistoryService.isFavorite(HistoryService.live, widget.channel.id);
    if (mounted) setState(() => _isFav = fav);
  }

  Future<void> _loadEpg() async {
    final entries = await widget.service.getShortEpg(widget.channel.id);
    if (mounted) setState(() { _epg = entries; _epgLoaded = true; });
    _scheduleEpgRefresh();
  }

  /// Programa un timer para refrescar EPG justo cuando termine el programa actual
  void _scheduleEpgRefresh() {
    _epgRefreshTimer?.cancel();
    final cur = _current;
    if (cur == null) return;
    final remaining = cur.end.difference(DateTime.now());
    // Si ya terminó o termina en menos de 5s, refrescar ahora
    final delay = remaining.isNegative ? Duration.zero
        : remaining + const Duration(seconds: 5);
    _epgRefreshTimer = Timer(delay, () async {
      if (!mounted) return;
      XtreamService.clearEpgCacheForChannel(widget.channel.id);
      await _loadEpg();
    });
  }

  Future<void> _toggleFav() async {
    final newState = await HistoryService.toggleFavorite(
      HistoryService.live, widget.channel.id,
      {'id': widget.channel.id, 'name': widget.channel.name, 'icon': widget.channel.streamIcon});
    if (mounted) { setState(() => _isFav = newState); widget.onFavChanged(); }
  }

  Future<void> _play() async {
    await HistoryService.addRecent(HistoryService.live,
      {'id': widget.channel.id, 'name': widget.channel.name, 'icon': widget.channel.streamIcon});
    if (!mounted) return;
    // Pasar programa actual al player si está disponible
    Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(
      title: widget.channel.name,
      streamUrl: widget.service.liveStreamUrl(widget.channel.id),
      epgTitle: _current?.title,
      channels: widget.channels,
      channelIndex: widget.channelIndex,
      service: widget.service,
    )));
  }

  // Programa actual (si la lista no está vacía y el primero no ha terminado)
  EpgEntry? get _current {
    if (_epg.isEmpty) return null;
    final now = DateTime.now();
    return _epg.firstWhere(
      (e) => e.start.isBefore(now) && e.end.isAfter(now),
      orElse: () => _epg.first,
    );
  }

  EpgEntry? get _next {
    if (_epg.length < 2) return null;
    final c = _current;
    if (c == null) return null;
    final idx = _epg.indexOf(c);
    return idx + 1 < _epg.length ? _epg[idx + 1] : null;
  }

  @override Widget build(BuildContext context) {
    final isPhone = R.isPhone(context);
    final sz = isPhone ? 36.0 : 48.0;
    final cur = _current;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      margin: const EdgeInsets.symmetric(vertical: 3, horizontal: 4),
      decoration: BoxDecoration(
        color: _focused ? Colors.white12 : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _focused ? AppColors.celeste : Colors.transparent, width: 2),
      ),
      // ── Row externo: canal (tappable) + corazón (sibling, no nested) ──
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Expanded(
          child: InkWell(
            focusNode: widget.focusNode, autofocus: widget.autofocus,
            focusColor: Colors.transparent,
            // onSelect viene del padre:
            //   • Teléfono  → bottom sheet con preview + EPG
            //   • TV/Tablet → actualiza la tercera columna (onFocused)
            // _play() solo se invoca desde el botón "Reproducir" del _PreviewPanel.
            onTap: widget.onSelect
                ?? (widget.onFocused != null ? () => widget.onFocused!() : null),
            borderRadius: const BorderRadius.horizontal(left: Radius.circular(10)),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isPhone ? 8 : 12,
                vertical: isPhone ? 7 : 9),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // ── Logo + nombre + badge ─────────────────────────────
                Row(children: [
                  ClipRRect(borderRadius: BorderRadius.circular(6),
                    child: widget.channel.streamIcon.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: widget.channel.streamIcon,
                          width: sz, height: sz * 0.75,
                          fit: BoxFit.contain,
                          placeholder: (_, __) => _icon(sz),
                          errorWidget: (_, __, ___) => _icon(sz))
                      : _icon(sz)),
                  SizedBox(width: isPhone ? 8 : 12),
                  Expanded(child: Text(widget.channel.name,
                    style: TextStyle(
                      color: _focused ? Colors.white : AppColors.textPrimary,
                      fontSize: R.fs(context, 14),
                      fontWeight: _focused ? FontWeight.w600 : FontWeight.normal),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                  if (!isPhone)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.red.withOpacity(0.15),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: Colors.red.withOpacity(0.5))),
                      child: const Text('● VIVO',
                        style: TextStyle(color: Colors.red, fontSize: 9, fontWeight: FontWeight.bold))),
                ]),

                // ── EPG: programa actual + barra ──────────────────────
                if (_epgLoaded && cur != null) ...[
                  const SizedBox(height: 5),
                  Padding(
                    padding: EdgeInsets.only(left: sz + (isPhone ? 8 : 12)),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(cur.title,
                          style: TextStyle(
                            color: _focused ? AppColors.celeste : Colors.white54,
                            fontSize: R.fs(context, 11),
                            fontWeight: FontWeight.w500),
                          maxLines: 1, overflow: TextOverflow.ellipsis)),
                        const SizedBox(width: 4),
                        Text(cur.timeRange,
                          style: const TextStyle(color: Colors.white30, fontSize: 10)),
                      ]),
                      const SizedBox(height: 3),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: cur.progress,
                          minHeight: 3,
                          backgroundColor: Colors.white12,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _focused ? AppColors.celeste : AppColors.celeste.withOpacity(0.5)),
                        ),
                      ),
                    ]),
                  ),
                ] else if (!_epgLoaded) ...[
                  Padding(
                    padding: EdgeInsets.only(left: sz + (isPhone ? 8 : 12), top: 4),
                    child: const SizedBox(
                      width: 80, height: 3,
                      child: LinearProgressIndicator(
                        backgroundColor: Colors.white10,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white12))),
                  ),
                ],
              ]),
            ),
          ),
        ),

        // ── Recordatorio próximo programa ─────────────────────────────
        if (_next != null && _next!.start.isAfter(DateTime.now()))
          Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isPhone ? 4 : 6,
              vertical: isPhone ? 10 : 14),
            child: ReminderBell(
              channel: widget.channel,
              program: _next!,
              size: 18,
            )),

        // ── Corazón: FUERA del InkWell para evitar conflicto de gestos ──
        GestureDetector(
          onTap: _toggleFav,
          child: Padding(
            padding: EdgeInsets.symmetric(
              horizontal: isPhone ? 10 : 12,
              vertical: isPhone ? 10 : 14),
            child: Icon(
              _isFav ? Icons.favorite : Icons.favorite_border,
              color: _isFav ? Colors.red : Colors.white30,
              size: 20)),
        ),
      ]),
    );
  }

  @override void dispose() {
    _epgRefreshTimer?.cancel();
    super.dispose();
  }

  Widget _icon(double sz) => Container(
    width: sz, height: sz * 0.75, color: AppColors.card,
    child: const Icon(Icons.tv, color: AppColors.celeste, size: 16));
}

// ─── Panel de Previsualización + EPG ─────────────────────────────────────────
class _PreviewPanel extends StatefulWidget {
  final Channel? channel;
  final XtreamService service;
  final List<Channel> channels;
  final int channelIndex;

  const _PreviewPanel({
    super.key,
    this.channel,
    required this.service,
    required this.channels,
    required this.channelIndex,
  });

  @override State<_PreviewPanel> createState() => _PreviewPanelState();
}

class _PreviewPanelState extends State<_PreviewPanel> {
  VideoPlayerController? _ctrl;
  List<EpgEntry> _epg = [];
  bool _videoError = false;
  bool _loadingEpg = false;
  Timer? _debounce;
  String? _loadedId;

  @override void initState() {
    super.initState();
    if (widget.channel != null) _scheduleLoad();
  }

  @override void didUpdateWidget(_PreviewPanel old) {
    super.didUpdateWidget(old);
    if (old.channel?.id != widget.channel?.id) _scheduleLoad();
  }

  void _scheduleLoad() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 500), _load);
  }

  Future<void> _load() async {
    final ch = widget.channel;
    if (ch == null || !mounted) return;
    final id = ch.id;
    _loadedId = id;

    // Dispose old player
    _ctrl?.dispose();
    if (mounted) setState(() { _ctrl = null; _videoError = false; _epg = []; _loadingEpg = true; });

    // Fetch EPG
    final epg = await widget.service.getShortEpg(id);
    if (!mounted || _loadedId != id) return;
    setState(() { _epg = epg; _loadingEpg = false; });

    // Init mini-player (muted)
    final url = widget.service.liveStreamUrl(id);
    final ctrl = VideoPlayerController.networkUrl(
      Uri.parse(url),
      httpHeaders: const {'User-Agent': 'Mozilla/5.0'},
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    try {
      await ctrl.initialize();
      if (!mounted || _loadedId != id) { ctrl.dispose(); return; }
      ctrl.setVolume(0);
      ctrl.play();
      setState(() => _ctrl = ctrl);
    } catch (_) {
      ctrl.dispose();
      if (mounted && _loadedId == id) setState(() => _videoError = true);
    }
  }

  @override void dispose() {
    _debounce?.cancel();
    _ctrl?.dispose();
    super.dispose();
  }

  @override Widget build(BuildContext context) {
    final ch = widget.channel;

    if (ch == null) {
      return Container(
        color: const Color(0xFF080B14),
        child: const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.live_tv, color: Colors.white12, size: 48),
          SizedBox(height: 12),
          Text('Selecciona un canal', style: TextStyle(color: Colors.white24, fontSize: 12)),
        ])),
      );
    }

    return Container(
      color: const Color(0xFF080B14),
      child: Column(children: [

        // ── Mini-player ─────────────────────────────────────────────────────
        AspectRatio(
          aspectRatio: 16 / 9,
          child: Stack(fit: StackFit.expand, children: [
            // Video (mudo, preview)
            (_ctrl != null && _ctrl!.value.isInitialized)
              ? ClipRect(child: FittedBox(
                  fit: BoxFit.cover,
                  child: SizedBox(
                    width: _ctrl!.value.size.width,
                    height: _ctrl!.value.size.height,
                    child: VideoPlayer(_ctrl!),
                  )))
              : Container(
                  color: const Color(0xFF0A0F1E),
                  child: Center(child: _videoError
                    ? const Icon(Icons.signal_cellular_connected_no_internet_4_bar_rounded,
                        color: Colors.white24, size: 28)
                    : const CircularProgressIndicator(
                        color: AppColors.celeste, strokeWidth: 2))),
            // Overlay inferior: nombre + badge EN VIVO
            Positioned(bottom: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                decoration: const BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [Color(0xDD000000), Colors.transparent])),
                child: Row(children: [
                  if (ch.streamIcon.isNotEmpty)
                    CachedNetworkImage(imageUrl: ch.streamIcon,
                      width: 22, height: 16, fit: BoxFit.contain),
                  const SizedBox(width: 6),
                  Expanded(child: Text(ch.name, style: const TextStyle(
                    color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600),
                    maxLines: 1, overflow: TextOverflow.ellipsis)),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(4)),
                    child: const Text('EN VIVO', style: TextStyle(
                      color: Colors.white, fontSize: 8, fontWeight: FontWeight.bold))),
                ]),
              )),
          ]),
        ),

        // ── Botón Reproducir ────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: const Icon(Icons.play_arrow_rounded, size: 20),
              label: const Text('Reproducir en pantalla completa',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.celeste,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 10),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                elevation: 0),
              onPressed: () async {
                // Guardar en Recientes igual que al reproducir directamente
                await HistoryService.addRecent(HistoryService.live,
                  {'id': ch.id, 'name': ch.name, 'icon': ch.streamIcon});
                if (!mounted) return;
                Navigator.push(context, MaterialPageRoute(builder: (_) =>
                  PlayerScreen(
                    title: ch.name,
                    streamUrl: widget.service.liveStreamUrl(ch.id),
                    channels: widget.channels,
                    channelIndex: widget.channelIndex,
                    service: widget.service,
                  )));
              },
            ),
          ),
        ),

        // ── Header de guía ──────────────────────────────────────────────────
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: const BoxDecoration(border: Border(
            top: BorderSide(color: Colors.white10),
            bottom: BorderSide(color: Colors.white10))),
          child: const Row(children: [
            Icon(Icons.schedule_rounded, color: AppColors.celeste, size: 13),
            SizedBox(width: 6),
            Text('Guía de Programación', style: TextStyle(
              color: Colors.white60, fontSize: 11, fontWeight: FontWeight.w600)),
          ]),
        ),

        // ── Lista EPG ──────────────────────────────────────────────────────
        Expanded(child: _loadingEpg
          ? const Center(child: CircularProgressIndicator(
              color: AppColors.celeste, strokeWidth: 2))
          : _epg.isEmpty
            ? const Center(child: Text('Sin guía disponible',
                style: TextStyle(color: Colors.white24, fontSize: 12)))
            : ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: _epg.length,
                itemBuilder: (_, i) {
                  final e = _epg[i];
                  final now = DateTime.now();
                  final isCurrent = e.start.isBefore(now) && e.end.isAfter(now);
                  final isFuture  = e.start.isAfter(now);
                  return Container(
                    margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    decoration: BoxDecoration(
                      color: isCurrent ? AppColors.celeste.withOpacity(0.08) : Colors.transparent,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isCurrent
                          ? AppColors.celeste.withOpacity(0.25) : Colors.transparent)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      // Hora + badge AHORA
                      SizedBox(width: 58, child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(e.timeRange.split(' - ').first, style: TextStyle(
                            color: isCurrent ? AppColors.celeste : Colors.white38,
                            fontSize: 10, fontWeight: FontWeight.w600)),
                          if (isCurrent) ...[
                            const SizedBox(height: 2),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: AppColors.celeste.withOpacity(0.2),
                                borderRadius: BorderRadius.circular(3)),
                              child: const Text('AHORA', style: TextStyle(
                                color: AppColors.celeste, fontSize: 7,
                                fontWeight: FontWeight.bold))),
                          ],
                        ])),
                      const SizedBox(width: 6),
                      // Título del programa
                      Expanded(child: Text(e.title, style: TextStyle(
                        color: isCurrent ? Colors.white : Colors.white.withOpacity(0.55),
                        fontSize: 11,
                        fontWeight: isCurrent ? FontWeight.w600 : FontWeight.normal),
                        maxLines: 2, overflow: TextOverflow.ellipsis)),
                      // Campanita (solo programas futuros)
                      if (isFuture)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: ReminderBell(channel: ch, program: e, size: 15)),
                    ]),
                  );
                })),
      ]),
    );
  }
}

// ─── Panel de zona horaria EPG ────────────────────────────────────────────────
class _EpgTimezoneSheet extends StatefulWidget {
  final int currentOffset;
  final Future<void> Function(int) onChanged;
  const _EpgTimezoneSheet({required this.currentOffset, required this.onChanged});
  @override State<_EpgTimezoneSheet> createState() => _EpgTimezoneSheetState();
}

class _EpgTimezoneSheetState extends State<_EpgTimezoneSheet> {
  late int _offset;
  bool _saving = false;

  @override void initState() { super.initState(); _offset = widget.currentOffset; }

  String get _label {
    if (_offset == 0) return 'Sin ajuste (servidor)';
    return _offset > 0 ? '+$_offset horas' : '$_offset horas';
  }

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF0D1020),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white12)),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Container(margin: const EdgeInsets.only(top: 10, bottom: 2),
        width: 36, height: 4,
        decoration: BoxDecoration(
          color: Colors.white24, borderRadius: BorderRadius.circular(2))),
      const Padding(
        padding: EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Row(children: [
          Icon(Icons.schedule_rounded, color: AppColors.celeste, size: 20),
          SizedBox(width: 10),
          Text('Zona horaria EPG', style: TextStyle(
            color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
      ),
      const Divider(color: Colors.white10, height: 1),
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
        child: Column(children: [
          Text(_label, style: const TextStyle(
            color: AppColors.celeste, fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          const Text('Ajusta si los horarios del EPG no coinciden con tu zona horaria',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12)),
          const SizedBox(height: 16),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.celeste,
              inactiveTrackColor: Colors.white12,
              thumbColor: AppColors.celeste,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 8),
              trackHeight: 4,
            ),
            child: Slider(
              value: _offset.toDouble(),
              min: -12, max: 12,
              divisions: 24,
              onChanged: (v) => setState(() => _offset = v.round()),
            ),
          ),
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            const Text('-12h', style: TextStyle(color: Colors.white30, fontSize: 11)),
            const Text('0', style: TextStyle(color: Colors.white30, fontSize: 11)),
            const Text('+12h', style: TextStyle(color: Colors.white30, fontSize: 11)),
          ]),
          const SizedBox(height: 20),
          Row(children: [
            Expanded(child: OutlinedButton(
              onPressed: () => Navigator.pop(context),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white38,
                side: const BorderSide(color: Colors.white12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: const Text('Cancelar'))),
            const SizedBox(width: 12),
            Expanded(child: ElevatedButton(
              onPressed: _saving ? null : () async {
                setState(() => _saving = true);
                await widget.onChanged(_offset);
                if (mounted) Navigator.pop(context);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.celeste,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
              child: _saving
                ? const SizedBox(width: 18, height: 18,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                : const Text('Aplicar'))),
          ]),
        ]),
      ),
      const SizedBox(height: 8),
    ]),
  );
}
