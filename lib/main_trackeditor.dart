// lib/main_trackeditor.dart
// Entry point for the trackEditor flavor.
// Uses the main clmschedule Firebase project — NOT a separate Firebase app.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'config/flavor_config.dart';
import 'firebase_options.dart';
import 'providers/schedule_provider.dart';
import 'track_editor/providers/te_files_provider.dart';
import 'track_editor/providers/te_points_in_polygon_provider.dart';
import 'track_editor/providers/te_polygons_provider.dart';
import 'track_editor/providers/te_processing_provider.dart';
import 'track_editor/providers/te_map_layer_provider.dart';
import 'track_editor/providers/te_tabs_provider.dart';
import 'track_editor/providers/te_tracks_provider.dart';
import 'track_editor/providers/te_waypoints_provider.dart';
import 'track_editor/providers/te_mode_provider.dart';
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
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => TEModeProvider()),
        ChangeNotifierProvider(
            create: (_) => ScheduleProvider()..initForTrackEditor()),
        ChangeNotifierProvider(create: (_) => TEFilesProvider()),
        ChangeNotifierProvider(create: (_) => TETabsProvider()),
        ChangeNotifierProvider(create: (_) => TEPolygonsProvider()),
        ChangeNotifierProvider(create: (_) => TEWaypointsProvider()),
        ChangeNotifierProvider(create: (_) => TETracksProvider()),
        ChangeNotifierProvider(create: (_) => TEPointsInPolygonProvider()),
        ChangeNotifierProvider(create: (_) => TEProcessingProvider()),
        ChangeNotifierProvider(create: (_) => TEMapLayerProvider()),
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
