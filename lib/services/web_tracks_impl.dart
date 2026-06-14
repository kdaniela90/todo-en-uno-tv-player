// Implementación web: accede a HTMLVideoElement.textTracks via dart:js_interop.
// Solo se importa cuando dart.library.js_interop está disponible (Flutter Web).
// ignore_for_file: avoid_web_libraries_in_flutter

import 'dart:js_interop';

// ── Tipos JS con extension types (Dart 3) ───────────────────────────────────

@JS()
extension type _TextTrack._(JSObject _) implements JSObject {
  external JSString get label;
  external JSString get language;
  external JSString get kind;
  external JSString get mode;
  external set mode(JSString value);
}

@JS()
extension type _TextTrackList._(JSObject _) implements JSObject {
  external int get length;
  external _TextTrack? item(int index);
}

@JS()
extension type _HTMLVideoElement._(JSObject _) implements JSObject {
  external _TextTrackList? get textTracks;
}

@JS('document.querySelector')
external JSObject? _querySelector(JSString selector);

// ── API pública ──────────────────────────────────────────────────────────────

/// Devuelve la lista de pistas de texto (subtítulos/captions) del primer
/// elemento <video> encontrado en el DOM.
List<Map<String, dynamic>> getTextTracks() {
  try {
    final el = _querySelector('video'.toJS);
    if (el == null) return [];
    final video = _HTMLVideoElement._(el);
    final tracks = video.textTracks;
    if (tracks == null) return [];

    final result = <Map<String, dynamic>>[];
    for (int i = 0; i < tracks.length; i++) {
      final t = tracks.item(i);
      if (t == null) continue;
      final kind = t.kind.toDart;
      // Solo mostrar pistas de subtítulos y captions
      if (kind != 'subtitles' && kind != 'captions') continue;
      final label = t.label.toDart;
      final language = t.language.toDart;
      result.add({
        'index': i,
        'label': label.isNotEmpty ? label : 'Subtítulo ${result.length + 1}',
        'language': language.isNotEmpty ? language.toUpperCase() : '',
        'kind': kind,
      });
    }
    return result;
  } catch (_) {
    return [];
  }
}

/// Activa la pista en [index] y desactiva todas las demás.
void enableTextTrack(int index) {
  try {
    final el = _querySelector('video'.toJS);
    if (el == null) return;
    final video = _HTMLVideoElement._(el);
    final tracks = video.textTracks;
    if (tracks == null) return;
    for (int i = 0; i < tracks.length; i++) {
      final t = tracks.item(i);
      if (t != null) t.mode = (i == index ? 'showing' : 'disabled').toJS;
    }
  } catch (_) {}
}

/// Desactiva todas las pistas de texto.
void disableAllTextTracks() {
  try {
    final el = _querySelector('video'.toJS);
    if (el == null) return;
    final video = _HTMLVideoElement._(el);
    final tracks = video.textTracks;
    if (tracks == null) return;
    for (int i = 0; i < tracks.length; i++) {
      final t = tracks.item(i);
      if (t != null) t.mode = 'disabled'.toJS;
    }
  } catch (_) {}
}
