// The Staff screen stages every edit and commits them in one batch. These
// round trip the real FirestoreService into an in-memory Firestore and read
// the stored documents back, so a change that never reaches the database
// (an added staff member, a cleared phone number) fails here.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';

Distributor _d(
  String id,
  String name,
  int index, {
  String? phone1,
  DistributorStatus status = DistributorStatus.active,
}) =>
    Distributor(
      id: id,
      name: name,
      index: index,
      phone1: phone1,
      status: status,
    );

Future<Map<String, dynamic>?> _stored(
    FakeFirebaseFirestore db, String id) async {
  final snap = await db.collection('distributors').doc(id).get();
  return snap.data();
}

void main() {
  group('batchSaveDistributors', () {
    // Deletes aren't exercised here: the Recycle Bin entry they write stamps
    // the signed-in user through FirebaseAuth.instance, which needs a real
    // Firebase app. That path is unchanged by the Staff screen.
    test('creates and updates in a single commit', () async {
      final db = FakeFirebaseFirestore();
      final service = FirestoreService(firestore: db);

      // Two already on the roster.
      await db
          .collection('distributors')
          .doc('barrie')
          .set(_d('barrie', 'Barrie', 0, phone1: '0821112222').toMap());
      await db
          .collection('distributors')
          .doc('sipho')
          .set(_d('sipho', 'Sipho', 1).toMap());

      // The screen's minted id for somebody being added.
      final newId = service.newDistributorId();
      expect(newId, isNotEmpty);

      await service.batchSaveDistributors(
        toCreate: [_d(newId, 'Thandi', 1, phone1: '0730000000')],
        toUpdate: [
          _d('barrie', 'Barrie B', 0), // phone1 cleared
          _d('sipho', 'Sipho', 2, status: DistributorStatus.inactive),
        ],
        toDelete: const {},
      );

      final created = await _stored(db, newId);
      expect(created, isNotNull, reason: 'the added staff member must be written');
      expect(created!['name'], 'Thandi');
      expect(created['index'], 1);
      expect(created['phone1'], '0730000000');
      expect(created['status'], 'active');

      final updated = await _stored(db, 'barrie');
      expect(updated!['name'], 'Barrie B');
      expect(updated['phone1'], isNull,
          reason: 'clearing a phone number must reach the database');

      // Going inactive drops somebody to the end of the roster.
      final moved = await _stored(db, 'sipho');
      expect(moved!['status'], 'inactive');
      expect(moved['index'], 2);
    });

    test('a create with no other edits still commits', () async {
      final db = FakeFirebaseFirestore();
      final service = FirestoreService(firestore: db);

      final id = service.newDistributorId();
      await service.batchSaveDistributors(
        toCreate: [_d(id, 'Nomsa', 0)],
        toUpdate: const [],
        toDelete: const {},
      );

      expect((await _stored(db, id))!['name'], 'Nomsa');
    });

    test('an empty save is a no-op', () async {
      final db = FakeFirebaseFirestore();
      final service = FirestoreService(firestore: db);

      await service.batchSaveDistributors(
        toCreate: const [],
        toUpdate: const [],
        toDelete: const {},
      );

      expect((await db.collection('distributors').get()).docs, isEmpty);
    });
  });

  group('Distributor.copyWith clear flags', () {
    test('clears phone numbers, which the Staff editor relies on', () {
      final d = _d('a', 'A', 0, phone1: '0821112222')
          .copyWith(phone2: '0730000000');
      expect(d.phone1, '0821112222');
      expect(d.phone2, '0730000000');

      final cleared = d.copyWith(clearPhone1: true, clearPhone2: true);
      expect(cleared.phone1, isNull);
      expect(cleared.phone2, isNull);
      expect(cleared.toMap()['phone1'], isNull);
    });
  });
}
