// lib/main_trackeditor.dart
// Entry point for the trackEditor flavor.
// Uses the main clmschedule Firebase project — NOT a separate Firebase app.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import 'config/flavor_config.dart';
import 'firebase_options.dart';
import 'providers/schedule_provider.dart';
// TE provider imports migrated to Riverpod
import 'track_editor/pages/track_editor_screen.dart';

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

class TrackEditorApp extends StatelessWidget {
  const TrackEditorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: FlavorConfig.instance.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
      ),
      home: const TrackEditorScreen(),
    );
  }
}
