// services/sync_status.dart
//
// One app-wide answer to "is what I'm looking at live, and have my changes
// reached the server?" — shown by SyncStatusBanner at the top of the app.
//
// Offline persistence is on everywhere, so every listener first serves the
// local cache and then quietly waits for the server. On a slow or dropped
// connection the screen kept showing that cache, schedule writes retried
// forever in the background and dead listeners only wrote to the debug
// console — the user had no way to tell the app wasn't syncing.
//
// Signals combined here:
//  * the device's network state (connectivity_plus);
//  * a metadata listener on `appConfig/version`. AppVersionService already
//    watches that doc, so this shares its watch target — no extra reads —
//    and `isFromCache` says whether Firestore is currently in sync with the
//    server (it flips to true for every listener when the connection drops);
//  * writes reported by providers that have not reached the server yet;
//  * listeners that failed and are being re-opened (ResilientSubscription);
//  * a once-a-minute server read (the heartbeat). A connection can look open
//    — listeners not "from cache" — while delivering nothing; the heartbeat
//    times out then, the banner shows, and the connection is reset.
//
// Avoiding false alarms (a warning nobody can act on only teaches people to
// ignore the banner):
//  * a dropped feed gets a quiet reconnect first — the red banner shows only
//    if it is still down after [feedGrace];
//  * one missed server check is a blip — two in a row are a problem;
//  * when the connection itself is down, every feed fails with it: the
//    connection message is shown, not a list of stopped feeds;
//  * coming back to a hidden tab or a woken laptop, the browser has paused
//    the app — it gets [resumeGrace] to catch up before anything new shows;
//  * a connection warning clears only after things stay healthy for
//    [clearAfter], so a flaky line doesn't flash yellow/green/yellow;
//  * a desktop notification is sent only if a connection problem lasts
//    [escalateAfter] while the app is in the background, once per incident.
import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';

import '../utils/browser_notification.dart';
import '../utils/unsaved_changes_guard.dart';

/// The browser's storage for this site, as measured by StorageHealth.
enum StorageCondition {
  ok,

  /// The computer is nearly out of disk space for the site.
  lowDisk,

  /// localStorage is filling up; saves will stop when it is full.
  nearlyFull,

  /// localStorage is full (or a save already failed with QuotaExceeded):
  /// changes are not saving.
  full,
}

enum SyncProblem {
  none,

  /// The browser's storage for this site is full — nothing can save.
  storageFull,

  /// The browser's storage is nearly full, or the disk nearly out of space.
  storageLow,

  /// The device has no network, and Firestore agrees.
  offline,

  /// A live listener died and is being re-opened.
  liveUpdatesStopped,

  /// Firestore has not been in sync with the server for [SyncStatus.slowAfter].
  slowConnection,

  /// Changes have been waiting to save for [SyncStatus.slowAfter].
  savingSlowly,
}

/// The problems that mean "what you see may be out of date".
bool isConnectionProblem(SyncProblem p) =>
    p == SyncProblem.offline ||
    p == SyncProblem.slowConnection ||
    p == SyncProblem.liveUpdatesStopped;

/// One live feed (the schedule, the Job List, payroll…) that has failed.
class _FeedOutage {
  final String what;
  int attempt = 1;
  DateTime? nextRetryAt;
  VoidCallback? retryNow;

  /// Still down after [SyncStatus.feedGrace] — worth telling the user.
  bool longDown = false;
  Timer? graceTimer;

  _FeedOutage(this.what);
}

class SyncStatus extends ChangeNotifier {
  SyncStatus._() {
    _armCacheTimer();
  }
  static final SyncStatus instance = SyncStatus._();

  /// A fresh, unstarted instance for tests (no Firebase, no plugins).
  @visibleForTesting
  SyncStatus.forTest() {
    _armCacheTimer();
  }

  /// Stands in for the probe listener in tests.
  @visibleForTesting
  void debugSetFromCache(bool fromCache) => _setFromCache(fromCache);

