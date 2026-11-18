import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/payslip_account.dart';
import 'package:clmschedule/services/payslip_access_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('normalizeSaPhone (must match normalizePhone in payslip_portal.js)', () {
    test('common formats become one number', () {
      for (final raw in [
        '082 123 4567',
        '0821234567',
        '+27 82 123 4567',
        '27821234567',
        '(082) 123-4567',
        '821234567',
      ]) {
        expect(normalizeSaPhone(raw), '0821234567', reason: raw);
      }
    });

    test('anything else is no number', () {
      for (final raw in [null, '', '12345', '08212345678', 'abc']) {
        expect(normalizeSaPhone(raw), isNull, reason: '$raw');
      }
    });
  });

  group('PayslipAccessService', () {
    late FakeFirebaseFirestore db;
    late PayslipAccessService service;
    final thabo = Distributor(id: 'd1', name: 'Thabo', index: 0);

    setUp(() async {
      db = FakeFirebaseFirestore();
      service = PayslipAccessService(firestore: db);
      await db.collection('payslipAccounts').doc('acc1').set({
        'name': 'Thabo M',
        'phone': '0821234567',
        'status': 'pending',
        'signupCode': '1234',
        'claimedDistributorId': 'd1',
      });
    });

    Future<Map<String, dynamic>> stored() async =>
        (await db.collection('payslipAccounts').doc('acc1').get()).data()!;

    test('approve links the distributor and stamps the reviewer', () async {
      await service.approve('acc1', thabo, 'admin@clm');
      final data = await stored();
      expect(data['status'], 'approved');
      expect(data['distributorId'], 'd1');
      expect(data['distributorName'], 'Thabo');
      expect(data['reviewedBy'], 'admin@clm');
      expect(data['reviewedAt'], isNotNull);
      // The function's own fields are untouched.
      expect(data['phone'], '0821234567');
      expect(data['signupCode'], '1234');
    });

    test('remove then undo restores access to the same distributor', () async {
      await service.approve('acc1', thabo, 'admin@clm');
      final approved = (await service.streamAccounts().first).single;
      expect(approved.status, PayslipAccountStatus.approved);

      await service.remove('acc1', 'admin@clm');
      expect((await stored())['status'], 'removed');

      await service.restore(approved, 'admin@clm');
      final data = await stored();
      expect(data['status'], 'approved');
      expect(data['distributorId'], 'd1');
    });

    test('reject then undo puts the request back to waiting', () async {
      final pending = (await service.streamAccounts().first).single;
      await service.reject('acc1', 'admin@clm');
      expect((await stored())['status'], 'rejected');
      expect((await stored())['distributorId'], isNull);

      await service.restore(pending, 'admin@clm');
      expect((await stored())['status'], 'pending');
    });

    test('reads the sign-up for the admin list', () async {
      final a = (await service.streamAccounts().first).single;
      expect(a.name, 'Thabo M');
      expect(a.phoneDisplay, '082 123 4567');
      expect(a.signupCode, '1234');
      expect(a.claimedDistributorId, 'd1');
      expect(a.status, PayslipAccountStatus.pending);
    });
  });
}
