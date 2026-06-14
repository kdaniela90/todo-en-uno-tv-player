import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../models/epg_entry.dart';
import '../services/reminder_service.dart';
import '../theme/app_theme.dart';

// ─── Shows the reminder dialog and handles scheduling/cancelling ──────────────
Future<void> showReminderDialog(
  BuildContext context, {
  required Channel channel,
  required EpgEntry program,
}) async {
  final alreadySet = await ReminderService.hasReminder(channel.id, program.start);
  if (!context.mounted) return;

  final now  = DateTime.now();
  final diff = program.start.difference(now).inMinutes;

  // Options depend on how far away the program is
  final options = <({int minutes, String label})>[];
  if (diff > 5)  options.add((minutes: 5,  label: '5 minutos antes'));
  if (diff > 15) options.add((minutes: 15, label: '15 minutos antes'));
  if (diff > 1)  options.add((minutes: 0,  label: 'Al inicio del programa'));

  if (alreadySet) {
    // Show cancel option
    final cancel = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0D1020),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(children: [
          Icon(Icons.notifications_active_rounded, color: Color(0xFFFFB300), size: 22),
          SizedBox(width: 10),
          Text('Recordatorio activo', style: TextStyle(color: Colors.white, fontSize: 16)),
        ]),
        content: Column(mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(program.title,
            style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(channel.name,
            style: const TextStyle(color: Colors.white54, fontSize: 12)),
          const SizedBox(height: 4),
          Text('Inicia a las ${_hm(program.start)}',
            style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Mantener', style: TextStyle(color: Colors.white38))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancelar recordatorio',
              style: TextStyle(color: Colors.red))),
        ],
      ),
    );
    if (cancel == true) {
      await ReminderService.cancelForProgram(channel.id, program.start);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Recordatorio cancelado: ${program.title}'),
          backgroundColor: Colors.black87,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ));
      }
    }
    return;
  }

  // No reminder yet — show scheduling options
  if (options.isEmpty) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('El programa está por iniciar, no hay tiempo para recordatorio.'),
        backgroundColor: Colors.black87, behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: 2),
      ));
    }
    return;
  }

  final selected = await showDialog<int>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: const Color(0xFF0D1020),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Row(children: [
        Icon(Icons.notification_add_rounded, color: Color(0xFFFFB300), size: 22),
        SizedBox(width: 10),
        Expanded(child: Text('Agregar recordatorio',
          style: TextStyle(color: Colors.white, fontSize: 15))),
      ]),
      content: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(program.title,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
        const SizedBox(height: 2),
        Text(channel.name,
          style: const TextStyle(color: Colors.white54, fontSize: 12)),
        const SizedBox(height: 2),
        Text('Inicia a las ${_hm(program.start)}',
          style: const TextStyle(color: Colors.white38, fontSize: 11)),
        const SizedBox(height: 16),
        const Text('¿Cuándo quieres que te avisemos?',
          style: TextStyle(color: Colors.white60, fontSize: 12)),
        const SizedBox(height: 10),
        ...options.map((opt) => _OptionTile(
          label: opt.label,
          onTap: () => Navigator.pop(ctx, opt.minutes),
        )),
      ]),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancelar', style: TextStyle(color: Colors.white38))),
      ],
    ),
  );

  if (selected == null || !context.mounted) return;

  final ok = await ReminderService.schedule(
    program:       program,
    channel:       channel,
    minutesBefore: selected,
  );

  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
    content: Row(children: [
      const Icon(Icons.notifications_active_rounded,
        color: Colors.white, size: 16),
      const SizedBox(width: 8),
      Expanded(child: Text(ok
        ? (selected == 0
          ? 'Aviso programado al inicio de "${program.title}"'
          : 'Recordatorio: ${selected} min antes de "${program.title}"')
        : 'El programa ya inició, no se puede programar.')),
    ]),
    backgroundColor: ok ? AppColors.celeste.withOpacity(0.9) : Colors.red.shade800,
    behavior: SnackBarBehavior.floating,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
    duration: const Duration(seconds: 3),
  ));
}

// ─── Bell icon widget — use it anywhere ──────────────────────────────────────
class ReminderBell extends StatefulWidget {
  final Channel  channel;
  final EpgEntry program;
  final double   size;
  final bool     compact; // if true, skip loading check and always show

  const ReminderBell({
    super.key,
    required this.channel,
    required this.program,
    this.size    = 20,
    this.compact = false,
  });
  @override State<ReminderBell> createState() => _ReminderBellState();
}

class _ReminderBellState extends State<ReminderBell> {
  bool _hasReminder = false;
  bool _checking    = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void didUpdateWidget(ReminderBell old) {
    super.didUpdateWidget(old);
    if (old.program.start != widget.program.start ||
        old.channel.id    != widget.channel.id) {
      _check();
    }
  }

  Future<void> _check() async {
    if (!mounted) return;
    setState(() => _checking = true);
    final has = await ReminderService.hasReminder(
        widget.channel.id, widget.program.start);
    if (mounted) setState(() { _hasReminder = has; _checking = false; });
  }

  Future<void> _tap() async {
    await showReminderDialog(
      context,
      channel: widget.channel,
      program: widget.program,
    );
    await _check(); // Refresh state after dialog
  }

  @override
  Widget build(BuildContext context) {
    if (_checking && !widget.compact) return const SizedBox.shrink();

    // Don't show bell for past programs
    if (widget.program.start.isBefore(DateTime.now())) {
      return const SizedBox.shrink();
    }

    return GestureDetector(
      onTap: _tap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: Icon(
          _hasReminder
            ? Icons.notifications_active_rounded
            : Icons.notifications_none_rounded,
          key: ValueKey(_hasReminder),
          color: _hasReminder ? const Color(0xFFFFB300) : Colors.white30,
          size: widget.size,
        ),
      ),
    );
  }
}

// ── Internal helpers ──────────────────────────────────────────────────────────
class _OptionTile extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _OptionTile({required this.label, required this.onTap});
  @override State<_OptionTile> createState() => _OptionTileState();
}
class _OptionTileState extends State<_OptionTile> {
  bool _focused = false;
  final _fn = FocusNode();
  @override void initState() {
    super.initState();
    _fn.addListener(() { if (mounted) setState(() => _focused = _fn.hasFocus); });
  }
  @override void dispose() { _fn.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) => InkWell(
    focusNode: _fn, focusColor: Colors.transparent, onTap: widget.onTap,
    borderRadius: BorderRadius.circular(8),
    child: AnimatedContainer(
      duration: const Duration(milliseconds: 100),
      margin: const EdgeInsets.symmetric(vertical: 3),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: _focused ? const Color(0xFFFFB300).withOpacity(0.15) : Colors.white.withOpacity(0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _focused ? const Color(0xFFFFB300) : Colors.white12)),
      child: Row(children: [
        Icon(Icons.alarm_rounded,
          color: _focused ? const Color(0xFFFFB300) : Colors.white38, size: 16),
        const SizedBox(width: 10),
        Text(widget.label,
          style: TextStyle(
            color: _focused ? Colors.white : Colors.white70,
            fontSize: 13)),
      ]),
    ),
  );
}

String _hm(DateTime dt) =>
    '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
