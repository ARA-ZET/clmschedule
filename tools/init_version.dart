import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import '../lib/firebase_options.dart';

/// Initialize the version collection in Firestore
/// Run this once to set up the initial version

void main() async {
  print('Initializing version collection in Firestore...\n');

  try {
    // Initialize Firebase with options
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    final firestore = FirebaseFirestore.instance;
    final versionDoc =
        firestore.collection('app_config').doc('current_version');

    // Check if it already exists
    final snapshot = await versionDoc.get();
    if (snapshot.exists) {
      print('⚠️  Version document already exists:');
      final data = snapshot.data()!;
      print('   Version: ${data['version']}');
      print('   Message: ${data['updateMessage']}');
      print('   Force Update: ${data['forceUpdate']}');
      print('\nUse update_app_version.dart to update it.');
      exit(0);
    }

    // Create initial version document
    await versionDoc.set({
      'version': '2.01.20',
      'lastUpdated': FieldValue.serverTimestamp(),
      'updateMessage': 'Initial version',
      'forceUpdate': false,
    });

    print('✅ Version collection initialized successfully!');
    print('   Version: 2.01.20');
    print('   Collection: app_config');
    print('   Document: current_version');
    print(
        '\nUsers will now receive update notifications when version changes.');

    exit(0);
  } catch (e) {
    print('❌ Error initializing version: $e');
    exit(1);
  }
}
