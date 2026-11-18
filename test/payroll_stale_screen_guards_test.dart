// Guards added after distributors were paid short on 6 Nov 2026, when an
// admin's PC showed out-of-date payroll figures.
import 'dart:async';

import 'package:clmschedule/models/distributor_payroll_profile.dart';
import 'package:clmschedule/models/payment_status.dart';
import 'package:clmschedule/models/payroll_daily_entry.dart';
import 'package:clmschedule/models/payroll_payslip.dart';
import 'package:clmschedule/models/payroll_settings.dart';
import 'package:clmschedule/providers/payroll_provider.dart';
import 'package:clmschedule/services/payroll_service.dart';
import 'package:clmschedule/services/sync_status.dart';
import 'package:clmschedule/utils/write_retry.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final day = DateTime(2026, 11, 5);
  PayrollDailyEntry sets(int n, {bool auto = false}) => PayrollDailyEntry(
      date: day, worked: true, flyerSets: n, autoDefault: auto);

  group('dayEditStillApplies (Ops Stats compare-and-set)', () {
    test('the 18:26 overwrite is refused: a stale cell cannot undo a newer '
        'value', () {
      // Mandla: the grid still showed the automatic 1, Barrie had saved 2.
      expect(
        dayEditStillApplies(
            current: sets(2), basedOn: sets(1, auto: true), wanted: sets(1, auto: true)),
        isFalse,
      );
    });

    test('a real edit on an up-to-date cell is saved', () {
      expect(
        dayEditStillApplies(
            current: sets(1, auto: true),
            basedOn: sets(1, auto: true),
            wanted: PayrollDailyEntry(
                date: day, worked: true, specialCode: 'WC')),
        isTrue,
      );
    });

    test('a retry of an edit that already landed still applies', () {
      expect(
        dayEditStillApplies(current: sets(2), basedOn: sets(1), wanted: sets(2)),
        isTrue,
      );
    });

    test('the date is not part of the comparison', () {
      expect(
          sameDailyEntry(sets(1),
              PayrollDailyEntry(date: DateTime(2020), worked: true, flyerSets: 1)),
          isTrue);
    });
  });

  group('payslip paid record', () {
    final blank = PayrollPayslip.blank(
      distributorId: 'd1',
      distributorName: 'Dickson',
      weekStart: DateTime(2026, 10, 30),
      settings: PayrollSettings.defaults(),
      profile: const DistributorPayrollProfile(),
    );

    test('round-trips through Firestore and clears when unpaid', () {
      final paidAt = DateTime(2026, 11, 6, 18, 38);
      final paid = blank.copyWith(
          paymentStatus: PaymentStatus.paid,
          paidAmount: 1609,
          paidAt: paidAt,
          paidBy: 'barrie@example.com');
      final back = PayrollPayslip.fromMap('d1', paid.toMap());
      expect(back.paidAmount, 1609);
      expect(back.paidAt, paidAt);
      expect(back.paidBy, 'barrie@example.com');
      expect(back.toMap()['paidAt'], isA<Timestamp>());

      final unpaid = back.copyWith(
          paymentStatus: PaymentStatus.notPaid, clearPaid: true);
      expect(unpaid.paidAmount, isNull);
      expect(unpaid.toMap().containsKey('paidAmount'), isFalse);
    });

    test('a change in the paid record is a real change', () {
      expect(
          payslipsMatchIgnoringStamp(blank, blank.copyWith(paidAmount: 10)),
          isFalse);
    });
  });

  group('isRetryableWriteError', () {
    test('connection and contention failures retry, others do not', () {
      expect(isRetryableWriteError(TimeoutException('x'), attempt: 1), isTrue);
      expect(
          isRetryableWriteError(
              FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
              attempt: 3),
          isTrue);
      expect(
          isRetryableWriteError(
              FirebaseException(
                  plugin: 'cloud_firestore', code: 'permission-denied'),
              attempt: 1),
          isFalse);
      expect(isRetryableWriteError(StateError('bug'), attempt: 1), isFalse);
    });
  });

  group('SyncStatus heartbeat', () {
    testWidgets('a failed server check shows the banner until one succeeds',
        (tester) async {
      final s = SyncStatus.forTest()..debugSetFromCache(false);
      expect(s.problem, SyncProblem.none);
      s.debugSetHeartbeatStale(true);
      expect(s.problem, SyncProblem.slowConnection);
      expect(s.neverReachedServer, isFalse);
      s.debugSetHeartbeatStale(false);
      await tester.pump(SyncStatus.clearAfter + const Duration(milliseconds: 100));
      expect(s.problem, SyncProblem.none);
      expect(s.showRecovered, isTrue);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('unsaved writes from schedule and payroll add up',
        (tester) async {
      final s = SyncStatus.forTest()..debugSetFromCache(false);
      s.reportPendingWrites('schedule', 1);
      s.reportPendingWrites('payroll', 2);
      expect(s.pendingWriteCount, 3);
      s.reportPendingWrites('schedule', 0);
      expect(s.pendingWriteCount, 2);
      s.reportPendingWrites('payroll', 0);
      await tester.pump(const Duration(seconds: 20));
      expect(s.problem, SyncProblem.none);
    });
  });
}
