import 'package:flutter/material.dart';
import '../services/xtream_service.dart';
import '../theme/app_theme.dart';
import 'live_screen.dart';
import 'movies_screen.dart';
import 'series_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  final Map<String, String> credentials;
  const HomeScreen({super.key, required this.credentials});
  @override State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  late XtreamService _service;

  static const _navItems = [
    _NavItem(icon: Icons.live_tv,          label: 'En Vivo'),
    _NavItem(icon: Icons.movie_outlined,   label: 'Películas'),
    _NavItem(icon: Icons.tv,               label: 'Series'),
    _NavItem(icon: Icons.search,           label: 'Buscar'),
    _NavItem(icon: Icons.settings_outlined,label: 'Ajustes'),
  ];

  @override
  void initState() {
    super.initState();
    _service = XtreamService(
      server: widget.credentials['server']!,
      username: widget.credentials['username']!,
      password: widget.credentials['password']!,
    );
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      LiveScreen(service: _service),
      MoviesScreen(service: _service),
      SeriesScreen(service: _service),
      SearchScreen(service: _service),
      SettingsScreen(credentials: widget.credentials),
    ];

    return Scaffold(
      backgroundColor: AppColors.background,
      body: Row(children: [
        // LEFT NAV RAIL
        Container(
          width: 76,
          color: const Color(0xFF080B14),
          child: Column(children: [
            const SizedBox(height: 14),
            Image.asset('assets/images/logo.png', width: 46,
              errorBuilder: (_, __, ___) => const Icon(Icons.tv, color: AppColors.celeste, size: 32)),
            const SizedBox(height: 16),
            const Divider(color: Colors.white12, height: 1),
            const SizedBox(height: 8),
            ...List.generate(_navItems.length, (i) => _NavRailItem(
              icon: _navItems[i].icon,
              label: _navItems[i].label,
              isActive: _currentIndex == i,
              autofocus: i == 0,
              onTap: () => setState(() => _currentIndex = i),
            )),
          ]),
        ),
        Container(width: 1, color: Colors.white10),
        Expanded(child: IndexedStack(index: _currentIndex, children: screens)),
      ]),
    );
  }
}

class _NavItem {
  final IconData icon;
  final String label;
  const _NavItem({required this.icon, required this.label});
}

class _NavRailItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool isActive;
  final bool autofocus;
  final VoidCallback onTap;
  const _NavRailItem({required this.icon, required this.label, required this.isActive,
    required this.autofocus, required this.onTap});
  @override State<_NavRailItem> createState() => _NavRailItemState();
}

class _NavRailItemState extends State<_NavRailItem> {
  bool _focused = false;
  @override
  Widget build(BuildContext context) {
    final highlight = widget.isActive || _focused;
    // InkWell responds to Enter/Select on TV remote (unlike GestureDetector)
    return InkWell(
      autofocus: widget.autofocus,
      focusColor: Colors.transparent,
      onTap: widget.onTap,
      onFocusChange: (f) => setState(() => _focused = f),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: widget.isActive
              ? AppColors.celeste.withOpacity(0.18)
              : (_focused ? Colors.white10 : Colors.transparent),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: _focused ? AppColors.celeste : Colors.transparent, width: 2),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(widget.icon,
            color: highlight ? AppColors.celeste : AppColors.textSecondary, size: 26),
          const SizedBox(height: 4),
          Text(widget.label,
            style: TextStyle(
              color: highlight ? AppColors.celeste : AppColors.textSecondary,
              fontSize: 9, fontWeight: highlight ? FontWeight.w600 : FontWeight.normal),
            textAlign: TextAlign.center),
        ]),
      ),
    );
  }
}