  /// How long a wait is tolerated before the banner says something. Short
  /// waits are normal (cache first, server a moment later) and not worth a
  /// flash of yellow.
  static const Duration slowAfter = Duration(seconds: 8);

  /// How long "Back online" stays up after a problem clears.
  static const Duration recoveredFor = Duration(seconds: 4);

  /// How often the heartbeat reads from the server while the app is in
  /// front, and how often once it has failed.
  static const Duration heartbeatEvery = Duration(seconds: 60);
  static const Duration heartbeatRetry = Duration(seconds: 15);
  static const Duration heartbeatTimeout = Duration(seconds: 12);

  /// A dropped feed's first reconnect (after 2 s) normally works; only one
  /// still down after this is shown.
  static const Duration feedGrace = Duration(seconds: 10);

  /// After the app comes back to the front, how long it gets to catch up
  /// before a new connection warning may show.
  static const Duration resumeGrace = Duration(seconds: 6);

  /// How long things must stay healthy before a connection warning clears.
  static const Duration clearAfter = Duration(seconds: 3);

  /// A connection problem lasting this long turns the banner red, offers a
  /// reload and (if the app is in the background) sends a desktop notice.
  static const Duration escalateAfter = Duration(minutes: 2);

  /// Server checks that must fail in a row before it counts as a problem.
  static const int heartbeatFailuresToWarn = 2;

  bool _resumeGraceActive = false;
  Timer? _resumeGraceTimer;
  Timer? _clearTimer;
  Timer? _escalateTimer;
  bool _escalated = false;
  bool _desktopNoticeSent = false;
  DateTime? _lastLiveAt;
  DateTime? _problemSince;
  DateTime? _nextServerCheckAt;

  bool _started = false;
  Timer? _heartbeatTimer;
  AppLifecycleListener? _lifecycle;
  bool _checking = false;
  int _heartbeatFailures = 0;

  /// The last heartbeat could not reach the server in time.
  bool _heartbeatStale = false;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _probeSub;
  Timer? _probeRetry;
  int _probeFailures = 0;

  bool _deviceOffline = false;

  /// True until the probe's first server snapshot, and again whenever the
  /// connection drops.
  bool _fromCache = true;
  bool _everLive = false;

  /// Set by timers once a wait has lasted [slowAfter] — timers rather than
  /// clock arithmetic, so a sleeping laptop's clock jump can't confuse it.
  Timer? _cacheTimer;
  bool _cacheTooLong = false;
  Timer? _pendingTimer;
  bool _pendingTooLong = false;

  final Map<String, int> _pendingWrites = {};
  final Set<String> _retryingWrites = {};

  /// key → the failed feed.
  final Map<String, _FeedOutage> _downFeeds = {};

  Timer? _recoveredTimer;
  SyncProblem _problem = SyncProblem.none;
  bool _showRecovered = false;

  SyncProblem get problem => _problem;

  /// The device reports no network at all (Wi-Fi and mobile data off).
  /// Instant, unlike [problem], which waits for Firestore to notice.
  bool get deviceOffline => _deviceOffline;

  StorageCondition _storage = StorageCondition.ok;
  int _storagePercent = 0;
  int? _diskFreeMb;
  bool _storageNeedsReload = false;

  StorageCondition get storageCondition => _storage;

  /// How full localStorage is, 0–100.
  int get storagePercentFull => _storagePercent;

  /// Free disk space for the site in MB, when it is low.
  int? get diskFreeMb => _diskFreeMb;

  /// A save already failed for lack of space, so Firestore needs a reload.
  bool get storageNeedsReload => _storageNeedsReload;

  /// A problem just cleared; the banner briefly says so.
  bool get showRecovered => _showRecovered;

  /// The probe has never had a server snapshot this session.
  bool get neverReachedServer => !_everLive;

  int get pendingWriteCount =>
      _pendingWrites.values.fold(0, (total, n) => total + n);

  /// Some feed has failed, even one still inside its quiet [feedGrace]. Not
  /// shown to the user, but money decisions wait for it to recover.
  bool get anyFeedDown => _downFeeds.isNotEmpty;

