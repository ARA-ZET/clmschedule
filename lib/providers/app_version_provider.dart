import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/app_version.dart';
import '../services/app_version_service.dart';

/// Riverpod provider for AppVersionProvider
final appVersionRiverpod =
    riverpod.ChangeNotifierProvider<AppVersionProvider>((ref) {
  return AppVersionProvider();
});

class AppVersionProvider extends ChangeNotifier {
  final AppVersionService _versionService;
  AppVersion? _currentVersion;
  AppVersion? _localVersion;
  StreamSubscription<AppVersion>? _versionSubscription;
  bool _isListening = false;

  AppVersionProvider({AppVersionService? versionService})
      : _versionService = versionService ?? AppVersionService();

  AppVersion? get currentVersion => _currentVersion;
  AppVersion? get localVersion => _localVersion;
  bool get isListening => _isListening;

  // Check if there's a version mismatch requiring update
  bool get needsUpdate {
    if (_currentVersion == null || _localVersion == null) return false;
    return _currentVersion!.version != _localVersion!.version;
  }

  bool get forceUpdate {
    if (_currentVersion == null) return false;
    return _currentVersion!.forceUpdate && needsUpdate;
  }

  // Initialize and start listening to version changes
  Future<void> initialize(String currentAppVersion) async {
    _localVersion = AppVersion(
      version: currentAppVersion,
      lastUpdated: DateTime.now(),
    );

    // Start listening to version changes
    startListening();

    // Get initial version
    _currentVersion = await _versionService.getCurrentVersion();
    notifyListeners();

    print('AppVersionProvider initialized');
    print('Local version: ${_localVersion!.version}');
    print('Server version: ${_currentVersion!.version}');
    print('Needs update: $needsUpdate');
  }

  void startListening() {
    if (_isListening) return;

    _versionSubscription?.cancel();
    _versionSubscription = _versionService.streamAppVersion().listen(
      (version) {
        final previousVersion = _currentVersion?.version;
        _currentVersion = version;

        print('=== VERSION UPDATE DETECTED ===');
        print('Previous version: $previousVersion');
        print('New version: ${version.version}');
        print('Last updated: ${version.lastUpdated}');
        print('Force update: ${version.forceUpdate}');
        print('==============================');

        notifyListeners();
      },
      onError: (error) {
        print('Error listening to version updates: $error');
      },
    );

    _isListening = true;
  }

  void stopListening() {
    _versionSubscription?.cancel();
    _versionSubscription = null;
    _isListening = false;
  }

  @override
  void dispose() {
    stopListening();
    super.dispose();
  }
}
