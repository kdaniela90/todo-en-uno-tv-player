import 'dart:async';
import 'dart:math' as math;
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../theme/app_theme.dart';

// ─── Entry point ─────────────────────────────────────────────────────────────
Future<void> showSpeedTestSheet(BuildContext context, {required String serverUrl}) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    isDismissible: true,
    builder: (_) => SpeedTestSheet(serverUrl: serverUrl),
  );
}

// ─── States ───────────────────────────────────────────────────────────────────
enum _Phase { idle, pingTest, downloadTest, done, error }

// ─── Main sheet ───────────────────────────────────────────────────────────────
class SpeedTestSheet extends StatefulWidget {
  final String serverUrl;
  const SpeedTestSheet({super.key, required this.serverUrl});
  @override State<SpeedTestSheet> createState() => _SpeedTestSheetState();
}

class _SpeedTestSheetState extends State<SpeedTestSheet>
    with SingleTickerProviderStateMixin {

  _Phase   _phase           = _Phase.idle;
  double   _speedMbps       = 0;    // resultado final descarga
  int      _latencyMs       = -1;   // resultado ping
  double   _gaugeTarget     = 0;    // 0.0–1.0 para la aguja al terminar
  double   _liveGauge       = 0;    // 0.0–1.0 en tiempo real durante descarga
  double   _liveMbps        = 0;    // Mbps en tiempo real (mostrado en el gauge)
  String   _activeUrl       = '';   // hostname del servidor activo
  String   _connectionLabel = '';   // WiFi / Ethernet / Datos móviles

  late AnimationController _animCtrl;
  late Animation<double>   _gaugeAnim;

  static const _maxScale = 50.0; // 50 Mbps = 100 % en el gauge

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 1200));
    _gaugeAnim = const AlwaysStoppedAnimation(0);
    _detectConnection();
  }

  @override
  void dispose() { _animCtrl.dispose(); super.dispose(); }

  // ── Detectar tipo de red ─────────────────────────────────────────────────

  Future<void> _detectConnection() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (!mounted) return;
      for (final r in results) {
        if (r == ConnectivityResult.ethernet) {
          setState(() => _connectionLabel = 'Ethernet');
          return;
        }
        if (r == ConnectivityResult.wifi) {
          setState(() => _connectionLabel = 'WiFi');
          return;
        }
        if (r == ConnectivityResult.mobile) {
          setState(() => _connectionLabel = 'Datos móviles');
          return;
        }
      }
    } catch (_) {}
  }

  // ── Test logic ──────────────────────────────────────────────────────────

  Future<void> _runTest() async {
    _animCtrl.reset();
    setState(() {
      _phase     = _Phase.pingTest;
      _latencyMs = -1;
      _speedMbps = 0;
      _liveGauge = 0;
      _liveMbps  = 0;
      _activeUrl = '';
    });

    // ── 1. Ping — prueba el servidor IPTV, con fallback a Cloudflare ───
    _latencyMs = await _measurePing(widget.serverUrl)
        ?? await _measurePing('https://1.1.1.1')
        ?? -1;
    if (mounted) setState(() {});

    if (!mounted) return;
    setState(() => _phase = _Phase.downloadTest);

    // ── 2. Velocidad de descarga — streaming real (20 MB) ─────────────
    // 3 URLs en cascada; la primera que responda gana
    final result =
        await _downloadSpeedMbps('https://speed.cloudflare.com/__down?bytes=20000000')
     ?? await _downloadSpeedMbps('https://proof.ovh.net/files/10Mb.dat')
     ?? await _downloadSpeedMbps('https://httpbin.org/bytes/1000000')
     ?? -1.0;

    if (!mounted) return;

    _speedMbps   = result;
    _gaugeTarget = result < 0 ? 0 : (result / _maxScale).clamp(0.0, 1.0);

    // Anima desde la posición live actual hasta el resultado final
    _gaugeAnim = Tween<double>(begin: _liveGauge, end: _gaugeTarget).animate(
        CurvedAnimation(parent: _animCtrl, curve: Curves.easeOut));
    _animCtrl.forward();

    setState(() => _phase = result < 0 ? _Phase.error : _Phase.done);
  }

  /// Mide el tiempo de respuesta (HEAD) a una URL. Devuelve null si falla.
  Future<int?> _measurePing(String url) async {
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return null;
      final sw = Stopwatch()..start();
      await http.head(uri).timeout(const Duration(seconds: 5));
      sw.stop();
      return sw.elapsedMilliseconds;
    } catch (_) { return null; }
  }

  /// Descarga en streaming con actualizaciones en tiempo real del gauge.
  /// Devuelve Mbps finales o null si falla.
  Future<double?> _downloadSpeedMbps(String url) async {
    final client = http.Client();
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) return null;

      // Mostrar hostname para transparencia
      if (mounted) setState(() => _activeUrl = uri.host);

      final sw = Stopwatch()..start();
      final response = await client
          .send(http.Request('GET', uri))
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return null;

      // Streaming con actualización del gauge cada ~200 ms
      int totalBytes = 0;
      int lastUpdateMs = 0;
      final completer = Completer<int>();

      response.stream
          .timeout(const Duration(seconds: 60))
          .listen(
        (chunk) {
          totalBytes += chunk.length;
          final nowMs = sw.elapsedMilliseconds;
          if (nowMs - lastUpdateMs >= 200 && totalBytes > 20000 && mounted) {
            lastUpdateMs = nowMs;
            final secs = nowMs / 1000.0;
            final mbps = (totalBytes * 8) / (secs * 1000000);
            setState(() {
              _liveMbps  = mbps;
              _liveGauge = (mbps / _maxScale).clamp(0.0, 1.0);
            });
          }
        },
        onDone:       () => completer.complete(totalBytes),
        onError:      (_) => completer.complete(totalBytes),
        cancelOnError: false,
      );
      totalBytes = await completer.future;

      sw.stop();
      final seconds = sw.elapsedMilliseconds / 1000.0;
      if (seconds < 0.1 || totalBytes < 50000) return null;
      return (totalBytes * 8) / (seconds * 1000000);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  // ── Rating ──────────────────────────────────────────────────────────────

  ({Color color, Color glow, IconData icon, String title, String detail}) get _rating {
    if (_speedMbps < 0) return (
      color: Colors.red, glow: Colors.red,
      icon: Icons.signal_wifi_off_rounded,
      title: 'Sin datos',
      detail: 'No se pudo medir la velocidad');
    if (_speedMbps < 2) return (
      color: Colors.red, glow: Colors.red,
      icon: Icons.warning_rounded,
      title: 'Velocidad baja',
      detail: 'Buffering probable en canales SD');
    if (_speedMbps < 5) return (
      color: Colors.orange, glow: Colors.orangeAccent,
      icon: Icons.signal_wifi_statusbar_connected_no_internet_4_rounded,
      title: 'Apenas suficiente',
      detail: 'Streaming SD estable, HD con cortes');
    if (_speedMbps < 10) return (
      color: Colors.amber, glow: Colors.amber,
      icon: Icons.wifi_rounded,
      title: 'Bueno para HD',
      detail: 'HD 720p/1080p sin problemas');
    if (_speedMbps < 25) return (
      color: const Color(0xFF66BB6A), glow: Colors.green,
      icon: Icons.wifi_rounded,
      title: 'Muy buena',
      detail: 'HD sin cortes · 4K posible');
    return (
      color: AppColors.celeste, glow: AppColors.celeste,
      icon: Icons.rocket_launch_rounded,
      title: 'Excelente',
      detail: 'Streaming 4K sin problemas');
  }

  String get _phaseLabel {
    switch (_phase) {
      case _Phase.pingTest:     return 'Midiendo latencia al servidor…';
      case _Phase.downloadTest: return 'Midiendo velocidad de descarga…';
      default: return '';
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Color(0xFF0D1020),
        borderRadius: BorderRadius.vertical(top: Radius.circular(24))),
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [

        // Handle
        Container(
          width: 36, height: 3,
          margin: const EdgeInsets.only(bottom: 20),
          decoration: BoxDecoration(
            color: Colors.white24, borderRadius: BorderRadius.circular(2))),

        // Header
        Row(children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: AppColors.celeste.withOpacity(0.15),
              borderRadius: BorderRadius.circular(10)),
            child: const Icon(Icons.speed_rounded, color: AppColors.celeste, size: 22)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Prueba de Velocidad',
                style: TextStyle(color: Colors.white, fontSize: 16,
                  fontWeight: FontWeight.bold)),
              const Text('Diagnóstico de tu conexión',
                style: TextStyle(color: Colors.white38, fontSize: 11)),
            ])),
          // Chip tipo de red
          if (_connectionLabel.isNotEmpty)
            _ConnChip(label: _connectionLabel),
        ]),

        const SizedBox(height: 28),

        // ── Gauge ─────────────────────────────────────────────────────
        SizedBox(
          width: 200, height: 120,
          child: AnimatedBuilder(
            animation: _gaugeAnim,
            builder: (_, __) {
              // Durante descarga: valor en tiempo real.
              // Al terminar o en idle/ping: animación final.
              final gaugeVal = (_phase == _Phase.downloadTest)
                  ? _liveGauge
                  : _gaugeAnim.value;
              return CustomPaint(
                painter: _GaugePainter(
                  value:   gaugeVal,
                  maxMbps: _maxScale,
                  color:   (_phase == _Phase.done || _phase == _Phase.error)
                               ? _rating.color : AppColors.celeste,
                  pulsing: _phase == _Phase.pingTest,
                ),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 18),
                    child: _gaugeCenter(),
                  )),
              );
            },
          )),

        const SizedBox(height: 8),

        // Scale labels
        SizedBox(
          width: 200,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: const [
              Text('0',  style: TextStyle(color: Colors.white24, fontSize: 10)),
              Text('25', style: TextStyle(color: Colors.white24, fontSize: 10)),
              Text('50+ Mbps', style: TextStyle(color: Colors.white24, fontSize: 10)),
            ])),

        const SizedBox(height: 24),

        // ── Results card ───────────────────────────────────────────────
        if (_phase == _Phase.done || _phase == _Phase.error)
          _ResultsCard(
            latencyMs: _latencyMs,
            speedMbps: _speedMbps,
            rating:    _rating),

        // ── Progress label ─────────────────────────────────────────────
        if (_phase == _Phase.pingTest || _phase == _Phase.downloadTest)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(children: [
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                SizedBox(
                  width: 14, height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppColors.celeste)),
                const SizedBox(width: 10),
                Text(_phaseLabel,
                  style: const TextStyle(color: Colors.white54, fontSize: 12)),
              ]),
              // Servidor activo (transparencia)
              if (_activeUrl.isNotEmpty) ...[
                const SizedBox(height: 6),
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.dns_outlined, color: Colors.white24, size: 12),
                  const SizedBox(width: 4),
                  Text('Servidor: $_activeUrl',
                    style: const TextStyle(color: Colors.white24, fontSize: 10)),
                ]),
              ],
            ])),

        const SizedBox(height: 16),

        // ── Action buttons ─────────────────────────────────────────────
        Row(children: [
          Expanded(
            child: OutlinedButton.icon(
              icon: const Icon(Icons.close, size: 16),
              label: const Text('Cerrar'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white54,
                side: const BorderSide(color: Colors.white24),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: () => Navigator.pop(context))),
          const SizedBox(width: 12),
          Expanded(
            child: ElevatedButton.icon(
              icon: Icon(
                _phase == _Phase.done || _phase == _Phase.error
                    ? Icons.refresh_rounded : Icons.play_arrow_rounded,
                size: 18),
              label: Text(
                _phase == _Phase.idle ? 'Iniciar prueba'
                  : _phase == _Phase.done || _phase == _Phase.error
                    ? 'Repetir prueba' : 'Probando…'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.celeste,
                foregroundColor: Colors.white,
                disabledBackgroundColor: AppColors.celeste.withOpacity(0.4),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                padding: const EdgeInsets.symmetric(vertical: 13)),
              onPressed: (_phase == _Phase.pingTest || _phase == _Phase.downloadTest)
                  ? null : _runTest)),
        ]),

        // Nota al pie
        const SizedBox(height: 12),
        const Text(
          'La prueba descarga ~20 MB de datos para medir la velocidad real.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white24, fontSize: 10)),
      ]),
    );
  }

  // ── Gauge center content ─────────────────────────────────────────────────

  Widget _gaugeCenter() {
    if (_phase == _Phase.idle) {
      return const Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.play_circle_outline_rounded, color: Colors.white24, size: 28),
        SizedBox(height: 4),
        Text('Presiona\nIniciar prueba', textAlign: TextAlign.center,
          style: TextStyle(color: Colors.white30, fontSize: 10)),
      ]);
    }
    if (_phase == _Phase.pingTest) {
      return const Column(mainAxisSize: MainAxisSize.min, children: [
        Text('…', style: TextStyle(color: Colors.white54, fontSize: 28,
          fontWeight: FontWeight.bold)),
        Text('Mbps', style: TextStyle(color: Colors.white24, fontSize: 11)),
      ]);
    }
    if (_phase == _Phase.downloadTest) {
      // Velocidad en tiempo real
      final display = _liveMbps >= 100
          ? _liveMbps.toStringAsFixed(0)
          : _liveMbps.toStringAsFixed(1);
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(display,
          style: const TextStyle(color: AppColors.celeste, fontSize: 28,
            fontWeight: FontWeight.bold)),
        const Text('Mbps', style: TextStyle(color: Colors.white54, fontSize: 11)),
      ]);
    }
    if (_speedMbps < 0) {
      return const Icon(Icons.error_outline, color: Colors.red, size: 28);
    }
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Text(
        _speedMbps >= 100
          ? _speedMbps.toStringAsFixed(0)
          : _speedMbps.toStringAsFixed(1),
        style: TextStyle(
          color: _rating.color, fontSize: 28,
          fontWeight: FontWeight.bold)),
      const Text('Mbps', style: TextStyle(color: Colors.white54, fontSize: 11)),
    ]);
  }
}

