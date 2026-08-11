// lib/main_trackeditor.dart
// Entry point for the trackEditor flavor.
// Uses the main clmschedule Firebase project — NOT a separate Firebase app.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import 'config/flavor_config.dart';
import 'firebase_options.dart';
import 'providers/auth_provider.dart';
import 'providers/schedule_provider.dart';
// TE provider imports migrated to Riverpod
import 'track_editor/pages/track_editor_screen.dart';
import 'widgets/auth_gate.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Use the main clmschedule Firebase project (same as other flavors).
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'trackEditor');
  assert(
    flavor == 'trackEditor',
    'This entry point is for the trackEditor flavor only.',
  );

  runApp(
    riverpod.ProviderScope(
      overrides: [
        scheduleRiverpod
            .overrideWith((ref) => ScheduleProvider()..initForTrackEditor()),
      ],
      child: const TrackEditorApp(),
    ),
  );
}

class TrackEditorApp extends riverpod.ConsumerStatefulWidget {
  const TrackEditorApp({super.key});

  @override
  riverpod.ConsumerState<TrackEditorApp> createState() =>
      _TrackEditorAppState();
}

class _TrackEditorAppState extends riverpod.ConsumerState<TrackEditorApp> {
  @override
  void initState() {
    super.initState();
    // Firestore rules require a signed-in user; AuthGate shows the login
    // screen until then, but only once the auth provider has initialized
    // (the main-app flavor does this in its dashboard init).
    ref.read(authRiverpod).initialize();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: FlavorConfig.instance.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const AuthGate(child: TrackEditorScreen()),
    );
  }
}
