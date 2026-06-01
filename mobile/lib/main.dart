import 'package:flutter/material.dart';

import 'core/i18n/i18n.dart';
import 'features/ime/ime_keyboard_view.dart';
import 'features/voice_keyboard/voice_keyboard_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await I18n.instance.load();
  runApp(const VoiceInputApp());
}

/// Dart entrypoint used by the native IME service. Must live in the same Dart
/// library as `main` — otherwise the AOT compiler tree-shakes it and the
/// FlutterEngine fails with "Could not resolve main entrypoint function".
@pragma('vm:entry-point')
void imeMain() async {
  WidgetsFlutterBinding.ensureInitialized();
  await I18n.instance.load();
  runApp(const ImeApp());
}

class VoiceInputApp extends StatelessWidget {
  const VoiceInputApp({super.key});

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.dark,
    );
    return ListenableBuilder(
      listenable: I18n.instance,
      builder: (context, _) => MaterialApp(
        title: tr('app.title'),
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: lightScheme,
          scaffoldBackgroundColor: lightScheme.surface,
          appBarTheme: AppBarTheme(
              backgroundColor: lightScheme.surface, foregroundColor: lightScheme.onSurface),
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: darkScheme,
          scaffoldBackgroundColor: darkScheme.surface,
          appBarTheme: AppBarTheme(
              backgroundColor: darkScheme.surface, foregroundColor: darkScheme.onSurface),
        ),
        home: const VoiceKeyboardPage(),
      ),
    );
  }
}

class ImeApp extends StatelessWidget {
  const ImeApp({super.key});

  static const double panelHeight = 200;

  @override
  Widget build(BuildContext context) {
    final lightScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.light,
    );
    final darkScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1A1A1C),
      brightness: Brightness.dark,
    );
    return ListenableBuilder(
      listenable: I18n.instance,
      builder: (context, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: lightScheme,
          scaffoldBackgroundColor: Colors.transparent,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: darkScheme,
          scaffoldBackgroundColor: Colors.transparent,
        ),
        home: Scaffold(
          backgroundColor: Colors.transparent,
          body: Align(
            alignment: Alignment.bottomCenter,
            child: SizedBox(
              height: panelHeight,
              width: double.infinity,
              child: Material(
                color: Theme.of(context).colorScheme.surface,
                child: const ImeKeyboardView(),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