  /// Feeds down for longer than [feedGrace], in words ("the schedule").
  List<String> get stoppedFeeds => {
        for (final f in _downFeeds.values)
          if (f.longDown) f.what
      }.toList();

  /// When the next automatic reconnect of a stopped feed happens; null while
  /// one is reconnecting right now.
  DateTime? get nextReconnectAt {
    DateTime? next;
    for (final f in _downFeeds.values) {
      if (!f.longDown) continue;
      final at = f.nextRetryAt;
      if (at == null) return null;
      if (next == null || at.isBefore(next)) next = at;
    }
    return next;
  }

  /// How many times the longest-failing feed has been tried.
  int get reconnectAttempts => _downFeeds.values
      .where((f) => f.longDown)
      .fold(0, (m, f) => f.attempt > m ? f.attempt : m);

  /// Reconnect every stopped feed now (the banner's "Try now").
  void retryFeedsNow() {
    for (final f in _downFeeds.values.toList()) {
      f.retryNow?.call();
    }
  }

  /// Server checks failed in a row.
  int get serverCheckFailures => _heartbeatFailures;

  /// When the next automatic server check runs.
  DateTime? get nextServerCheckAt => _nextServerCheckAt;

  /// A server check is running right now.
  bool get checkingServer => _checking;

  /// Check the server now and reset the connection if it's stuck (the
  /// banner's "Check now").
  Future<void> checkNowFromUser() async {
    await checkServerNow();
    if (_heartbeatFailures > 0) unawaited(_resetConnection());
    _scheduleHeartbeat(
        _heartbeatFailures > 0 ? heartbeatRetry : heartbeatEvery);
  }

  /// The last moment the app was known to be in step with the server —
  /// "out of date since". Null if it hasn't been live this session.
  DateTime? get lastLiveAt => _lastLiveAt;

  /// When the current problem started.
  DateTime? get problemSince => _problemSince;

  /// The current connection problem has lasted [escalateAfter].
  bool get escalated => _escalated;

  /// Starts watching. Safe to call more than once.
  void start() {
    if (_started) return;
    _started = true;

    final connectivity = Connectivity();
    unawaited(connectivity.checkConnectivity().then(_onConnectivity,
        onError: (Object e) => debugPrint('SyncStatus: connectivity: $e')));
    _connectivitySub = connectivity.onConnectivityChanged.listen(
      _onConnectivity,
      onError: (Object e) => debugPrint('SyncStatus: connectivity: $e'),
    );

    _listenProbe();
    _scheduleHeartbeat(heartbeatEvery);
    // Coming back to the app (tab shown, laptop woken) checks at once —
    // that is when a dead connection is most likely and most costly.
    _lifecycle = AppLifecycleListener(onResume: _onResume);
    _reevaluate();
  }

  /// The browser pauses a hidden tab (and a sleeping laptop pauses
  /// everything), so on return the connection is briefly behind. Give it
  /// [resumeGrace] to catch up before showing anything new, then check.
  void _onResume() {
    _resumeGraceActive = true;
    if (_fromCache) _armCacheTimer();
    _resumeGraceTimer?.cancel();
    _resumeGraceTimer = Timer(resumeGrace, () {
      _resumeGraceActive = false;
      _reevaluate();
    });
    unawaited(checkServerNow());
  }

  void _scheduleHeartbeat(Duration after) {
    _heartbeatTimer?.cancel();
    _nextServerCheckAt = DateTime.now().add(after);
    _heartbeatTimer = Timer(after, () async {
      await checkServerNow();
      _scheduleHeartbeat(
          _heartbeatFailures > 0 ? heartbeatRetry : heartbeatEvery);
    });
  }

