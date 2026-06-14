import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'services/epg_settings_service.dart';
import 'services/reminder_service.dart';
import 'theme/app_theme.dart';
import 'screens/splash_screen.dart';
import 'screens/login_screen.dart';
import 'screens/hub_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await EpgSettingsService.init();
  await ReminderService.init();
  if (!kIsWeb) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));
  runApp(const TodoEnUnoTVApp());
}

class TodoEnUnoTVApp extends StatelessWidget {
  const TodoEnUnoTVApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TEUTV Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      initialRoute: '/',
      routes: {
        '/': (_) => const SplashScreen(),
        '/login': (_) => const LoginScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/hub') {
          final creds = settings.arguments as Map<String, String>;
          return MaterialPageRoute(builder: (_) => HubScreen(credentials: creds));
        }
        return null;
      },
    );
  }
}