// ─── Connection type chip ─────────────────────────────────────────────────────
class _ConnChip extends StatelessWidget {
  final String label;
  const _ConnChip({required this.label});

  IconData get _icon {
    if (label == 'Ethernet')      return Icons.cable_rounded;
    if (label == 'Datos móviles') return Icons.signal_cellular_alt_rounded;
    return Icons.wifi_rounded;
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Colors.white.withOpacity(0.07),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: Colors.white.withOpacity(0.12))),
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(_icon, color: Colors.white54, size: 12),
      const SizedBox(width: 4),
      Text(label,
        style: const TextStyle(color: Colors.white54, fontSize: 11)),
    ]),
  );
}

// ─── Results card ─────────────────────────────────────────────────────────────
class _ResultsCard extends StatelessWidget {
  final int latencyMs;
  final double speedMbps;
  final ({Color color, Color glow, IconData icon, String title, String detail}) rating;

  const _ResultsCard({
    required this.latencyMs,
    required this.speedMbps,
    required this.rating,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: rating.color.withOpacity(0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: rating.color.withOpacity(0.3))),
      child: Column(children: [

        // Rating badge
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: rating.color.withOpacity(0.15),
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(
                color: rating.glow.withOpacity(0.3),
                blurRadius: 12)]),
            child: Icon(rating.icon, color: rating.color, size: 22)),
          const SizedBox(width: 12),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(rating.title,
              style: TextStyle(color: rating.color, fontSize: 15,
                fontWeight: FontWeight.bold)),
            Text(rating.detail,
              style: const TextStyle(color: Colors.white60, fontSize: 11)),
          ]),
        ]),

        const SizedBox(height: 14),
        const Divider(color: Colors.white10, height: 1),
        const SizedBox(height: 14),

        // Metrics row
        Row(children: [
          _Metric(
            label: 'Descarga',
            value: speedMbps < 0 ? 'N/D' : '${speedMbps.toStringAsFixed(1)} Mbps',
            icon: Icons.download_rounded,
            color: rating.color),
          Container(width: 1, height: 36, color: Colors.white10),
          _Metric(
            label: 'Latencia',
            value: latencyMs < 0 ? 'N/D' : '$latencyMs ms',
            icon: Icons.network_ping_rounded,
            color: _latencyColor(latencyMs)),
          Container(width: 1, height: 36, color: Colors.white10),
          _Metric(
            label: 'Calidad',
            value: _qualityLabel(speedMbps),
            icon: Icons.tv_rounded,
            color: rating.color),
        ]),

      ]),
    );
  }

  Color _latencyColor(int ms) {
    if (ms < 0)   return Colors.grey;
    if (ms < 80)  return Colors.green;
    if (ms < 200) return Colors.amber;
    return Colors.red;
  }

  String _qualityLabel(double mbps) {
    if (mbps < 0)   return 'N/D';
    if (mbps < 2)   return 'SD bajo';
    if (mbps < 5)   return 'SD';
    if (mbps < 15)  return 'HD';
    if (mbps < 25)  return 'FHD';
    return '4K';
  }
}