  /// Reads one tiny document from the server (one read). Skipped while the
  /// app is in the background or the device is offline.
  Future<void> checkServerNow() async {
    if (_checking || _deviceOffline) return;
    final state = WidgetsBinding.instance.lifecycleState;
    if (state != null && state != AppLifecycleState.resumed) return;
    _checking = true;
    if (_problem != SyncProblem.none) notifyListeners();
    try {
      await FirebaseFirestore.instance
          .collection('appConfig')
          .doc('version')
          .get(const GetOptions(source: Source.server))
          .timeout(heartbeatTimeout);
      _heartbeatFailures = 0;
      if (!_fromCache) _lastLiveAt = DateTime.now();
      if (_heartbeatStale) {
        _heartbeatStale = false;
      }
      _reevaluate();
    } catch (e) {
      _heartbeatFailures++;
      debugPrint('SyncStatus: server check failed (#$_heartbeatFailures): $e');
      // One missed check is a blip; two in a row (15 s apart) a problem.
      if (!_heartbeatStale && _heartbeatFailures >= heartbeatFailuresToWarn) {
        _heartbeatStale = true;
      }
      _reevaluate(force: _problem != SyncProblem.none);
      // A stuck connection doesn't always recover by itself: restart it.
      if (_heartbeatFailures == 2 || _heartbeatFailures % 6 == 0) {
        unawaited(_resetConnection());
      }
    } finally {
      _checking = false;
      if (_problem != SyncProblem.none) notifyListeners();
    }
  }

  /// Drops and reopens Firestore's connection. Listeners resume by
  /// themselves; a write in flight fails as "unavailable" and the write
  /// queues retry it.
  Future<void> _resetConnection() async {
    debugPrint('SyncStatus: resetting the Firestore connection');
    try {
      await FirebaseFirestore.instance.disableNetwork();
      await Future<void>.delayed(const Duration(seconds: 1));
    } catch (e) {
      debugPrint('SyncStatus: disableNetwork failed: $e');
    } finally {
      try {
        await FirebaseFirestore.instance.enableNetwork();
      } catch (e) {
        debugPrint('SyncStatus: enableNetwork failed: $e');
      }
    }
  }

  /// Stands in for a heartbeat result in tests.
  @visibleForTesting
  void debugSetHeartbeatStale(bool stale) {
    _heartbeatStale = stale;
    _reevaluate();
  }

  void _onConnectivity(List<ConnectivityResult> results) {
    // Only an explicit "none" counts as offline. VPN, bluetooth and "other"
    // all carry traffic, and Firestore's own view settles the rest.
    final offline =
        results.isEmpty || results.every((r) => r == ConnectivityResult.none);
    if (offline == _deviceOffline) return;
    _deviceOffline = offline;
    _reevaluate();
  }

  void _listenProbe() {
    _probeSub?.cancel();
    _probeSub = FirebaseFirestore.instance
        .collection('appConfig')
        .doc('version')
        .snapshots(includeMetadataChanges: true)
        .listen(
      (snap) {
        _probeFailures = 0;
        _setFromCache(snap.metadata.isFromCache);
      },
      onError: (Object e) {
        // The listener is closed for good after an error; open a new one.
        debugPrint('SyncStatus: probe listener failed: $e');
        _setFromCache(true);
        _probeFailures++;
        final seconds =
            const [2, 5, 15, 30, 60][(_probeFailures - 1).clamp(0, 4)];
        _probeRetry?.cancel();
        _probeRetry = Timer(Duration(seconds: seconds), _listenProbe);
      },
    );
  }

  void _setFromCache(bool fromCache) {
    if (!fromCache) {
      _everLive = true;
      _lastLiveAt = DateTime.now();
    }
    if (fromCache == _fromCache) return;
    _fromCache = fromCache;
    if (fromCache) {
      // Dropped again while the warning is still up (a flaky line): keep it
      // up rather than restarting the wait and flickering off and on.
      if (isConnectionProblem(_problem) && _cacheTooLong) {
        _reevaluate();
        return;
      }
      _armCacheTimer();
    } else {
      _cacheTimer?.cancel();
      // Kept while the warning is up, so a re-drop within [clearAfter]
      // keeps it showing; reset once it has really cleared (see _apply).
      if (!isConnectionProblem(_problem)) _cacheTooLong = false;
    }
    _reevaluate();
  }

