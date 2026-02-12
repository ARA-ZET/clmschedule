import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// Service to monitor network connectivity status
class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;

  bool _isOnline = true;
  bool get isOnline => _isOnline;

  final _connectivityController = StreamController<bool>.broadcast();
  Stream<bool> get connectivityStream => _connectivityController.stream;

  /// Initialize connectivity monitoring
  Future<void> initialize() async {
    // Check current connectivity status
    final result = await _connectivity.checkConnectivity();
    _updateConnectionStatus(result);

    // Listen to connectivity changes
    _connectivitySubscription = _connectivity.onConnectivityChanged.listen(
      _updateConnectionStatus,
      onError: (error) {
        debugPrint(
            '❌ ConnectivityService: Error monitoring connectivity: $error');
      },
    );

    debugPrint(
        '📡 ConnectivityService: Initialized. Current status: ${_isOnline ? "Online" : "Offline"}');
  }

  void _updateConnectionStatus(List<ConnectivityResult> results) {
    // Consider online if any connectivity is available (wifi, mobile, ethernet)
    final wasOnline = _isOnline;
    _isOnline = results.any((result) =>
        result == ConnectivityResult.wifi ||
        result == ConnectivityResult.mobile ||
        result == ConnectivityResult.ethernet);

    // Only emit if status changed
    if (wasOnline != _isOnline) {
      debugPrint(
          '📡 ConnectivityService: Status changed to ${_isOnline ? "Online" : "Offline"}');
      _connectivityController.add(_isOnline);
    }
  }

  /// Dispose of resources
  void dispose() {
    _connectivitySubscription?.cancel();
    _connectivityController.close();
  }
}
