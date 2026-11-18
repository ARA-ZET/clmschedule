import 'package:clmschedule/services/storage_health.dart';
import 'package:clmschedule/services/sync_status.dart';
import 'package:flutter_test/flutter_test.dart';

// testWidgets runs in a fake clock, so tester.pump(duration) drives the
// SyncStatus threshold timers without real waiting.
void main() {
  testWidgets('cache-only view becomes "slow connection" after the threshold',
      (tester) async {
    final s = SyncStatus.forTest();
    expect(s.problem, SyncProblem.none);
    await tester.pump(SyncStatus.slowAfter + const Duration(milliseconds: 100));
    expect(s.problem, SyncProblem.slowConnection);
    expect(s.neverReachedServer, isTrue);

    s.debugSetFromCache(false);
    // Clears only once it has stayed healthy for a moment (no flicker).
    expect(s.problem, SyncProblem.slowConnection);
    await tester.pump(SyncStatus.clearAfter + const Duration(milliseconds: 100));
    expect(s.problem, SyncProblem.none);
    expect(s.showRecovered, isTrue);
    await tester.pump(SyncStatus.recoveredFor + const Duration(seconds: 1));
    expect(s.showRecovered, isFalse);
  });

  testWidgets('a brief blip while warning does not flash green', (tester) async {
    final s = SyncStatus.forTest();
    await tester.pump(SyncStatus.slowAfter + const Duration(milliseconds: 100));
    expect(s.problem, SyncProblem.slowConnection);
    s.debugSetFromCache(false);
    await tester.pump(const Duration(seconds: 1));
    s.debugSetFromCache(true); // dropped again within clearAfter
    await tester.pump(SyncStatus.clearAfter);
    expect(s.problem, SyncProblem.slowConnection);
    expect(s.showRecovered, isFalse);
    s.debugSetFromCache(false);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a quick save never shows the banner', (tester) async {
    final s = SyncStatus.forTest()..debugSetFromCache(false);
    s.reportPendingWrites('schedule', 1);
    await tester.pump(const Duration(seconds: 2));
    s.reportPendingWrites('schedule', 0);
    await tester.pump(const Duration(seconds: 20));
    expect(s.problem, SyncProblem.none);
    expect(s.showRecovered, isFalse);
  });

  testWidgets('a slow or retrying save is reported with its count',
      (tester) async {
    final s = SyncStatus.forTest()..debugSetFromCache(false);
    s.reportPendingWrites('schedule', 2);
    await tester.pump(SyncStatus.slowAfter + const Duration(milliseconds: 100));
    expect(s.problem, SyncProblem.savingSlowly);
    expect(s.pendingWriteCount, 2);

    s.reportPendingWrites('schedule', 0);
    expect(s.problem, SyncProblem.none);

    // A network failure flags it at once, without waiting for the threshold.
    s.reportPendingWrites('schedule', 1);
    s.reportWriteRetrying('schedule', true);
    expect(s.problem, SyncProblem.savingSlowly);
    s.reportPendingWrites('schedule', 0);
    expect(s.problem, SyncProblem.none);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a feed that reconnects quickly never shows a warning',
      (tester) async {
    final s = SyncStatus.forTest()..debugSetFromCache(false);
    s.reportListenerDown('a', 'the schedule');
    expect(s.problem, SyncProblem.none);
    expect(s.anyFeedDown, isTrue); // payments still wait for it
    await tester.pump(const Duration(seconds: 5));
    s.reportListenerUp('a');
    await tester.pump(const Duration(seconds: 20));
    expect(s.problem, SyncProblem.none);
    expect(s.showRecovered, isFalse);
  });

  testWidgets('dead listeners show after the grace, with their countdown, and '
      'clear when back up', (tester) async {
    final s = SyncStatus.forTest()..debugSetFromCache(false);
    final next = DateTime.now().add(const Duration(seconds: 15));
    var retried = 0;
    s.reportListenerDown('a', 'the schedule',
        attempt: 3, nextRetryAt: next, retryNow: () => retried++);
    s.reportListenerDown('b', 'the Job List');
    await tester.pump(SyncStatus.feedGrace + const Duration(milliseconds: 100));
    expect(s.problem, SyncProblem.liveUpdatesStopped);
    expect(s.stoppedFeeds, ['the schedule', 'the Job List']);
    expect(s.reconnectAttempts, 3);
    expect(s.nextReconnectAt, isNull); // 'b' is reconnecting right now
    s.retryFeedsNow();
    expect(retried, 1);
    s.reportListenerUp('a');
    s.reportListenerUp('b');
    await tester.pump(SyncStatus.clearAfter + const Duration(milliseconds: 100));
    expect(s.problem, SyncProblem.none);
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a lost connection is one message, not a list of dead feeds',
      (tester) async {
    final s = SyncStatus.forTest()..debugSetFromCache(false);
    s.reportListenerDown('a', 'the schedule');
    s.debugExpireFeedGrace();
    expect(s.problem, SyncProblem.liveUpdatesStopped);
    s.debugSetHeartbeatStale(true);
    expect(s.problem, SyncProblem.slowConnection);
    s.debugSetHeartbeatStale(false);
    s.reportListenerUp('a');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('a long outage escalates', (tester) async {
    final s = SyncStatus.forTest();
    await tester.pump(SyncStatus.slowAfter + const Duration(milliseconds: 100));
    expect(s.escalated, isFalse);
    await tester.pump(SyncStatus.escalateAfter);
    expect(s.escalated, isTrue);
    s.debugSetFromCache(false);
    await tester.pump(const Duration(seconds: 10));
    expect(s.escalated, isFalse);
  });

  testWidgets('full browser storage outranks everything, even offline',
      (tester) async {
    final s = SyncStatus.forTest()..debugSetFromCache(false);
    s.reportListenerDown('schedule', 'the schedule');
    s.debugExpireFeedGrace();
    expect(s.problem, SyncProblem.liveUpdatesStopped);

    s.reportStorage(StorageCondition.full, percentFull: 100, needsReload: true);
    expect(s.problem, SyncProblem.storageFull);
    expect(s.storageNeedsReload, isTrue);

    s.reportStorage(StorageCondition.ok);
    expect(s.problem, SyncProblem.liveUpdatesStopped);
    s.reportListenerUp('schedule');
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('nearly-full storage warns only when nothing worse is going on',
      (tester) async {
    final s = SyncStatus.forTest()..debugSetFromCache(false);
    s.reportStorage(StorageCondition.nearlyFull, percentFull: 82);
    expect(s.problem, SyncProblem.storageLow);
    expect(s.storagePercentFull, 82);

    s.reportListenerDown('jobList', 'the Job List');
    s.debugExpireFeedGrace();
    expect(s.problem, SyncProblem.liveUpdatesStopped);
    s.reportListenerUp('jobList');
    await tester.pump(SyncStatus.clearAfter + const Duration(milliseconds: 100));
    expect(s.problem, SyncProblem.storageLow);

    // Clearing a storage warning is not "back online".
    s.reportStorage(StorageCondition.ok);
    expect(s.problem, SyncProblem.none);
    expect(s.showRecovered, isFalse);
    await tester.pump(const Duration(seconds: 10));
  });

  test('recognises the browser quota error however it is wrapped', () {
    expect(
        StorageHealth.isStorageFullError(
            "An unknown error occurred: QuotaExceededError: Failed to execute "
            "'setItem' on 'Storage': Setting the value of 'firebase:authUser:"
            "x:[DEFAULT]' exceeded the quota."),
        isTrue);
    expect(
        StorageHealth.isStorageFullError(
            'FIRESTORE INTERNAL ASSERTION FAILED: AsyncQueue is already '
            'failed: QuotaExceededError'),
        isTrue);
    expect(StorageHealth.isStorageFullError('[cloud_firestore/unavailable]'),
        isFalse);
    expect(StorageHealth.isStorageFullError(null), isFalse);
  });
}
