import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/channel.dart';
import '../models/epg_entry.dart';
import '../services/xtream_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'player_screen.dart';
import 'live_screen.dart' show sectionAppBar;
import '../widgets/reminder_button.dart';

class EpgSearchScreen extends StatefulWidget {
  final XtreamService service;
  /// Canales ya cargados en la sesión (para mostrar nombre e ícono en resultados)
  final List<Channel> channels;
  const EpgSearchScreen({super.key, required this.service, required this.channels});
  @override State<EpgSearchScreen> createState() => _EpgSearchScreenState();
}

class _EpgSearchScreenState extends State<EpgSearchScreen> {
  final _ctrl      = TextEditingController();
  final _focus     = FocusNode();
  List<({String streamId, EpgEntry entry})> _results = [];
  // Mapa rápido channelId → Channel
  late final Map<String, Channel> _channelMap;
  bool _searched = false;

  @override
  void initState() {
    super.initState();
    _channelMap = { for (final c in widget.channels) c.id: c };
  }

  @override
  void dispose() { _ctrl.dispose(); _focus.dispose(); super.dispose(); }

  void _search(String q) {
    FocusScope.of(context).unfocus();
    final results = XtreamService.searchEpgCache(q);
    setState(() { _results = results; _searched = true; });
  }

  void _play(String streamId) {
    final ch = _channelMap[streamId];
    if (ch == null) return;
    Navigator.push(context, MaterialPageRoute(
      builder: (_) => PlayerScreen(
        title:    ch.name,
        streamUrl: widget.service.liveStreamUrl(ch.id),
        channels: widget.channels,
        channelIndex: widget.channels.indexWhere((c) => c.id == ch.id),
        service:  widget.service,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = R.padding(context);
    final isPhone = R.isPhone(context);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: sectionAppBar(context, 'Buscar en EPG',
          Icons.manage_search_rounded, AppColors.celeste),
      body: Column(children: [

        // ── Campo de búsqueda ──────────────────────────────────────────────
        Padding(
          padding: EdgeInsets.fromLTRB(p + 6, p + 6, p + 6, p + 6),
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.card,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.celeste.withOpacity(0.3)),
            ),
            child: Row(children: [
              Padding(padding: EdgeInsets.only(left: p + 2),
                child: const Icon(Icons.search, color: AppColors.textSecondary)),
              Expanded(child: TextField(
                controller: _ctrl,
                focusNode: _focus,
                autofocus: true,
                style: TextStyle(color: Colors.white, fontSize: R.fs(context, 15)),
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  hintText: 'Nombre de programa, serie, película...',
                  hintStyle: const TextStyle(color: AppColors.textSecondary),
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(horizontal: p, vertical: 14),
                ),
                onSubmitted: _search,
              )),
              if (_ctrl.text.isNotEmpty) ...[
                if (_searched)
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white38, size: 20),
                    onPressed: () {
                      _ctrl.clear();
                      setState(() { _results = []; _searched = false; });
                    }),
                IconButton(
                  icon: const Icon(Icons.send_rounded, color: AppColors.celeste),
                  onPressed: () => _search(_ctrl.text)),
              ],
            ]),
          ),
        ),

        // ── Aviso: solo busca en EPG ya cargado ───────────────────────────
        if (!_searched)
          Padding(
            padding: EdgeInsets.symmetric(horizontal: p + 6),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.amber.withOpacity(0.08),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.amber.withOpacity(0.25))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Icon(Icons.info_outline, color: Colors.amber, size: 16),
                const SizedBox(width: 8),
                Expanded(child: Text(
                  'Busca en los programas EPG ya cargados. '
                  'Navega por los canales primero para ampliar la cobertura.',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                )),
              ]),
            ),
          ),

        // ── Resultados ─────────────────────────────────────────────────────
        Expanded(child: !_searched
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.tv_rounded, color: AppColors.textSecondary,
                size: isPhone ? 40 : 56),
              const SizedBox(height: 14),
              Text('Busca programas en la guía EPG',
                style: TextStyle(color: AppColors.textSecondary,
                  fontSize: R.fs(context, 15))),
            ]))
          : _results.isEmpty
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.search_off, color: AppColors.textSecondary,
                  size: isPhone ? 40 : 56),
                const SizedBox(height: 14),
                Text('Sin resultados para "${_ctrl.text}"',
                  style: TextStyle(color: AppColors.textSecondary,
                    fontSize: R.fs(context, 15))),
                const SizedBox(height: 6),
                const Text('Navega más canales para ampliar la búsqueda',
                  style: TextStyle(color: Colors.white30, fontSize: 12)),
              ]))
            : ListView.builder(
                padding: EdgeInsets.fromLTRB(p + 6, 0, p + 6, 40),
                itemCount: _results.length,
                itemBuilder: (_, i) {
                  final r  = _results[i];
                  final ch = _channelMap[r.streamId];
                  return _EpgResultTile(
                    entry:   r.entry,
                    channel: ch,
                    onTap:   () => _play(r.streamId),
                  );
                },
              ),
        ),
      ]),
    );
  }
}

