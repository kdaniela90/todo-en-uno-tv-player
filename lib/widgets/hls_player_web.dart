// Implementación web de HlsPlayer usando HLS.js (cargado en web/index.html).
// Solo se compila en la plataforma web.
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

// ── Interop con las funciones JS definidas en web/index.html ────────────────

@JS('hlsCreate')
external void _hlsCreate(
  JSString viewId,
  JSString url,
  JSFunction? onReady,
  JSFunction? onError,
);

@JS('hlsDestroy')
external void _hlsDestroy(JSString viewId);

@JS('hlsLoad')
external void _hlsLoad(JSString viewId, JSString url);

// ── Widget ───────────────────────────────────────────────────────────────────

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

  @override
  State<HlsPlayer> createState() => _HlsPlayerState();
}

class _HlsPlayerState extends State<HlsPlayer> {
  // ID único para este player — usado como id del div en el DOM y en window._hls
  final String _viewId =
      'hlsp-${DateTime.now().microsecondsSinceEpoch}';

  @override
  void initState() {
    super.initState();
    _registerFactory();
  }

  void _registerFactory() {
    ui_web.platformViewRegistry.registerViewFactory(_viewId, (int id) {
      // Contenedor <div> que será el root del HtmlElementView
      final div = web.document.createElement('div') as web.HTMLDivElement;
      div.id = 'hlsv-$_viewId';
      div.style.cssText = 'width:100%;height:100%;background:#000;overflow:hidden;';

      // Inicializar HLS.js después de que el div esté en el DOM
      Future.delayed(const Duration(milliseconds: 150), () => _initHls());

      return div;
    });
  }

  void _initHls() {
    _hlsCreate(
      _viewId.toJS,
      widget.url.toJS,
      widget.onReady == null
          ? null
          : (() => widget.onReady!()).toJS,
      widget.onError == null
          ? null
          : (() => widget.onError!()).toJS,
    );
  }

  @override
  void didUpdateWidget(HlsPlayer old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url) {
      // Cambio de canal: recargar con la nueva URL
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
      HtmlElementView(viewType: _viewId);
}
