// lib/main_letterbox.dart
// Entry point for the Cape Town Letterbox Index.
//
// Deliberately its own entry point: the letterbox work is being proven in
// isolation before any of it is wired into the schedule or maps apps, so it
// runs against the same Firebase project but shares no providers with them.
//
//   flutter run -d chrome -t lib/main_letterbox.dart

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import 'firebase_options.dart';
import 'letterbox/pages/letterbox_curation_page.dart';
import 'letterbox/theme/letterbox_theme.dart';
import 'providers/auth_provider.dart';
import 'widgets/auth_gate.dart';
import 'shareable_maps/providers/map_gesture_provider.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final container = riverpod.ProviderContainer();
  // AuthProvider only flips `isInitialized` inside initialize(), and AuthGate
  // shows its loading spinner until it does — so without this the app hangs
  // forever on "Initializing secure connection…". Fire-and-forget: AuthGate
  // watches authRiverpod and rebuilds when the state lands.
  // ignore: unawaited_futures
  container.read(authRiverpod).initialize();

  runApp(
    riverpod.UncontrolledProviderScope(
      container: container,
      child: const LetterboxApp(),
    ),
  );
}

class LetterboxApp extends StatelessWidget {
  const LetterboxApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CLM Letterbox Index',
      navigatorObservers: [
        riverpod.ProviderScope.containerOf(context)
            .read(mapModalObserverRiverpod),
      ],
      debugShowCheckedModeBanner: false,
      theme: LetterboxTheme.light(),
      home: const AuthGate(child: LetterboxCurationPage()),
    );
  }
}
