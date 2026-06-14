import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../models/category.dart';
import '../models/series.dart';
import '../services/xtream_service.dart';
import '../services/history_service.dart';
import '../services/parental_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'live_screen.dart' show sectionAppBar, CatTile;
import 'series_detail_screen.dart';

class SeriesScreen extends StatefulWidget {
  final XtreamService service;
  const SeriesScreen({super.key, required this.service});
  @override State<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends State<SeriesScreen> {
  List<Category> _categories = [];
  List<Series> _series = [];
  int _selectedCatIndex = 0;
  bool _loadingCats = true;
  bool _loadingSeries = false;
  final _catFocusNodes = <FocusNode>[];
  final _seriesFocusNodes = <FocusNode>[];

  // ── Búsqueda inline ──────────────────────────────────────────────────────
  bool _showSearch = false;
  String _searchQuery = '';
  final _searchCtrl = TextEditingController();
  List<Series> _allSeries = [];
  bool _loadingAll = false;

  List<Series> get _visibleSeries {
    if (_searchQuery.isEmpty) return _series;
    final pool = _allSeries.isNotEmpty ? _allSeries : _series;
    return pool.where((s) =>
        s.name.toLowerCase().contains(_searchQuery.toLowerCase())).toList();
  }

  static final _virtualCats = [
    Category(id: HistoryService.recentCatId, name: 'Recientes'),
    Category(id: HistoryService.favCatId,    name: 'Favoritos'),
  ];

  @override void initState() { super.initState(); _loadCategories(); }

  @override
  void dispose() {
    for (final n in _catFocusNodes) n.dispose();
    for (final n in _seriesFocusNodes) n.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadCategories() async {
    final results = await Future.wait([
      widget.service.getSeriesCategories(),
      ParentalService.getBlocked('series'),
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

  Future<void> _selectCategory(Category cat, int index) async {
    _searchCtrl.clear();
    setState(() { _selectedCatIndex = index; _loadingSeries = true; _series = []; _searchQuery = ''; });
    for (final n in _seriesFocusNodes) n.dispose();
    _seriesFocusNodes.clear();

    List<Series> s;
    if (cat.id == HistoryService.recentCatId) {
      final data = await HistoryService.getRecent(HistoryService.series);
      s = data.map((d) => _seriesFromMap(d)).toList();
    } else if (cat.id == HistoryService.favCatId) {
      final data = await HistoryService.getFavorites(HistoryService.series);
      s = data.map((d) => _seriesFromMap(d)).toList();
    } else {
      s = await widget.service.getSeries(categoryId: cat.id);
    }
    if (!mounted) return;
    _seriesFocusNodes.addAll(List.generate(s.length, (_) => FocusNode()));
    setState(() { _series = s; _loadingSeries = false; });
  }

  Series _seriesFromMap(Map<String, String> d) => Series(
    id: d['id'] ?? '', name: d['name'] ?? '',
    cover: d['icon'] ?? '', categoryId: '');

  Future<void> _loadAllSeries() async {
    if (_allSeries.isNotEmpty || _loadingAll) return;
    setState(() => _loadingAll = true);
    final all = await widget.service.getSeries();
    if (!mounted) return;
    setState(() { _allSeries = all; _loadingAll = false; });
  }

  @override
  Widget build(BuildContext context) {
    final cols = R.gridCols(context);
    final p    = R.padding(context);
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: sectionAppBar(context, 'Series', Icons.tv_outlined, AppColors.morado,
        actions: [
          IconButton(
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: Icon(
                _showSearch ? Icons.search_off_rounded : Icons.search_rounded,
                key: ValueKey(_showSearch),
                color: _showSearch ? AppColors.morado : Colors.white70, size: 22)),
            tooltip: 'Buscar serie',
            onPressed: () {
              final opening = !_showSearch;
              setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) { _searchCtrl.clear(); _searchQuery = ''; }
              });
              if (opening) _loadAllSeries();
            },
          ),
        ]),
      body: Column(children: [
        // ── Barra de búsqueda ──────────────────────────────────────────
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          child: _showSearch ? _buildSearchBar(context, AppColors.morado) : const SizedBox.shrink(),
        ),
        // ── Contenido ──────────────────────────────────────────────────
        Expanded(child: Row(children: [
          SizedBox(
            width: R.catPanelW(context),
            child: _loadingCats
              ? const Center(child: CircularProgressIndicator(color: AppColors.celeste))
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _categories.length,
                  itemBuilder: (_, i) => CatTile(
                    name: _categories[i].name,
                    isSelected: _selectedCatIndex == i,
                    accentColor: i < _virtualCats.length ? Colors.amber : AppColors.morado,
                    focusNode: _catFocusNodes[i],
                    autofocus: i == 0,
                    onSelect: () => _selectCategory(_categories[i], i),
                  )),
          ),
          Container(width: 1, color: Colors.white10),
          Expanded(child: (_loadingSeries || (_loadingAll && _searchQuery.isNotEmpty))
            ? const Center(child: CircularProgressIndicator(color: AppColors.morado))
            : _visibleSeries.isEmpty
              ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_searchQuery.isNotEmpty ? Icons.search_off : (
                    _selectedCatIndex < _virtualCats.length ? Icons.inbox_outlined : Icons.tv_outlined),
                    color: Colors.white24, size: 48),
                  const SizedBox(height: 12),
                  Text(_searchQuery.isNotEmpty
                    ? 'Sin resultados para "$_searchQuery"'
                    : (_selectedCatIndex < _virtualCats.length ? 'Aún no hay nada aquí' : 'Sin series'),
                    style: const TextStyle(color: AppColors.textSecondary, fontSize: 14)),
                ]))
              : GridView.builder(
                  padding: EdgeInsets.all(p),
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: cols, childAspectRatio: 0.65,
                    crossAxisSpacing: 6, mainAxisSpacing: 6),
                  itemCount: _visibleSeries.length,
                  itemBuilder: (_, i) => _SeriesCard(
                    series: _visibleSeries[i],
                    service: widget.service,
                    focusNode: i < _seriesFocusNodes.length ? _seriesFocusNodes[i] : FocusNode(),
                    autofocus: i == 0,
                    onFavChanged: () => _selectCategory(_categories[_selectedCatIndex], _selectedCatIndex),
                  ),
                )),
        ])),
      ]),
    );
  }

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
              hintText: 'Buscar serie...',
              hintStyle: TextStyle(color: AppColors.textSecondary),
              border: InputBorder.none,
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 12)),
            onChanged: (q) => setState(() => _searchQuery = q),
          )),
          if (_searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, color: Colors.white38, size: 16),
              onPressed: () { _searchCtrl.clear(); setState(() => _searchQuery = ''); }),
        ]),
      ),
    );
  }
}

