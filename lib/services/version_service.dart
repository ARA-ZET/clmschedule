import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:async';

/// Service to check app version and force reload if newer version is available
class VersionService {
  final FirebaseFirestore _firestore;
  StreamSubscription<DocumentSnapshot>? _versionSubscription;
  String? _currentVersion;
  Function? _onNewVersionAvailable;

  VersionService(this._firestore);

  /// Initialize version checking
  /// [onNewVersionAvailable] callback is called when a new version is detected
  Future<void> initialize({Function? onNewVersionAvailable}) async {
    _onNewVersionAvailable = onNewVersionAvailable;
    
    try {
      // Get current app version from package info
      final packageInfo = await PackageInfo.fromPlatform();
      _currentVersion = packageInfo.version;
      
      if (kDebugMode) {
        print('Current app version: $_currentVersion');
      }

      // Start listening for version updates
      _startVersionListener();
    } catch (e) {
      if (kDebugMode) {
        print('Error initializing version service: $e');
      }
    }
  }

  /// Start listening to version document in Firestore
  void _startVersionListener() {
    _versionSubscription = _firestore
        .collection('appConfig')
        .doc('version')
        .snapshots()
        .listen((snapshot) {
      if (snapshot.exists) {
        final data = snapshot.data();
        if (data != null) {
          final serverVersion = data['version'] as String?;
          final forceUpdate = data['forceUpdate'] as bool? ?? true;

          if (serverVersion != null && serverVersion != _currentVersion) {
            if (kDebugMode) {
              print('New version available: $serverVersion (current: $_currentVersion)');
            }

            if (forceUpdate) {
              // Call the callback to notify about new version
              _onNewVersionAvailable?.call(serverVersion);
            }
          }
        }
      }
    });
  }

  /// Update the version in Firestore (call this after deploying)
  /// This should be called from your deployment script or manually after deploy
  static Future<void> updateServerVersion(String version, {bool forceUpdate = true}) async {
    try {
      await FirebaseFirestore.instance
          .collection('appConfig')
          .doc('version')
          .set({
        'version': version,
        'forceUpdate': forceUpdate,
        'lastUpdated': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      if (kDebugMode) {
        print('Server version updated to: $version');
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error updating server version: $e');
      }
    }
  }

  /// Dispose and cancel subscriptions
  void dispose() {
    _versionSubscription?.cancel();
  }
}
