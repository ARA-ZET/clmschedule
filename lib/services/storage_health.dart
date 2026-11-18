// services/storage_health.dart
//
// Watches the browser's storage for this site so a full one is caught and
// fixed before it stops the app saving.
//
// Nov 2026: Barrie's PC filled the site's localStorage (~5M characters).
// Firebase Auth keeps the sign-in token there and Firestore's multi-tab sync
// writes tab/query/write state there without catching errors, so every save
// threw — silently — and in the end he couldn't even sign in
// ("QuotaExceededError: Failed to execute 'setItem' on 'Storage'").
//
//  * web/index.html tidies localStorage on every page load, before Firebase
//    starts (leftovers only; everything but the sign-in token when it is
//    actually full or the user pressed "Fix now").
//  * This service repeats the safe tidy every few minutes while the app
//    runs, probes that ~32K characters can still be written, watches the
//    computer's free disk space, and catches QuotaExceededError from
//    anywhere — reporting to SyncStatus, which shows a red/amber banner
//    with a "Fix now" button.
//  * When a load had to clean up, what filled it is uploaded to
//    `storageIncidents` once signed in, so the cause can be found.
//
// localStorage never holds a user's unsaved changes (Firestore keeps them in
// IndexedDB), so tidying it can't lose work. Off the web this is a no-op.
import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'storage_health_stub.dart'
    if (dart.library.js_interop) 'storage_health_web.dart' as platform;
import 'sync_status.dart';

class StorageHealth {
  StorageHealth._();
  static final StorageHealth instance = StorageHealth._();

  static const Duration checkEvery = Duration(minutes: 3);

  /// Warn when localStorage is fuller than this (the page tidies leftovers
  /// first, so reaching it means something keeps writing).
  static const double nearlyFullAt = 0.7;

  /// Warn when the computer has less free space than this for the site.
  static const int lowDiskBytes = 100 * 1024 * 1024;

  bool _started = false;
  Timer? _timer;
  AppLifecycleListener? _lifecycle;
  StreamSubscription<User?>? _authSub;

  /// A QuotaExceededError was seen. Firestore's queue may be broken until
  /// the page reloads, so this stays set even if space frees up.
  bool _errorSeen = false;
  bool _checking = false;
  bool _uploading = false;

  /// The last localStorage report from the page.
  Map<String, dynamic>? lastReport;

  /// True for the browser's "storage is full" error, however it was wrapped
  /// (Firebase Auth "unknown error", Firestore "AsyncQueue is already
  /// failed", …).
  static bool isStorageFullError(Object? error) {
    if (error == null) return false;
    final text = error.toString();
    return text.contains('QuotaExceededError') ||
        text.contains('exceeded the quota');
  }

  void start() {
    if (!kIsWeb || _started) return;
    _started = true;
    _apply(_decode(platform.storageBootReport()));
    unawaited(check());
    _timer = Timer.periodic(checkEvery, (_) => unawaited(check()));
    _lifecycle = AppLifecycleListener(onResume: () => unawaited(check()));
    _authSub = FirebaseAuth.instance.authStateChanges().listen((user) {
      if (user != null) unawaited(_uploadIncident(user));
    });
  }

  /// Tidies leftovers, measures, and updates the banner.
  Future<void> check() async {
    if (!kIsWeb || _checking) return;
    _checking = true;
    try {
      _apply(_decode(platform.runStorageCheck('routine')));
      final est = await platform.storageEstimate();
      if (est != null && est.quota > 0) {
        final free = est.quota - est.usage;
        _lowDiskFree = free < lowDiskBytes ? free : null;
      }
      _report();
    } finally {
      _checking = false;
    }
  }

  /// Call with any error that might be the browser refusing to store data.
  /// Cheap; safe to call with every error.
  void noteError(Object? error) {
    if (!kIsWeb || _errorSeen || !isStorageFullError(error)) return;
    debugPrint('StorageHealth: browser storage full: $error');
    _errorSeen = true;
    // Free what is safe now; the banner offers the full fix.
    _apply(_decode(platform.runStorageCheck('pressure')));
    _report();
  }

  /// Clears this site's localStorage before Firebase starts and reloads.
  /// Saved data and changes still waiting to save (IndexedDB) are kept; the
  /// user may have to sign in again only if even the sign-in token can't fit.
  void fixNow() => platform.fixStorageAndReload();

  int? _lowDiskFree;
  bool _cannotWrite = false;
  double _fraction = 0;

  void _apply(Map<String, dynamic>? report) {
    if (report == null || report['available'] != true) return;
    lastReport = report;
    _cannotWrite = report['canWrite'] == false;
    final used = (report['usedChars'] as num?)?.toDouble();
    final limit = (report['limitChars'] as num?)?.toDouble();
    if (used != null && limit != null && limit > 0) _fraction = used / limit;
  }

  void _report() {
    final StorageCondition condition;
    if (_errorSeen || _cannotWrite) {
      condition = StorageCondition.full;
    } else if (_fraction >= nearlyFullAt) {
      condition = StorageCondition.nearlyFull;
    } else if (_lowDiskFree != null) {
      condition = StorageCondition.lowDisk;
    } else {
      condition = StorageCondition.ok;
    }
    SyncStatus.instance.reportStorage(
      condition,
      percentFull: (_fraction * 100).round(),
      diskFreeMb: _lowDiskFree == null
          ? null
          : (_lowDiskFree! < 0 ? 0 : _lowDiskFree!) ~/ (1024 * 1024),
      needsReload: _errorSeen,
    );
  }

  static Map<String, dynamic>? _decode(String? json) {
    if (json == null) return null;
    try {
      final v = jsonDecode(json);
      return v is Map<String, dynamic> ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Sends what filled storage (recorded by the page load that cleaned it)
  /// to `storageIncidents`, then forgets it.
  Future<void> _uploadIncident(User user) async {
    if (_uploading) return;
    final incident = _decode(platform.readStorageIncident());
    if (incident == null) return;
    _uploading = true;
    try {
      await FirebaseFirestore.instance.collection('storageIncidents').add({
        ...incident,
        'uid': user.uid,
        'email': user.email,
        'userAgent': platform.browserUserAgent(),
        'reportedAt': FieldValue.serverTimestamp(),
      });
      platform.clearStorageIncident();
    } catch (e) {
      debugPrint('StorageHealth: could not upload storage incident: $e');
    } finally {
      _uploading = false;
    }
  }

  @visibleForTesting
  void dispose() {
    _timer?.cancel();
    _lifecycle?.dispose();
    _authSub?.cancel();
  }
}
