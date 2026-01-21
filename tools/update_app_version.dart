import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';

/// Tool to update the app version in Firestore
///
/// Usage:
///   dart run tools/update_app_version.dart 1.2.3 "Bug fixes and improvements"
///   dart run tools/update_app_version.dart 2.0.0 "Major update with new features" --force
///
/// Arguments:
///   version: The new version number (e.g., 1.2.3)
///   message: Description of the update
///   --force: Optional flag to require users to update immediately

void main(List<String> args) async {
  if (args.isEmpty || args.length < 2) {
    print(
        'Usage: dart run tools/update_app_version.dart <version> "<message>" [--force]');
    print(
        'Example: dart run tools/update_app_version.dart 1.2.3 "Bug fixes" --force');
    exit(1);
  }

  final version = args[0];
  final message = args[1];
  final forceUpdate = args.contains('--force');

  print('Updating app version in Firestore...');
  print('Version: $version');
  print('Message: $message');
  print('Force Update: $forceUpdate');
  print('');

  try {
    // Initialize Firebase
    await Firebase.initializeApp();

    final firestore = FirebaseFirestore.instance;
    final versionDoc =
        firestore.collection('app_config').doc('current_version');

    // Update the version
    await versionDoc.set({
      'version': version,
      'lastUpdated': FieldValue.serverTimestamp(),
      'updateMessage': message,
      'forceUpdate': forceUpdate,
    });

    print('✅ Version updated successfully!');
    print('All connected users will be notified of the update.');

    if (forceUpdate) {
      print('⚠️  Force update enabled - users will be required to refresh.');
    }

    exit(0);
  } catch (e) {
    print('❌ Error updating version: $e');
    exit(1);
  }
}
