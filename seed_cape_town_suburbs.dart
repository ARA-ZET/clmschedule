/// One-time seeder script: parses Cape_Town_Suburbs.kml and writes all suburb
/// polygons into the single `workSuburbs/main` Firestore document.
///
/// Run with:
///   `flutter run -t seed_cape_town_suburbs.dart -d <deviceId>`
///
/// This is a one-off operation for developers. It only needs to be run again
/// when the KML file is replaced with a newer version.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'lib/firebase_options.dart';
import 'lib/shareable_maps/services/suburb_data_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const _SeederApp());
}

class _SeederApp extends StatelessWidget {
  const _SeederApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: _SeederScreen());
  }
}

class _SeederScreen extends StatefulWidget {
  const _SeederScreen();

  @override
  State<_SeederScreen> createState() => _SeederScreenState();
}

class _SeederScreenState extends State<_SeederScreen> {
  static const String _kmlAssetPath = 'assets/maps/Cape_Town_Suburbs.kml';
  static const String _version = 'v2_firestore_main';

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  String _status = 'Sign in first, then press Seed Firestore.';
  bool _running = false;
  bool _signedIn = false;

  Future<void> _signIn() async {
    setState(() {
      _running = true;
      _status = 'Signing in...';
    });
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      setState(() {
        _signedIn = true;
        _status = 'Signed in as ${cred.user?.email}.\nPress Seed Firestore.';
      });
    } catch (e) {
      setState(() => _status = 'Sign-in failed: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _status = 'Loading KML asset...';
    });

    try {
      final kmlString = await rootBundle.loadString(_kmlAssetPath);
      _log('KML loaded: ${(kmlString.length / 1024).toStringAsFixed(0)} KB');

      _log('Parsing suburb polygons...');
      final suburbs = await SuburbDataService.parseKml(kmlString);
      final totalPoints = suburbs.fold<int>(
        0,
        (total, suburb) => total + suburb.polygonPoints.length,
      );
      _log('Parsed ${suburbs.length} suburbs with $totalPoints points.');

      _log('Writing workSuburbs/main...');
      await FirebaseFirestore.instance.doc('workSuburbs/main').set({
        'suburbs': suburbs.map((suburb) => suburb.toMap()).toList(),
        'version': _version,
        'sourceAsset': _kmlAssetPath,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      SuburbDataService.invalidateCache();
      _log('workSuburbs/main written.');

      _log('Seeding complete! Version: $_version');
    } catch (e, st) {
      _log('Error: $e\n$st');
    } finally {
      setState(() => _running = false);
    }
  }

  void _log(String msg) {
    debugPrint('[Seeder] $msg');
    setState(() => _status = '$_status\n$msg');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Cape Town Suburbs Firestore Seeder')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This parses Cape_Town_Suburbs.kml and writes all polygons to '
              'the workSuburbs/main Firestore document.\n\n'
              'Run this again whenever the KML file is updated.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            if (!_signedIn) ...[
              TextField(
                controller: _emailCtrl,
                decoration: const InputDecoration(labelText: 'Email'),
                keyboardType: TextInputType.emailAddress,
              ),
              TextField(
                controller: _passCtrl,
                decoration: const InputDecoration(labelText: 'Password'),
                obscureText: true,
              ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: _running ? null : _signIn,
                child: const Text('Sign In'),
              ),
            ] else
              ElevatedButton(
                onPressed: _running ? null : _run,
                child: const Text('Seed Firestore'),
              ),
            const SizedBox(height: 24),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  _status,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
