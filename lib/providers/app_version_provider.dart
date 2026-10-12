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

  /// The deploy stamp this session started on. Anything newer than this means
  /// a deploy happened while the app was open — even when the version string
  /// is unchanged, which is the norm for two deploys on the same day under the
  /// date-based `2.MM.DD` scheme.
  DateTime? _sessionBaseline;

  AppVersionProvider({AppVersionService? versionService})
      : _versionService = versionService ?? AppVersionService();

  AppVersion? get currentVersion => _currentVersion;
  AppVersion? get localVersion => _localVersion;
  bool get isListening => _isListening;

  // Check if there's a version mismatch requiring update
  bool get needsUpdate {
    final server = _currentVersion;
    final local = _localVersion;
    if (server == null || local == null) return false;

    // The build that is running differs from what is deployed.
    if (server.version != local.version) return true;

    // Same version string, but the deploy stamp moved on since this session
    // started — a redeploy the version string cannot express.
    final baseline = _sessionBaseline;
    final stamp = server.serverTimestamp;
    return baseline != null && stamp != null && stamp.isAfter(baseline);
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

    // Get initial version. A server-only read fails when the client is
    // offline; the listener fills the value in once it reconnects, so this is
    // not fatal.
    try {
      final initial = await _versionService.getCurrentVersion();
      _currentVersion = initial;
      _sessionBaseline ??= initial.serverTimestamp;
    } catch (e) {
      debugPrint('AppVersionProvider: initial version read failed: $e');
    }
    notifyListeners();

    debugPrint('AppVersionProvider initialized');
    debugPrint('Local version: ${_localVersion!.version}');
    debugPrint('Server version: ${_currentVersion?.version ?? 'unknown'}');
    debugPrint('Needs update: $needsUpdate');
  }

  void startListening() {
    if (_isListening) return;

    _versionSubscription?.cancel();
    _versionSubscription = _versionService.streamAppVersion().listen(
      (version) {
        final previousVersion = _currentVersion?.version;
        _currentVersion = version;
        // First server value seen this session is the baseline to compare
        // later deploys against.
        _sessionBaseline ??= version.serverTimestamp;

        debugPrint('=== VERSION UPDATE DETECTED ===');
        debugPrint('Previous version: $previousVersion');
        debugPrint('New version: ${version.version}');
        debugPrint('Last updated: ${version.lastUpdated}');
        debugPrint('Session baseline: $_sessionBaseline');
        debugPrint('Force update: ${version.forceUpdate}');
        debugPrint('Needs update: $needsUpdate');
        debugPrint('==============================');

        notifyListeners();
      },
      onError: (error) {
        debugPrint('Error listening to version updates: $error');
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