class _Metric extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _Metric({required this.label, required this.value,
    required this.icon, required this.color});

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(children: [
      Icon(icon, color: color, size: 16),
      const SizedBox(height: 4),
      Text(value, style: TextStyle(color: color, fontSize: 13,
        fontWeight: FontWeight.bold)),
      Text(label, style: const TextStyle(color: Colors.white38, fontSize: 10)),
    ]),
  );
}

// ─── Gauge painter ────────────────────────────────────────────────────────────
class _GaugePainter extends CustomPainter {
  final double value;    // 0.0 – 1.0
  final double maxMbps;
  final Color  color;
  final bool   pulsing;

  _GaugePainter({
    required this.value,
    required this.maxMbps,
    required this.color,
    required this.pulsing,
  });

  // Arc: starts at 210° (bottom-left), sweeps 240° clockwise to bottom-right
  static const _startDeg = 210.0;
  static const _sweepDeg = 240.0;
  static const _startRad = _startDeg * math.pi / 180;
  static const _sweepRad = _sweepDeg * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final cx   = size.width  / 2;
    final cy   = size.height * 0.80;
    final r    = math.min(cx, cy) - 6;
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    // Background track
    final bgPaint = Paint()
      ..style       = PaintingStyle.stroke
      ..strokeWidth = 10
      ..strokeCap   = StrokeCap.round
      ..color       = Colors.white10;
    canvas.drawArc(rect, _startRad, _sweepRad, false, bgPaint);

