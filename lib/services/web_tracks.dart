// Fachada de pistas de texto para web.
// Usa importación condicional:
//   - En web (dart.library.js_interop disponible) → web_tracks_impl.dart
//   - En otras plataformas → web_tracks_stub.dart (no-ops)

import 'web_tracks_stub.dart'
    if (dart.library.js_interop) 'web_tracks_impl.dart'
    as _impl;

class WebTracks {
  /// Devuelve la lista de pistas de subtítulos/captions del <video> activo.
  static List<Map<String, dynamic>> getTextTracks() => _impl.getTextTracks();

  /// Activa la pista en [index] y desactiva las demás.
  static void enableTextTrack(int index) => _impl.enableTextTrack(index);

  /// Desactiva todas las pistas de texto (Sin subtítulos).
  static void disableAllTextTracks() => _impl.disableAllTextTracks();
}
