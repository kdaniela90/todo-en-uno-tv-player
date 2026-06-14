import 'package:flutter/material.dart';
import '../models/category.dart';
import '../services/parental_service.dart';
import '../services/xtream_service.dart';
import '../theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PIN DIALOG
// Shows a 4-dot indicator + numeric keypad. Mode: 'enter' | 'setup' | 'confirm'
// Returns the entered PIN string, or null if cancelled.
// ─────────────────────────────────────────────────────────────────────────────
Future<String?> showPinDialog(BuildContext context, {
  String title = 'Ingresa tu PIN',
}) async {
  return showDialog<String>(
    context: context,
    barrierDismissible: true,
    builder: (_) => _PinDialog(title: title),
  );
}

class _PinDialog extends StatefulWidget {
  final String title;
  const _PinDialog({required this.title});
  @override State<_PinDialog> createState() => _PinDialogState();
}
class _PinDialogState extends State<_PinDialog> {
  String _pin = '';
  bool _shaking = false;

  void _press(String digit) {
    if (_pin.length >= 4) return;
    setState(() => _pin += digit);
    if (_pin.length == 4) {
      Future.delayed(const Duration(milliseconds: 120), () {
        if (mounted) Navigator.pop(context, _pin);
      });
    }
  }

  void _delete() { if (_pin.isNotEmpty) setState(() => _pin = _pin.substring(0, _pin.length - 1)); }

  void shake() {
    setState(() { _shaking = true; _pin = ''; });
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) setState(() => _shaking = false);
    });
  }

  @override
  Widget build(BuildContext context) => Dialog(
    backgroundColor: const Color(0xFF0D1020),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 28),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_outline, color: AppColors.celeste, size: 32),
        const SizedBox(height: 12),
        Text(widget.title,
          style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          textAlign: TextAlign.center),
        const SizedBox(height: 24),

        // 4 dots
        AnimatedSlide(
          offset: _shaking ? const Offset(0.04, 0) : Offset.zero,
          duration: const Duration(milliseconds: 80),
          child: Row(mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(4, (i) => Container(
              margin: const EdgeInsets.symmetric(horizontal: 8),
              width: 14, height: 14,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: i < _pin.length ? AppColors.celeste : Colors.white24,
                border: i >= _pin.length
                  ? Border.all(color: Colors.white38, width: 1.5) : null,
              ),
            ))),
        ),
        const SizedBox(height: 28),

        // Keypad
        ...[ ['1','2','3'], ['4','5','6'], ['7','8','9'], ['','0','⌫'] ]
          .map((row) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(mainAxisAlignment: MainAxisAlignment.center,
              children: row.map((k) => _Key(
                label: k,
                onTap: k.isEmpty ? null
                  : k == '⌫' ? _delete
                  : () => _press(k),
              )).toList()),
          )),

        const SizedBox(height: 4),
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancelar', style: TextStyle(color: Colors.white38, fontSize: 13))),
      ]),
    ),
  );
}

