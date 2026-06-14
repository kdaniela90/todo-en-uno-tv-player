import 'package:flutter/material.dart';
import '../models/program_reminder.dart';
import '../services/reminder_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import 'live_screen.dart' show sectionAppBar;

class RemindersScreen extends StatefulWidget {
  const RemindersScreen({super.key});
  @override State<RemindersScreen> createState() => _RemindersScreenState();
}

class _RemindersScreenState extends State<RemindersScreen> {
  List<ProgramReminder> _reminders = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final list = await ReminderService.load();
    if (!mounted) return;
    // Only show non-expired
    setState(() {
      _reminders = list.where((r) => !r.isExpired).toList();
      _loading   = false;
    });
  }

  Future<void> _cancel(ProgramReminder r) async {
    await ReminderService.cancel(r.notificationId);
    if (!mounted) return;
    setState(() => _reminders.removeWhere((x) => x.notificationId == r.notificationId));
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Recordatorio cancelado: ${r.programTitle}'),
      backgroundColor: Colors.black87,
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: sectionAppBar(context, 'Recordatorios', Icons.notifications_rounded,
          const Color(0xFFFFB300)),
      body: _loading
        ? const Center(child: CircularProgressIndicator(color: AppColors.celeste))
        : _reminders.isEmpty
          ? _emptyState()
          : ListView.builder(
              padding: EdgeInsets.all(R.padding(context)),
              itemCount: _reminders.length,
              itemBuilder: (_, i) => _ReminderTile(
                reminder: _reminders[i],
                onCancel: () => _cancel(_reminders[i]),
              ),
            ),
    );
  }

  Widget _emptyState() => Center(
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.notifications_off_outlined, color: Colors.white24,
        size: R.isPhone(context) ? 48 : 64),
      const SizedBox(height: 14),
      const Text('Sin recordatorios pendientes',
        style: TextStyle(color: AppColors.textSecondary, fontSize: 15)),
      const SizedBox(height: 8),
      const Text(
        'Toca el icono de notificacion en cualquier\nprograma de la guia para agregar un recordatorio.',
        textAlign: TextAlign.center,
        style: TextStyle(color: Colors.white30, fontSize: 12)),
    ]),
  );
}

// ─── Tile de recordatorio ─────────────────────────────────────────────────────
class _ReminderTile extends StatefulWidget {
  final ProgramReminder reminder;
  final VoidCallback onCancel;
  const _ReminderTile({required this.reminder, required this.onCancel});
  @override State<_ReminderTile> createState() => _ReminderTileState();
}
class _ReminderTileState extends State<_ReminderTile> {
  bool _focused = false;
  final _fn = FocusNode();

  @override void initState() {
    super.initState();
    _fn.addListener(() { if (mounted) setState(() => _focused = _fn.hasFocus); });
  }
  @override void dispose() { _fn.dispose(); super.dispose(); }

  String get _timeLabel {
    final r = widget.reminder;
    final fireAt = r.fireAt;
    final now = DateTime.now();
    final diff = fireAt.difference(now);

    if (diff.inMinutes < 1)  return 'En menos de 1 min';
    if (diff.inHours < 1)    return 'En ${diff.inMinutes} min';
    if (diff.inHours < 24)   return 'En ${diff.inHours}h ${diff.inMinutes % 60}min';
    return 'El ${_dateLabel(fireAt)}';
  }

  String _dateLabel(DateTime dt) {
    final now = DateTime.now();
    if (dt.day == now.day + 1) return 'mañana a las ${_hm(dt)}';
    return '${dt.day}/${dt.month} a las ${_hm(dt)}';
  }

  String _hm(DateTime dt) =>
      '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  Color get _urgencyColor {
    final diff = widget.reminder.fireAt.difference(DateTime.now());
    if (diff.inMinutes < 10) return Colors.orange;
    if (diff.inHours   < 1)  return Colors.amber;
    return const Color(0xFFFFB300);
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.reminder;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: _focused ? Colors.white10 : AppColors.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _focused ? _urgencyColor : Colors.white10,
          width: _focused ? 2 : 1)),
      child: InkWell(
        focusNode: _fn, focusColor: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        onTap: () {},
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(children: [
            // Bell icon with urgency color
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: _urgencyColor.withOpacity(0.15),
                shape: BoxShape.circle),
              child: Icon(Icons.notifications_active_rounded,
                color: _urgencyColor, size: 20)),
            const SizedBox(width: 14),

            // Info
            Expanded(child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(r.programTitle,
                  style: TextStyle(
                    color: _focused ? Colors.white : AppColors.textPrimary,
                    fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 3),
                Text(r.channelName,
                  style: const TextStyle(color: Colors.white54, fontSize: 11)),
                const SizedBox(height: 4),
                Row(children: [
                  Icon(Icons.access_time_rounded, color: _urgencyColor, size: 12),
                  const SizedBox(width: 4),
                  Text(_timeLabel,
                    style: TextStyle(color: _urgencyColor, fontSize: 11,
                      fontWeight: FontWeight.w500)),
                  const SizedBox(width: 8),
                  Text(
                    r.minutesBefore == 0 ? '(al inicio)' : '(${r.minutesBefore} min antes)',
                    style: const TextStyle(color: Colors.white30, fontSize: 10)),
                ]),
                // Program start time
                const SizedBox(height: 2),
                Text(
                  'Programa: ${_hm(r.programStart)} – ${_hm(r.programEnd)}',
                  style: const TextStyle(color: Colors.white24, fontSize: 10)),
              ],
            )),
            const SizedBox(width: 8),

            // Cancel button
            IconButton(
              icon: const Icon(Icons.notifications_off_outlined,
                color: Colors.white38, size: 20),
              tooltip: 'Cancelar recordatorio',
              onPressed: widget.onCancel,
            ),
          ]),
        ),
      ),
    );
  }
}
