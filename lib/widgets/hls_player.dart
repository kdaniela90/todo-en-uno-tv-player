// Importación condicional: en web usa HLS.js, en nativo usa el stub vacío.
export 'hls_player_stub.dart'
    if (dart.library.js_interop) 'hls_player_web.dart';