class _Key extends StatelessWidget {
  final String label;
  final VoidCallback? onTap;
  const _Key({required this.label, this.onTap});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 10),
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(40),
        child: Container(
          width: 60, height: 60,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: label.isEmpty ? Colors.transparent : Colors.white10,
          ),
          alignment: Alignment.center,
          child: label == '⌫'
            ? const Icon(Icons.backspace_outlined, color: Colors.white54, size: 20)
            : label.isEmpty ? const SizedBox()
            : Text(label, style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PARENTAL SETTINGS SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class ParentalScreen extends StatefulWidget {
  final XtreamService service;
  const ParentalScreen({super.key, required this.service});
  @override State<ParentalScreen> createState() => _ParentalScreenState();
}

class _ParentalScreenState extends State<ParentalScreen> with SingleTickerProviderStateMixin {
  late TabController _tabs;
  bool _loading = true;
  List<Category> _liveCats = [], _movieCats = [], _seriesCats = [];
  Set<String> _blockedLive = {}, _blockedMovies = {}, _blockedSeries = {};

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 3, vsync: this);
    _loadAll();
  }
  @override void dispose() { _tabs.dispose(); super.dispose(); }

  Future<void> _loadAll() async {
    final results = await Future.wait([
      widget.service.getLiveCategories(),
      widget.service.getVodCategories(),
      widget.service.getSeriesCategories(),
      ParentalService.getBlocked('live'),
      ParentalService.getBlocked('movies'),
      ParentalService.getBlocked('series'),
    ]);
    if (!mounted) return;
    setState(() {
      _liveCats    = results[0] as List<Category>;
      _movieCats   = results[1] as List<Category>;
      _seriesCats  = results[2] as List<Category>;
      _blockedLive    = results[3] as Set<String>;
      _blockedMovies  = results[4] as Set<String>;
      _blockedSeries  = results[5] as Set<String>;
      _loading = false;
    });
  }

  Future<void> _toggle(String type, String catId, bool newVisible) async {
    await ParentalService.setBlocked(type, catId, !newVisible);
    setState(() {
      if (type == 'live') {
        if (!newVisible) _blockedLive.add(catId); else _blockedLive.remove(catId);
      } else if (type == 'movies') {
        if (!newVisible) _blockedMovies.add(catId); else _blockedMovies.remove(catId);
      } else {
        if (!newVisible) _blockedSeries.add(catId); else _blockedSeries.remove(catId);
      }
    });
  }

  Future<void> _changePin() async {
    final newPin = await showPinDialog(context, title: 'Ingresa el nuevo PIN');
    if (newPin == null || newPin.length < 4) return;
    final confirm = await showPinDialog(context, title: 'Confirma el nuevo PIN');
    if (confirm == null) return;
    if (newPin != confirm) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Los PINs no coinciden'), backgroundColor: Colors.red));
      return;
    }
    await ParentalService.setPin(newPin);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('PIN actualizado ✓'), backgroundColor: AppColors.celeste));
  }

  Future<void> _disableParental() async {
    final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      backgroundColor: const Color(0xFF0D1020),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text('Desactivar control parental', style: TextStyle(color: Colors.white, fontSize: 15)),
      content: const Text('Se eliminarán el PIN y todos los bloqueos.', style: TextStyle(color: Colors.white60)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false),
          child: const Text('Cancelar', style: TextStyle(color: Colors.white38))),
        TextButton(onPressed: () => Navigator.pop(context, true),
          child: const Text('Desactivar', style: TextStyle(color: Colors.red))),
      ],
    ));
    if (ok == true) {
      await ParentalService.clearAll();
      if (mounted) Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: const Color(0xFF080B14),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new, color: Colors.white70, size: 20),
          onPressed: () => Navigator.pop(context)),
        title: const Row(children: [
          Icon(Icons.shield_outlined, color: AppColors.celeste, size: 20),
          SizedBox(width: 8),
          Text('Control Parental', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
        ]),
        actions: [
          TextButton.icon(
            onPressed: _changePin,
            icon: const Icon(Icons.pin_outlined, color: AppColors.celeste, size: 18),
            label: const Text('Cambiar PIN', style: TextStyle(color: AppColors.celeste, fontSize: 12)),
          ),
          TextButton(
            onPressed: _disableParental,
            child: const Text('Desactivar', style: TextStyle(color: Colors.red, fontSize: 12)),
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabs,
          indicatorColor: AppColors.celeste,
          labelColor: AppColors.celeste,
          unselectedLabelColor: Colors.white38,
          labelStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
          tabs: const [
            Tab(icon: Icon(Icons.live_tv, size: 18), text: 'TV en Vivo'),
            Tab(icon: Icon(Icons.movie_outlined, size: 18), text: 'Películas'),
            Tab(icon: Icon(Icons.tv_outlined, size: 18), text: 'Series'),
          ],
        ),
      ),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.celeste))
        : TabBarView(controller: _tabs, children: [
            _CatList(
              type: 'live', cats: _liveCats, blocked: _blockedLive,
              accentColor: AppColors.celeste, onToggle: _toggle),
            _CatList(
              type: 'movies', cats: _movieCats, blocked: _blockedMovies,
              accentColor: AppColors.azul, onToggle: _toggle),
            _CatList(
              type: 'series', cats: _seriesCats, blocked: _blockedSeries,
              accentColor: AppColors.morado, onToggle: _toggle),
          ]),
    );
  }
}

class _CatList extends StatelessWidget {
  final String type;
  final List<Category> cats;
  final Set<String> blocked;
  final Color accentColor;
  final Future<void> Function(String, String, bool) onToggle;

  const _CatList({
    required this.type, required this.cats, required this.blocked,
    required this.accentColor, required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    if (cats.isEmpty) return const Center(
      child: Text('Sin categorías', style: TextStyle(color: AppColors.textSecondary)));

    final visibleCount = cats.length - blocked.length;
    return Column(children: [
      // Summary bar
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        color: Colors.white.withOpacity(0.05),
        child: Text(
          '$visibleCount de ${cats.length} categorías visibles  ·  ${blocked.length} bloqueadas',
          style: TextStyle(color: accentColor, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
      Expanded(child: ListView.separated(
        itemCount: cats.length,
        separatorBuilder: (_, __) => Divider(color: Colors.white.withOpacity(0.07), height: 1),
        itemBuilder: (ctx, i) {
          final cat = cats[i];
          final isVisible = !blocked.contains(cat.id);
          return ListTile(
            leading: Icon(
              isVisible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
              color: isVisible ? accentColor : Colors.white24,
              size: 20,
            ),
            title: Text(cat.name,
              style: TextStyle(
                color: isVisible ? Colors.white : Colors.white38,
                fontSize: 14,
                decoration: isVisible ? null : TextDecoration.lineThrough,
                decorationColor: Colors.white24,
              )),
            trailing: Switch(
              value: isVisible,
              onChanged: (v) => onToggle(type, cat.id, v),
              activeColor: accentColor,
              activeTrackColor: accentColor.withOpacity(0.3),
              inactiveThumbColor: Colors.white24,
              inactiveTrackColor: Colors.white10,
            ),
          );
        },
      )),
    ]);
  }
}