  void _armCacheTimer() {
    _cacheTimer?.cancel();
    _cacheTooLong = false;
    _cacheTimer = Timer(slowAfter, () {
      _cacheTooLong = true;
      _reevaluate();
    });
  }

  /// [source] has [count] writes that have not reached the server yet.
  void reportPendingWrites(String source, int count) {
    final before = pendingWriteCount;
    if (count <= 0) {
      _pendingWrites.remove(source);
      _retryingWrites.remove(source);
    } else {
      _pendingWrites[source] = count;
    }
    final after = pendingWriteCount;
    // Warn before the web page closes while any of them is unsaved.
    setUnsavedChangesGuard(after > 0);
    if (after == 0) {
      _pendingTimer?.cancel();
      _pendingTooLong = false;
    } else if (before == 0) {
      _pendingTimer?.cancel();
      _pendingTimer = Timer(slowAfter, () {
        _pendingTooLong = true;
        _reevaluate();
      });
    }
    _reevaluate(force: before != after && _problem != SyncProblem.none);
  }

  /// From StorageHealth: how the browser's storage for this site is doing.
  void reportStorage(
    StorageCondition condition, {
    int percentFull = 0,
    int? diskFreeMb,
    bool needsReload = false,
  }) {
    if (condition == _storage &&
        percentFull == _storagePercent &&
        diskFreeMb == _diskFreeMb &&
        needsReload == _storageNeedsReload) {
      return;
    }
    _storage = condition;
    _storagePercent = percentFull;
    _diskFreeMb = diskFreeMb;
    _storageNeedsReload = needsReload;
    _reevaluate(force: true);
  }

  /// A write from [source] failed for a network reason and is being retried.
  void reportWriteRetrying(String source, bool retrying) {
    final changed =
        retrying ? _retryingWrites.add(source) : _retryingWrites.remove(source);
    if (changed) _reevaluate();
  }

  /// The listener [key] died and is being re-opened. [what] names what it
  /// feeds, for the banner ("the schedule"); [attempt] and [nextRetryAt]
  /// (null = reconnecting now) drive the countdown, [retryNow] "Try now".
  void reportListenerDown(String key, String what,
      {int attempt = 1, DateTime? nextRetryAt, VoidCallback? retryNow}) {
    final feed = _downFeeds.putIfAbsent(key, () {
      final f = _FeedOutage(what);
      // Quietly retried first: shown only if still down after [feedGrace].
      f.graceTimer = Timer(feedGrace, () {
        f.longDown = true;
        _reevaluate();
      });
      return f;
    });
    feed
      ..attempt = attempt
      ..nextRetryAt = nextRetryAt
      ..retryNow = retryNow;
    _reevaluate(force: feed.longDown);
  }

  void reportListenerUp(String key) {
    final feed = _downFeeds.remove(key);
    if (feed == null) return;
    feed.graceTimer?.cancel();
    _reevaluate();
  }

  /// Stands in for [feedGrace] passing, in tests.
  @visibleForTesting
  void debugExpireFeedGrace() {
    for (final f in _downFeeds.values) {
      f.graceTimer?.cancel();
      f.longDown = true;
    }
    _reevaluate();
  }

  SyncProblem _compute() {
    // First: when storage is full nothing saves, online or not.
    if (_storage == StorageCondition.full) return SyncProblem.storageFull;
    // Just back from the background: let the connection catch up before
    // raising a NEW connection warning (one already showing stays).
    final quiet = _resumeGraceActive && !isConnectionProblem(_problem);
    if (_deviceOffline && _fromCache) return SyncProblem.offline;
    // The connection outranks individual feeds: when it's down they all
    // fail with it, and one message is clearer than a list.
    if (!quiet && ((_fromCache && _cacheTooLong) || _heartbeatStale)) {
      return SyncProblem.slowConnection;
    }
    if (!quiet && _downFeeds.values.any((f) => f.longDown)) {
      return SyncProblem.liveUpdatesStopped;
    }
    if (pendingWriteCount > 0 &&
        (_retryingWrites.isNotEmpty || _pendingTooLong)) {
      return SyncProblem.savingSlowly;
    }
    if (_storage != StorageCondition.ok) return SyncProblem.storageLow;
    return SyncProblem.none;
  }

