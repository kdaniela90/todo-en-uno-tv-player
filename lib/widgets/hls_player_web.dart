// Implementación web de HlsPlayer usando HLS.js (cargado en web/index.html).
// Solo se compila en la plataforma web (via exportación condicional en hls_player.dart).
// NO usa package:web para evitar conflictos de versión — el div se crea desde JS.
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';

// ── Interop con funciones JS definidas en web/index.html ─────────────────────

/// Crea el <div> contenedor y lo devuelve como elemento DOM nativo.
/// El div queda con id='hlsv-<viewId>' para que hlsCreate lo encuentre.
@JS('hlsCreateContainer')
external JSObject _createContainer(JSString viewId);

/// Inicializa HLS.js dentro del contenedor y empieza a reproducir url.
@JS('hlsCreate')
external void _hlsCreate(
  JSString viewId,
  JSString url,
  JSFunction? onReady,
  JSFunction? onError,
);

/// Destruye la instancia HLS.js asociada a viewId.
@JS('hlsDestroy')
external void _hlsDestroy(JSString viewId);

/// Carga una nueva URL sin recrear el elemento de video.
@JS('hlsLoad')
external void _hlsLoad(JSString viewId, JSString url);

/// Último error de HLS.js almacenado en window._hlsLastError por JS.
@JS('_hlsLastError')
external JSString get _hlsLastErrorJs;

// ── Widget ────────────────────────────────────────────────────────────────────

// Expone el último error de HLS.js al resto del app (e.g. player_screen.dart).
// lee window._hlsLastError que JS escribe en web/index.html.
// ignore: non_constant_identifier_names

class HlsPlayer extends StatefulWidget {
  const HlsPlayer({
    super.key,
    required this.url,
    this.onReady,
    this.onError,
  });

  final String url;
  final VoidCallback? onReady;
  final VoidCallback? onError;

  /// Lee window._hlsLastError — el último error fatal reportado por HLS.js.
  static String lastError() {
    try { return _hlsLastErrorJs.toDart; } catch (_) { return ''; }
  }

  @override
  State<HlsPlayer> createState() => _HlsPlayerState();
}

class _HlsPlayerState extends State<HlsPlayer> {
  /// ID único por instancia: clave del div en el DOM y de window._hls.
  final String _viewId = 'hlsp-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _registerFactory();
  }

  void _registerFactory() {
    ui_web.platformViewRegistry.registerViewFactory(
      _viewId,
      (int id) {
        // El div es creado DESDE JS para evitar depender de package:web.
        // flutter_web lo trata como HTMLElement nativo (que efectivamente es).
        final container = _createContainer(_viewId.toJS);

        // Después de que Flutter inserte el div en el DOM, iniciar HLS.js.
        Future.delayed(const Duration(milliseconds: 200), _initHls);

        return container;
      },
      isVisible: true,
    );
  }

  void _initHls() {
    if (!mounted) return;
    _hlsCreate(
      _viewId.toJS,
      widget.url.toJS,
      widget.onReady == null ? null : (() { widget.onReady!(); }).toJS,
      widget.onError == null ? null : (() { widget.onError!(); }).toJS,
    );
  }

  @override
  void didUpdateWidget(HlsPlayer old) {
    super.didUpdateWidget(old);
    // Solo recargamos si la URL cambió (zapping).
    if (old.url != widget.url) {
      _hlsLoad(_viewId.toJS, widget.url.toJS);
    }
  }

  @override
  void dispose() {
    _hlsDestroy(_viewId.toJS);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      // SizedBox.expand garantiza que el HtmlElementView llene su contenedor.
      SizedBox.expand(
        child: HtmlElementView(viewType: _viewId),
      );
}
