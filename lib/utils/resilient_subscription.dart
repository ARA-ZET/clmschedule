// utils/resilient_subscription.dart
//
// A Firestore listener is closed for good after its first error, and most
// providers only debugPrint'ed it — one hiccup (dropped connection, a token
// refresh after the laptop slept, a rules deploy rolling out) and that screen
// silently stopped updating until a reload. This re-opens the stream with
// backoff, keeps the last data on screen meanwhile, and tells SyncStatus so
// the banner can say live updates are paused.
import 'dart:async';
import 'dart:math' as math;

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../services/sync_status.dart';
import 'friendly_error.dart';

class ResilientSubscription<T> {
  /// Starts listening immediately.
  ResilientSubscription({
    required this.debugLabel,
    required this.userLabel,
    required this.open,
    required this.onData,
  }) : _key = '$debugLabel#${_nextId++}' {
    _listen();
  }

  static int _nextId = 0;

  /// For the console ("schedule 2026-11").
  final String debugLabel;

  /// For the banner ("the schedule").
  final String userLabel;

  final Stream<T> Function() open;
  final void Function(T data) onData;

  final String _key;
  StreamSubscription<T>? _sub;
  Timer? _retryTimer;
  Timer? _upTimer;
  Timer? _healthyTimer;
  int _failures = 0;
  bool _cancelled = false;

  static const List<Duration> _delays = [
    Duration(seconds: 2),
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  /// Data must arrive and no error follow for this long before the listener
  /// counts as back. A re-opened listener first replays the offline cache,
  /// so data alone doesn't prove the server accepted it.
  static const Duration _upAfter = Duration(seconds: 5);

  void _listen() {
    _sub = open().listen(
      (data) {
        if (_cancelled) return;
        if (_failures > 0) {
          _upTimer ??= Timer(_upAfter, () {
            _upTimer = null;
            SyncStatus.instance.reportListenerUp(_key);
          });
          _healthyTimer ??= Timer(const Duration(seconds: 60), () {
            _healthyTimer = null;
            _failures = 0;
          });
        }
        onData(data);
      },
      onError: _onError,
    );
  }

  void _onError(Object error) {
    if (_cancelled) return;
    _sub?.cancel();
    _sub = null;
    _upTimer?.cancel();
    _upTimer = null;
    _healthyTimer?.cancel();
    _healthyTimer = null;
    _failures++;

    if (FirebaseAuth.instance.currentUser == null) {
      // Signed out: the sign-in screen takes over; nothing to reconnect.
      debugPrint('ResilientSubscription: $debugLabel failed while signed '
          'out ($error) — not reconnecting');
      SyncStatus.instance.reportListenerUp(_key);
      return;
    }

    final delay = _delays[math.min(_failures - 1, _delays.length - 1)];
    debugPrint('ResilientSubscription: $debugLabel listener failed '
        '(#$_failures): $error — reopening in ${delay.inSeconds}s');
    _lastError = error;
    SyncStatus.instance.reportListenerDown(
      _key,
      userLabel,
      attempt: _failures,
      nextRetryAt: DateTime.now().add(delay),
      retryNow: retryNow,
    );

    _retryTimer?.cancel();
    _retryTimer = Timer(delay, _reopen);
  }

  Object? _lastError;

  /// Re-opens a failed listener now instead of waiting for the next retry
  /// (the banner's "Try now"). No-op while it is listening.
  void retryNow() {
    if (_cancelled || _sub != null) return;
    _retryTimer?.cancel();
    unawaited(_reopen());
  }

  Future<void> _reopen() async {
    _retryTimer = null;
    final code = _lastError == null ? null : firebaseErrorCode(_lastError!);
    if (code == 'permission-denied' || code == 'unauthenticated') {
      // Usually a stale sign-in token (e.g. after sleep). Get a fresh one.
      try {
        await FirebaseAuth.instance.currentUser?.getIdToken(true);
      } catch (e) {
        debugPrint('ResilientSubscription: token refresh failed: $e');
      }
    }
    if (_cancelled || _sub != null) return;
    // Shown as "reconnecting now" until it either works or fails again.
    SyncStatus.instance.reportListenerDown(_key, userLabel,
        attempt: _failures, nextRetryAt: null, retryNow: retryNow);
    _listen();
  }

  Future<void> cancel() {
    _cancelled = true;
    _retryTimer?.cancel();
    _upTimer?.cancel();
    _healthyTimer?.cancel();
    SyncStatus.instance.reportListenerUp(_key);
    return _sub?.cancel() ?? Future<void>.value();
  }
}