    // Colored fill
    if (value > 0 || pulsing) {
      final fillSweep = pulsing ? _sweepRad * 0.05 : _sweepRad * value;
      final fgPaint = Paint()
        ..style       = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap   = StrokeCap.round
        ..shader      = SweepGradient(
            startAngle: _startRad,
            endAngle:   _startRad + _sweepRad,
            colors: const [
              Color(0xFF4CAF50),
              Color(0xFFFFEB3B),
              Color(0xFFFF9800),
              Color(0xFFF44336),
            ],
            stops: const [0.0, 0.35, 0.65, 1.0],
          ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r + 5));
      canvas.drawArc(rect, _startRad, fillSweep, false, fgPaint);
    }

    // Tick marks
    final tickPaint = Paint()
      ..color       = Colors.white24
      ..strokeWidth = 1.5;
    for (int i = 0; i <= 5; i++) {
      final angle  = _startRad + _sweepRad * (i / 5);
      final innerR = r - 12;
      final outerR = r + 1;
      canvas.drawLine(
        Offset(cx + innerR * math.cos(angle), cy + innerR * math.sin(angle)),
        Offset(cx + outerR * math.cos(angle), cy + outerR * math.sin(angle)),
        tickPaint);
    }

    // Needle
    if (value > 0 && !pulsing) {
      final needleAngle = _startRad + _sweepRad * value;
      final needleR     = r - 4;
      final nx = cx + needleR * math.cos(needleAngle);
      final ny = cy + needleR * math.sin(needleAngle);
      canvas.drawLine(
        Offset(cx, cy), Offset(nx, ny),
        Paint()
          ..color       = color
          ..strokeWidth = 2.5
          ..strokeCap   = StrokeCap.round);
      canvas.drawCircle(Offset(nx, ny), 4, Paint()..color = color);
    }

    // Center dot
    canvas.drawCircle(Offset(cx, cy), 5, Paint()..color = Colors.white24);
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.value != value || old.color != color || old.pulsing != pulsing;
}
