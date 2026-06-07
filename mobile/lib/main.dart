import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'core/i18n/i18n.dart';
import 'features/ime/ime_keyboard_view.dart';
import 'features/voice_keyboard/voice_keyboard_page.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[main] entry');
  await I18n.instance.load();
  debugPrint('[main] i18n loaded, locale=${I18n.instance.locale.code}');
  runApp(const VoiceInputApp());
}

/// Dart entrypoint used by the native IME service. Must live in the same Dart
/// library as `main` — otherwise the AOT compiler tree-shakes it and the
/// FlutterEngine fails with "Could not resolve main entrypoint function".
@pragma('vm:entry-point')
void imeMain() {
  WidgetsFlutterBinding.ensureInitialized();
  debugPrint('[imeMain] entry');
  // Spin up the UI right away — blocking on I18n.load() before runApp leaves
  // the IME engine in a "view ready, no Dart frame" state on some platforms
  // (taps look ignored). Locale loads in the background and the
  // ListenableBuilder around MaterialApp re-renders when it lands.
  I18n.instance.load().then((_) {
    debugPrint('[imeMain] i18n loaded, locale=${I18n.instance.locale.code}');
  });
  runApp(const ImeApp());
  debugPrint('[imeMain] runApp returned');
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

  @override
  Widget build(BuildContext context) {
    debugPrint('[ImeApp] build');
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
          scaffoldBackgroundColor: lightScheme.surface,
        ),
        darkTheme: ThemeData(
          useMaterial3: true,
          colorScheme: darkScheme,
          scaffoldBackgroundColor: darkScheme.surface,
        ),
        // Standard bottom keyboard: the native IME service already sizes the
        // input view to a fixed height and docks it at the bottom, so here we
        // just fill that area with an opaque keyboard panel.
        home: const Scaffold(
          body: ImeKeyboardView(),
        ),
      ),
    );
  }
}