class _SeriesCard extends StatefulWidget {
  final Series series;
  final XtreamService service;
  final FocusNode focusNode;
  final bool autofocus;
  final VoidCallback onFavChanged;
  const _SeriesCard({required this.series, required this.service,
    required this.focusNode, this.autofocus = false, required this.onFavChanged});
  @override State<_SeriesCard> createState() => _SeriesCardState();
}
class _SeriesCardState extends State<_SeriesCard> {
  bool _focused = false, _isFav = false;
  @override void initState() {
    super.initState();
    widget.focusNode.addListener(() { if (mounted) setState(() => _focused = widget.focusNode.hasFocus); });
    _loadFav();
  }
  Future<void> _loadFav() async {
    final f = await HistoryService.isFavorite(HistoryService.series, widget.series.id);
    if (mounted) setState(() => _isFav = f);
  }
  Future<void> _toggleFav() async {
    final newState = await HistoryService.toggleFavorite(
      HistoryService.series, widget.series.id,
      {'id': widget.series.id, 'name': widget.series.name, 'icon': widget.series.cover});
    if (mounted) { setState(() => _isFav = newState); widget.onFavChanged(); }
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
    InkWell(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      focusColor: Colors.transparent,
      onTap: () {
        HistoryService.addRecent(HistoryService.series,
          {'id': widget.series.id, 'name': widget.series.name, 'icon': widget.series.cover});
        Navigator.push(context, MaterialPageRoute(builder: (_) =>
          SeriesDetailScreen(series: widget.series, service: widget.service)));
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        transform: Matrix4.identity()..scale(_focused ? 1.04 : 1.0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _focused ? AppColors.morado : Colors.white12, width: _focused ? 2 : 1),
          boxShadow: _focused ? [BoxShadow(color: AppColors.morado.withOpacity(0.5), blurRadius: 10)] : [],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(7),
          child: Stack(fit: StackFit.expand, children: [
            widget.series.cover.isNotEmpty
              ? CachedNetworkImage(imageUrl: widget.series.cover, fit: BoxFit.cover,
                  placeholder: (_, __) => _ph(), errorWidget: (_, __, ___) => _ph())
              : _ph(),
            Positioned(bottom: 0, left: 0, right: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 5),
                decoration: const BoxDecoration(gradient: LinearGradient(
                  begin: Alignment.bottomCenter, end: Alignment.topCenter,
                  colors: [Color(0xE6000000), Colors.transparent])),
                child: Text(widget.series.name,
                  style: TextStyle(color: Colors.white, fontSize: R.fs(context, 10), fontWeight: FontWeight.w600),
                  maxLines: 2, overflow: TextOverflow.ellipsis))),
          ]),
        ),
      ),
    ),
  ]);
  Widget _ph() => Container(color: AppColors.card,
    child: const Icon(Icons.tv_outlined, color: AppColors.morado, size: 28));
}
