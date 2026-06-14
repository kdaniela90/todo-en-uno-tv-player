// Stub para plataformas nativas (Android, TV).
// En web se usa hls_player_web.dart vía importación condicional.
import 'package:flutter/material.dart';

class HlsPlayer extends StatelessWidget {
  const HlsPlayer({
    super.key,
    required this.url,
    this.onReady,
    this.onError,
  });

  final String url;
  final VoidCallback? onReady;
  final VoidCallback? onError;

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