  void _reevaluate({bool force = false}) {
    final next = _compute();
    // A connection warning only clears once things have stayed healthy for
    // [clearAfter] — otherwise a flaky line flashes yellow/green/yellow.
    if (isConnectionProblem(_problem) &&
        !isConnectionProblem(next) &&
        // Something worse replaces it at once.
        next != SyncProblem.storageFull) {
      _clearTimer ??= Timer(clearAfter, () {
        _clearTimer = null;
        _apply(_compute(), force: true);
      });
      if (force) notifyListeners();
      return;
    }
    _clearTimer?.cancel();
    _clearTimer = null;
    _apply(next, force: force);
  }

  void _apply(SyncProblem next, {bool force = false}) {
    if (next == _problem && !force) return;
    final wasConnection = isConnectionProblem(_problem);
    if (next != _problem) {
      _problemSince = next == SyncProblem.none ? null : DateTime.now();
      if (next == SyncProblem.none) _lastLiveAt = DateTime.now();
    }
    if (isConnectionProblem(next)) {
      if (!wasConnection) {
        _escalated = false;
        _escalateTimer?.cancel();
        _escalateTimer = Timer(escalateAfter, _escalate);
      }
    } else {
      _escalateTimer?.cancel();
      _escalated = false;
      if (!_fromCache) _cacheTooLong = false;
      if (wasConnection && _desktopNoticeSent) {
        _desktopNoticeSent = false;
        if (_inBackground) {
          showBrowserNotification(
            title: 'CLM Schedule is back online',
            body: 'Everything is up to date again.',
            tag: 'clm-sync',
          );
        }
      }
    }
    // "Back online" is about the connection; a storage warning clearing
    // (space freed) is not worth a flash of green.
    final wasProblem = _problem != SyncProblem.none &&
        _problem != SyncProblem.storageLow &&
        // A save that was merely slow isn't worth a "back online".
        _problem != SyncProblem.savingSlowly;
    _problem = next;
    if (next == SyncProblem.none && wasProblem) {
      _showRecovered = true;
      _recoveredTimer?.cancel();
      _recoveredTimer = Timer(recoveredFor, () {
        _showRecovered = false;
        notifyListeners();
      });
    } else if (next != SyncProblem.none) {
      _showRecovered = false;
      _recoveredTimer?.cancel();
    }
    notifyListeners();
  }

  static bool get _inBackground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state != null && state != AppLifecycleState.resumed;
  }

  void _escalate() {
    if (!isConnectionProblem(_problem)) return;
    _escalated = true;
    notifyListeners();
    // The banner can't be seen from another tab: tell them once.
    if (_inBackground && !_desktopNoticeSent) {
      _desktopNoticeSent = true;
      showBrowserNotification(
        title: 'CLM Schedule is not up to date',
        body: _problem == SyncProblem.offline
            ? "You've been offline for 2 minutes. Don't rely on the schedule "
                "or payroll figures until it's back."
            : "The connection to the server has been down for 2 minutes. "
                "Don't rely on the schedule or payroll figures until it's "
                'back.',
        tag: 'clm-sync',
      );
    }
  }

  /// Stands in for [escalateAfter] passing, in tests.
  @visibleForTesting
  void debugEscalate() => _escalate();

  @override
  void dispose() {
    // Singleton: never disposed in the app. Kept for tests.
    _resumeGraceTimer?.cancel();
    _clearTimer?.cancel();
    _escalateTimer?.cancel();
    for (final f in _downFeeds.values) {
      f.graceTimer?.cancel();
    }
    _connectivitySub?.cancel();
    _probeSub?.cancel();
    _probeRetry?.cancel();
    _heartbeatTimer?.cancel();
    _lifecycle?.dispose();
    _cacheTimer?.cancel();
    _pendingTimer?.cancel();
    _recoveredTimer?.cancel();
    super.dispose();
  }
}
