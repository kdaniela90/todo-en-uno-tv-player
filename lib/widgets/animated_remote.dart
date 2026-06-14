import 'package:flutter/material.dart';
import 'dart:math';
import 'dart:ui' as ui;

class AnimatedRemote extends StatefulWidget {
  final double width;
  final double height;
  const AnimatedRemote({super.key, required this.width, required this.height});
  @override State<AnimatedRemote> createState() => _AnimatedRemoteState();
}

class _AnimatedRemoteState extends State<AnimatedRemote>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this,
        duration: const Duration(seconds: 20))
      ..repeat();
  }

  @override void dispose() { _ctrl.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _ctrl,
    builder: (_, __) => CustomPaint(
      size: Size(widget.width, widget.height),
      painter: _RemotePainter(t: _ctrl.value * 20.0),
    ),
  );
}

class _RemotePainter extends CustomPainter {
  final double t;
  const _RemotePainter({required this.t});
  @override bool shouldRepaint(_RemotePainter o) => o.t != t;

  Path _pill(double x, double y, double pw, double ph, double r) {
    final p = Path();
    p.moveTo(x + r, y);
    p.lineTo(x + pw - r, y);
    p.quadraticBezierTo(x + pw, y, x + pw, y + r);
    p.lineTo(x + pw, y + ph - r);
    p.quadraticBezierTo(x + pw, y + ph, x + pw - r, y + ph);
    p.lineTo(x + r, y + ph);
    p.quadraticBezierTo(x, y + ph, x, y + ph - r);
    p.lineTo(x, y + r);
    p.quadraticBezierTo(x, y, x + r, y);
    p.close();
    return p;
  }

  Color _hsl(double h, double s, double l) =>
      HSLColor.fromAHSL(1.0, h % 360,
          (s / 100).clamp(0.0, 1.0), (l / 100).clamp(0.0, 1.0)).toColor();

  static int _a(double opacity) => (opacity.clamp(0.0, 1.0) * 255).round();

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final pad = w * 0.04;
    final rx  = (w - pad * 2) / 2;

    final hS  = sin(t * 0.4) * 18;
    final sS  = sin(t * 0.3) * 8;
    final cTop = _hsl(182 + hS, 76 + sS, 63);
    final cMid = _hsl(219 + hS * 0.5, 75, 56);
    final cBot = _hsl(271 + hS * 0.3, 84, 55);

    // 1. Body gradient
    final pillPath = _pill(pad, pad, w - pad*2, h - pad*2, rx);
    canvas.drawPath(pillPath, Paint()..shader = ui.Gradient.linear(
      Offset.zero, Offset(w, h),
      [cTop, cMid, cBot], [0.0, 0.5, 1.0]));

    // 2. Gloss
    canvas.drawPath(
      _pill(pad, pad, w - pad*2, (h - pad*2) * 0.5, rx),
      Paint()..shader = ui.Gradient.radial(
        Offset(w * 0.5, h * 0.18), w * 0.5,
        [const Color(0x2EFFFFFF), const Color(0x00FFFFFF)], [0.0, 1.0]));

    // 3. Scan line
    final scanPxY = pad + (h - pad*2) * ((t * 0.55) % 1.0);
    canvas.save();
    canvas.clipPath(pillPath);
    canvas.drawRect(Rect.fromLTWH(0, scanPxY - 8, w, 16),
      Paint()..shader = ui.Gradient.linear(
        Offset(0, scanPxY - 8), Offset(0, scanPxY + 8),
        [const Color(0x00FFFFFF), const Color(0x38FFFFFF), const Color(0x00FFFFFF)],
        [0.0, 0.5, 1.0]));
    canvas.restore();

    // 4. LED
    final ledA = (0.5 + sin(t * 1.8) * 0.4).clamp(0.1, 0.9);
    final ledY = pad + (h - pad*2) * 0.072;
    canvas.drawCircle(Offset(w * 0.5, ledY), w * 0.18,
      Paint()..shader = ui.Gradient.radial(
        Offset(w * 0.5, ledY), w * 0.18,
        [Color.fromARGB(_a(ledA * 0.4), 255, 255, 255), const Color(0x00FFFFFF)],
        [0.0, 1.0]));
    canvas.drawCircle(Offset(w * 0.5, ledY), w * 0.045,
      Paint()..color = Color.fromARGB(_a(ledA), 255, 255, 255));

    // 5. Play ring
    final playY  = pad + (h - pad*2) * 0.40;
    final playR  = w * 0.36;
    final bScale = 1 + sin(t * 2.2) * 0.14;
    final bAlpha = (0.10 + sin(t * 2.2) * 0.07).clamp(0.0, 1.0);
    canvas.drawCircle(Offset(w * 0.5, playY), playR * bScale,
      Paint()..color = Color.fromARGB(_a(bAlpha), 255, 255, 255));
    canvas.drawCircle(Offset(w * 0.5, playY), playR * 0.78,
      Paint()..color = const Color(0x21FFFFFF));

    // 6. Pulse ring
    final pulse = (t * 0.5) % 1.0;
    if (pulse < 0.8) {
      canvas.drawCircle(Offset(w * 0.5, playY),
        playR + pulse * playR * 1.6,
        Paint()
          ..color       = Color.fromARGB(_a((1 - pulse / 0.8) * 0.22), 255, 255, 255)
          ..style       = PaintingStyle.stroke
          ..strokeWidth = w * 0.025);
    }

    // 7. Triangle
    final triA = (0.9 + sin(t * 2.2) * 0.08).clamp(0.0, 1.0);
    canvas.drawPath(
      Path()
        ..moveTo(w * 0.28, playY - playR * 0.58)
        ..lineTo(w * 0.28, playY + playR * 0.58)
        ..lineTo(w * 0.74, playY)
        ..close(),
      Paint()..color = Color.fromARGB(_a(triA), 255, 255, 255));

    // 8. Divider
    canvas.drawLine(
      Offset(w * 0.20, pad + (h - pad*2) * 0.68),
      Offset(w * 0.80, pad + (h - pad*2) * 0.68),
      Paint()..color = const Color(0x24FFFFFF)..strokeWidth = 1);

    // 9. Three dots
    final dotY = pad + (h - pad*2) * 0.80;
    final dotR = w * 0.09;
    for (int i = 0; i < 3; i++) {
      final dx   = [w * 0.27, w * 0.50, w * 0.73][i];
      final wave = sin(t * 3.2 + i * 1.35);
      final sc   = 1 + wave * 0.28;
      final al   = (0.45 + wave * 0.38).clamp(0.07, 1.0);
      canvas.drawCircle(Offset(dx, dotY), dotR * sc * 2.2,
        Paint()..shader = ui.Gradient.radial(
          Offset(dx, dotY), dotR * sc * 2.2,
          [Color.fromARGB(_a(al * 0.4), 255, 255, 255), const Color(0x00FFFFFF)],
          [0.0, 1.0]));
      canvas.drawCircle(Offset(dx, dotY), dotR * sc,
        Paint()..color = Color.fromARGB(_a(al), 255, 255, 255));
    }

    // 10. Bottom button
    canvas.drawCircle(Offset(w * 0.5, pad + (h - pad*2) * 0.92), w * 0.07,
      Paint()..color = const Color(0x40FFFFFF));
  }
}