// ─── Tile de resultado EPG ────────────────────────────────────────────────────
class _EpgResultTile extends StatefulWidget {
  final EpgEntry  entry;
  final Channel?  channel;
  final VoidCallback onTap;
  const _EpgResultTile({required this.entry, required this.channel, required this.onTap});
  @override State<_EpgResultTile> createState() => _EpgResultTileState();
}
class _EpgResultTileState extends State<_EpgResultTile> {
  bool _focused = false;
  final _fn = FocusNode();

  @override void initState() {
    super.initState();
    _fn.addListener(() { if (mounted) setState(() => _focused = _fn.hasFocus); });
  }
  @override void dispose() { _fn.dispose(); super.dispose(); }

  bool get _isNow {
    final now = DateTime.now();
    return widget.entry.start.isBefore(now) && widget.entry.end.isAfter(now);
  }

  @override
  Widget build(BuildContext context) {
    final ch = widget.channel;
    final sz = R.isPhone(context) ? 36.0 : 44.0;

    return InkWell(
      focusNode: _fn, focusColor: Colors.transparent, onTap: widget.onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: EdgeInsets.symmetric(
          horizontal: R.isPhone(context) ? 10 : 14,
          vertical:   R.isPhone(context) ? 8  : 10),
        decoration: BoxDecoration(
          color: _focused ? Colors.white12 : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _focused ? AppColors.celeste : Colors.transparent, width: 2)),
        child: Row(children: [
          // Logo del canal
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ch != null && ch.streamIcon.isNotEmpty
              ? CachedNetworkImage(imageUrl: ch.streamIcon,
                  width: sz, height: sz * 0.75, fit: BoxFit.contain,
                  errorWidget: (_, __, ___) => _iconBox(sz))
              : _iconBox(sz)),
          const SizedBox(width: 12),
          // Info
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Nombre del canal
              if (ch != null)
                Text(ch.name, style: const TextStyle(
                  color: Colors.white54, fontSize: 11),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 2),
              // Título del programa
              Text(widget.entry.title, style: TextStyle(
                color: _focused ? Colors.white : AppColors.textPrimary,
                fontSize: R.fs(context, 13),
                fontWeight: _focused ? FontWeight.w600 : FontWeight.normal),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              const SizedBox(height: 3),
              Row(children: [
                // Horario
                Icon(Icons.access_time_rounded,
                  color: Colors.white30, size: 11),
                const SizedBox(width: 3),
                Text(widget.entry.timeRange,
                  style: const TextStyle(color: Colors.white38, fontSize: 11)),
                const SizedBox(width: 8),
                // Badge "EN VIVO" si está al aire ahora
                if (_isNow)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.red.withOpacity(0.5))),
                    child: const Text('● AHORA',
                      style: TextStyle(color: Colors.red, fontSize: 9,
                        fontWeight: FontWeight.bold))),
              ]),
              // Barra de progreso si está al aire
              if (_isNow) ...[
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: widget.entry.progress,
                    minHeight: 2,
                    backgroundColor: Colors.white12,
                    valueColor: const AlwaysStoppedAnimation<Color>(AppColors.celeste),
                  ),
                ),
              ],
            ],
          )),
          const SizedBox(width: 8),
          // Bell reminder — only for upcoming programs
          if (widget.channel != null && widget.entry.start.isAfter(DateTime.now()))
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ReminderBell(
                channel: widget.channel!,
                program: widget.entry,
                size: 20,
              ),
            ),
          Icon(Icons.play_circle_outline_rounded,
            color: _focused ? AppColors.celeste : Colors.white24, size: 24),
        ]),
      ),
    );
  }

  Widget _iconBox(double sz) => Container(
    width: sz, height: sz * 0.75, color: AppColors.card,
    child: const Icon(Icons.tv, color: AppColors.celeste, size: 16));
}
