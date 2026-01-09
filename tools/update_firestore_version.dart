import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:clmschedule/firebase_options.dart';

/// Script to update the app version in Firestore
/// This is called during deployment to notify users of new version
void main(List<String> args) async {
  if (args.isEmpty) {
    print('Usage: dart run tools/update_firestore_version.dart <version>');
    print('Example: dart run tools/update_firestore_version.dart 1.2.3');
    exit(1);
  }

  final version = args[0];

  print('Initializing Firebase...');
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );

  print('Updating version to: $version');

  try {
    await FirebaseFirestore.instance
        .collection('appConfig')
        .doc('version')
        .set({
      'version': version,
      'forceUpdate': true, // Set to false if you don't want to force reload
      'lastUpdated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    print('✓ Successfully updated version in Firestore');
    print('All users will be prompted to reload to get version $version');
    exit(0);
  } catch (e) {
    print('✗ Error updating version: $e');
    print('You can manually update it in Firebase Console:');
    print('Collection: appConfig');
    print('Document: version');
    print('Fields: {version: "$version", forceUpdate: true, lastUpdated: <timestamp>}');
    exit(1);
  }
}
