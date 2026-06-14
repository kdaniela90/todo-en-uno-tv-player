import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

import '../services/storage_service.dart';
import '../services/xtream_service.dart';
import '../theme/app_theme.dart';
import '../widgets/animated_remote.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});
  @override State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey  = GlobalKey<FormState>();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _userFocus = FocusNode();
  final _passFocus = FocusNode();
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  static const String _server = 'http://allinonestream.fans:8080';

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _userCtrl.dispose(); _passCtrl.dispose();
    _userFocus.dispose(); _passFocus.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() { _loading = true; _error = null; });

    final service = XtreamService(
      server: _server,
      username: _userCtrl.text.trim(),
      password: _passCtrl.text.trim());
    final result = await service.login();
    if (!mounted) return;

    if (result != null && result['user_info'] != null) {
      final expRaw = result['user_info']['exp_date']?.toString() ?? '';
      await StorageService.saveCredentials(
        username: _userCtrl.text.trim(),
        password: _passCtrl.text.trim(),
        server: _server, expDate: expRaw);
      Navigator.pushReplacementNamed(context, '/hub', arguments: {
        'username': _userCtrl.text.trim(),
        'password': _passCtrl.text.trim(),
        'server': _server, 'exp_date': expRaw,
      });
    } else {
      setState(() {
        _error = 'Usuario o contraseña incorrectos.';
        _loading = false;
      });
    }
  }

  // ── QR local-server login ────────────────────────────────────────────────
  // En la versión web este botón no se muestra (ver _formContent).
  // El método existe solo para evitar referencias rotas; en web nunca se invoca.
  Future<void> _openQrLogin() async {}

  // ── Build ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final isTwoCol = size.width > 700;
    final keyboardH = MediaQuery.of(context).viewInsets.bottom;

    return Scaffold(
      backgroundColor: AppColors.background,
      resizeToAvoidBottomInset: true,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: isTwoCol
              ? _twoColumnLayout(context)
              : _singleColumnLayout(context, keyboardH),
        ),
      ),
    );
  }

  // ── Dos columnas: TV / tablet landscape ─────────────────────────────────
  Widget _twoColumnLayout(BuildContext context) => Row(
    children: [
      // ── Columna izquierda: logo ──────────────────────────────────────────
      Expanded(
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                AppColors.background,
                const Color(0xFF0A1128),
              ],
            ),
            border: const Border(
              right: BorderSide(color: Colors.white10, width: 1),
            ),
          ),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Logo principal
                Image.asset(
                  'assets/images/logo.png',
                  width: 180,
                  fit: BoxFit.contain,
                ),
                const SizedBox(height: 20),
                AnimatedRemote(width: 80, height: 160),
                const SizedBox(height: 20),
                const Text('Tu entretenimiento en un solo lugar',
                  style: TextStyle(
                    color: Colors.white38,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  )),
              ],
            ),
          ),
        ),
      ),

      // ── Columna derecha: formulario ──────────────────────────────────────
      Expanded(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 32),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 380),
              child: _formContent(context),
            ),
          ),
        ),
      ),
    ],
  );

  // ── Una columna: teléfono ────────────────────────────────────────────────
  Widget _singleColumnLayout(BuildContext context, double keyboardH) => Center(
    child: SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: EdgeInsets.fromLTRB(32, 36, 32, keyboardH + 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Column(children: [
          // Logo principal
          Image.asset(
            'assets/images/logo.png',
            width: 160,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 10),
          // Control animado como acento visual (más pequeño)
          AnimatedRemote(width: 32, height: 64),
          const SizedBox(height: 12),
          const Text('Tu entretenimiento en un solo lugar',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white38, fontSize: 12,
              letterSpacing: 0.4)),
          const SizedBox(height: 28),
          _formContent(context),
        ]),
      ),
    ),
  );

  // ── Contenido del formulario (compartido) ────────────────────────────────
  Widget _formContent(BuildContext context) => Form(
    key: _formKey,
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Iniciar sesión',
        style: TextStyle(color: Colors.white,
          fontSize: 24, fontWeight: FontWeight.bold)),
      const SizedBox(height: 6),
      const Text('Ingresa tus credenciales para continuar',
        style: TextStyle(color: Colors.white54, fontSize: 14)),
      const SizedBox(height: 28),

      _field(ctrl: _userCtrl, focus: _userFocus, next: _passFocus,
        label: 'Usuario', icon: Icons.person_rounded,
        validator: (v) => (v?.isEmpty ?? true) ? 'Ingresa tu usuario' : null),
      const SizedBox(height: 14),
      _field(ctrl: _passCtrl, focus: _passFocus,
        label: 'Contraseña', icon: Icons.lock_rounded, obscure: _obscure,
        suffix: IconButton(
          icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off,
            color: Colors.white54),
          onPressed: () => setState(() => _obscure = !_obscure)),
        onSubmit: (_) => _login(),
        validator: (v) => (v?.isEmpty ?? true) ? 'Ingresa tu contraseña' : null),

      if (_error != null) ...[
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.2),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.red.withOpacity(0.5))),
          child: Row(children: [
            const Icon(Icons.error_outline, color: Colors.red, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text(_error!,
              style: const TextStyle(color: Colors.red, fontSize: 13))),
          ]),
        ),
      ],
      const SizedBox(height: 24),

      SizedBox(width: double.infinity, height: 54,
        child: ElevatedButton(
          onPressed: _loading ? null : _login,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.celeste.withOpacity(0.85),
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14))),
          child: _loading
            ? const SizedBox(width: 24, height: 24,
                child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
            : const Text('INICIAR SESIÓN',
                style: TextStyle(fontSize: 16,
                  fontWeight: FontWeight.bold, letterSpacing: 1.5)),
        )),

      // QR login solo disponible en la app nativa (Android/TV)
      if (!kIsWeb) ...[
        const SizedBox(height: 12),
        SizedBox(width: double.infinity, height: 48,
          child: OutlinedButton.icon(
            onPressed: _loading ? null : _openQrLogin,
            icon: const Icon(Icons.qr_code_scanner, size: 18),
            label: const Text('Ingresar desde el móvil',
              style: TextStyle(fontSize: 14, letterSpacing: 0.5)),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.celeste,
              side: BorderSide(color: AppColors.celeste.withOpacity(0.5)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14))),
          )),
      ],

      const SizedBox(height: 24),
      const Center(child: Text('© 2026 Todo en Uno TV',
        style: TextStyle(color: Colors.white24, fontSize: 12))),
    ]),
  );

  Widget _field({
    required TextEditingController ctrl,
    required FocusNode focus,
    FocusNode? next,
    required String label,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    void Function(String)? onSubmit,
    String? Function(String?)? validator,
  }) => TextFormField(
    controller: ctrl, focusNode: focus,
    obscureText: obscure,
    style: const TextStyle(color: Colors.white, fontSize: 16),
    textInputAction: next != null ? TextInputAction.next : TextInputAction.done,
    onFieldSubmitted: onSubmit ?? (_) { if (next != null) next.requestFocus(); },
    decoration: InputDecoration(
      labelText: label,
      prefixIcon: Icon(icon, color: AppColors.celeste),
      suffixIcon: suffix,
      filled: true,
      fillColor: Colors.white.withOpacity(0.09),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: AppColors.celeste, width: 2.0)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: Colors.white24, width: 1.5)),
      labelStyle: const TextStyle(color: Colors.white70, fontSize: 15),
    ),
    validator: validator,
  );
}

