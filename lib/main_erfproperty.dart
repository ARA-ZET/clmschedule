// lib/main_erfproperty.dart
// Entry point for the erfProperty flavor.
// Uses the main clmschedule Firebase project.

import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import 'config/flavor_config.dart';
import 'firebase_options.dart';
import 'erf_property/pages/erf_property_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  const flavor = String.fromEnvironment('FLAVOR', defaultValue: 'erfProperty');
  assert(
    flavor == 'erfProperty',
    'This entry point is for the erfProperty flavor only.',
  );

  runApp(
    riverpod.ProviderScope(
      child: const ErfPropertyApp(),
    ),
  );
}

class ErfPropertyApp extends StatelessWidget {
  const ErfPropertyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: FlavorConfig.instance.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: const ErfPropertyScreen(),
    );
  }
}
