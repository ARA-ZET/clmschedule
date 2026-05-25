/// One-time seeder script: uploads Cape_Town_Suburbs.kml to Firebase Storage
/// and creates/updates the `workSuburbs/meta` Firestore document.
///
/// Run with:
///   flutter run -t seed_cape_town_suburbs.dart -d <deviceId>
///
/// This is a one-off operation for developers. It only needs to be run again
/// when the KML file is replaced with a newer version.
library;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;

import 'lib/firebase_options.dart';

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
  static const String _storageDestination = 'suburbs/Cape_Town_Suburbs.kml';
  static const String _version = 'v1';

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();

  String _status = 'Sign in first, then press Upload.';
  bool _running = false;
  bool _signedIn = false;

  Future<void> _signIn() async {
    setState(() {
      _running = true;
      _status = 'Signing in…';
    });
    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailCtrl.text.trim(),
        password: _passCtrl.text,
      );
      setState(() {
        _signedIn = true;
        _status = 'Signed in as ${cred.user?.email}.\nPress Upload & Seed.';
      });
    } catch (e) {
      setState(() => _status = '❌ Sign-in failed: $e');
    } finally {
      setState(() => _running = false);
    }
  }

  Future<void> _run() async {
    setState(() {
      _running = true;
      _status = 'Loading KML asset…';
    });

    try {
      // 1. Load the bundled KML.
      final kmlBytes = await rootBundle.load(_kmlAssetPath);
      final uint8 = kmlBytes.buffer.asUint8List();
      _log('KML loaded: ${(uint8.lengthInBytes / 1024).toStringAsFixed(0)} KB');

      // 2. Upload to Firebase Storage.
      _log('Uploading to Storage at $_storageDestination…');
      final ref = FirebaseStorage.instance.ref(_storageDestination);
      await ref.putData(
        uint8,
        SettableMetadata(
          contentType: 'application/vnd.google-earth.kml+xml',
          // 1-hour browser / CDN cache so repeated app starts don't re-download.
          cacheControl: 'public, max-age=3600',
        ),
      );
      _log('Upload complete.');

      // 3. Write workSuburbs/meta.
      _log('Writing workSuburbs/meta…');
      await FirebaseFirestore.instance.doc('workSuburbs/meta').set({
        'version': _version,
        'storagePath': _storageDestination,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      _log('Meta document written.');

      // 4. Ensure workSuburbs/overrides exists (creates empty doc if absent).
      final overridesRef =
          FirebaseFirestore.instance.doc('workSuburbs/overrides');
      final snap = await overridesRef.get();
      if (!snap.exists) {
        await overridesRef.set({
          'overrides': <Map<String, dynamic>>[],
          'updatedAt': FieldValue.serverTimestamp(),
        });
        _log('Created empty workSuburbs/overrides.');
      } else {
        _log('workSuburbs/overrides already exists — skipped.');
      }

      _log('✅ Seeding complete! Version: $_version');
    } catch (e, st) {
      _log('❌ Error: $e\n$st');
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
      appBar: AppBar(title: const Text('Cape Town Suburbs Seeder')),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This uploads Cape_Town_Suburbs.kml to Firebase Storage '
              'and creates the workSuburbs/meta document.\n\n'
              'Only run this once (or when the KML file is updated).',
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
                child: const Text('Upload & Seed'),
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
