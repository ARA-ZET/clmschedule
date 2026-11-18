// Round trips through the real JobListService (and the providers that use
// it) into an in-memory Firestore, then reads the stored document back:
//
//  * the new fields — needsFlyerCollection, timeSlot/timeSlots,
//    contactPerson/contactPhone — reach the database on add and on edit, and
//    clearing one reaches it too;
//  * they survive a month move and an edit from an older app version that
//    does not know them;
//  * documents in the old shape (time on `date`, no slot, no contact) still
//    read the same, and the dropsheet and Collection Schedule read the same
//    booking from both shapes.
import 'package:clmschedule/models/collection_job.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/providers/auth_provider.dart';
import 'package:clmschedule/providers/collection_schedule_provider.dart';
import 'package:clmschedule/providers/dropsheet_provider.dart';
import 'package:clmschedule/providers/job_list_provider.dart';
import 'package:clmschedule/providers/job_type_provider.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:clmschedule/services/job_list_service.dart';
import 'package:clmschedule/utils/schedule_time.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

const _month = 'Nov 2026';

JobListItem _job({
  String id = '',
  DateTime? date,
  String timeSlot = '',
  int timeSlots = 0,
  bool needsFlyerCollection = false,
  String contactPerson = '',
  String contactPhone = '',
}) =>
    JobListItem(
      id: id,
      invoice: '',
      amount: 0,
      client: 'Mrs Smith',
      contactPerson: contactPerson,
      contactPhone: contactPhone,
      jobStatusId: 'standby',
      jobTypeId: 'junkCollection',
      area: '12 Main Rd, Bellville',
      quantity: 0,
      manDays: 1,
      date: date ?? DateTime(2026, 11, 20, 10),
      collectionAddress: '',
      collectionDate: DateTime(2000, 1, 1),
      needsFlyerCollection: needsFlyerCollection,
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      timeSlot: timeSlot,
      timeSlots: timeSlots,
    );

/// The document as stored, by month and id.
Future<Map<String, dynamic>> _stored(FakeFirebaseFirestore db, String id,
    {String month = _month}) async {
  final snap = await db
      .collection('jobLists')
      .doc(month)
      .collection('items')
      .doc(id)
      .get();
  expect(snap.exists, isTrue, reason: 'jobLists/$month/items/$id');
  return snap.data()!;
}

DateTime _civil(Object? ts) => toScheduleCivil((ts as Timestamp).toDate());

class _JobTypes extends ChangeNotifier implements JobTypeProvider {
  @override
  String getJobTypeLabel(String id) => 'Junk Collection';
  @override
  bool hasTwoStops(String id) => false;
  @override
  String? dropsheetTaskTypeKey(String id) => 'collection';
  @override
  bool needsTimeSlot(String id) => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeUser implements User {
  @override
  String get uid => 'u1';
  @override
  String? get email => 'barrie@example.com';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuth implements AuthProvider {
  @override
  User? get user => _FakeUser();
  @override
  get appUser => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoFirestoreService implements FirestoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late FakeFirebaseFirestore db;
  late JobListService service;

  setUp(() {
    db = FakeFirebaseFirestore();
    service = JobListService(db);
  });

  group('adding a job', () {
    test('Add Job saves every new field', () async {
      final provider = JobListProvider(service, _FakeAuth());
      // As Add/Edit Job builds it: a 10:00–11:30 booking, a contact, a tick.
      final built = _job(
        date: DateTime(2026, 11, 20),
        needsFlyerCollection: true,
        contactPerson: 'John',
        contactPhone: '082 123 4567',
      ).withAppointment(DateTime(2026, 11, 20, 10),
          slots: 3, onCollectionSchedule: true);

      final added = provider.addJobListItemLocal(built);
      await added.saved;

      final doc = await _stored(db, added.job.id);
      expect(doc['timeSlot'], '10:00');
      expect(doc['timeSlots'], 3);
      expect(_civil(doc['date']), DateTime(2026, 11, 20, 10));
      expect(doc['needsFlyerCollection'], isTrue);
      expect(doc['contactPerson'], 'John');
      expect(doc['contactPhone'], '082 123 4567');
    });

    test('a job without them still writes the contact and tick keys',
        () async {
      final id = service.newJobListItemId(DateTime(2026, 11, 20));
      await service.setNewJobListItem(id, _job(date: DateTime(2026, 11, 20)));
      final doc = await _stored(db, id);
      expect(doc['contactPerson'], '');
      expect(doc['contactPhone'], '');
      expect(doc['needsFlyerCollection'], isFalse);
      expect(doc.containsKey('timeSlot'), isFalse,
          reason: 'no booking, no slot key — same as before');
    });

    test('Add Job on the Collection Schedule puts the start on the date too',
        () async {
      final schedule = CollectionScheduleProvider(
        firestoreService: _NoFirestoreService(),
        jobListService: service,
      );
      final id = await schedule.addCollectionJob(
        CollectionJob(
          id: '',
          location: '12 Main Rd',
          vehicleType: VehicleType.hyundai,
          trailerType: TrailerType.noTrailer,
          date: DateTime(2026, 11, 20),
          timeSlot: '13:30',
          timeSlots: 2,
          assignedStaff: const [],
          staffCount: 1,
          jobType: 'junkCollection',
          statusId: 'scheduled',
          clients: const [],
        ),
        jobTypeId: 'junkCollection',
      );

      final doc = await _stored(db, id);
      expect(doc['timeSlot'], '13:30');
      expect(doc['timeSlots'], 2);
      expect(_civil(doc['date']), DateTime(2026, 11, 20, 13, 30),
          reason: 'it used to stay at midnight, so the dropsheet and older '
              'versions saw no time');
      expect(_civil(doc['collectionDate']), DateTime(2026, 11, 20, 13, 30));
    });
  });

  group('editing a job', () {
    Future<(JobListProvider, JobListItem)> seeded(JobListItem job) async {
      final id = service.newJobListItemId(job.date);
      final stored = job.copyWith(id: id);
      await service.setNewJobListItem(id, stored);
      return (JobListProvider(service, _FakeAuth()), stored);
    }

    // The Job List debounces saves by 500 ms.
    Future<void> saved() =>
        Future<void>.delayed(const Duration(milliseconds: 700));

    test('a new time slot, contact and tick reach the database', () async {
      final (provider, job) =
          await seeded(_job(timeSlot: '10:00', timeSlots: 2));

      final edited = job
          .copyWith(
            needsFlyerCollection: true,
            contactPerson: 'John',
            contactPhone: '082 123 4567',
          )
          .withAppointment(DateTime(2026, 11, 21, 14),
              slots: 3, onCollectionSchedule: true);
      await provider.updateJobListItemWithTracking(job, edited);
      await saved();

      final doc = await _stored(db, job.id);
      expect(doc['timeSlot'], '14:00');
      expect(doc['timeSlots'], 3);
      expect(_civil(doc['date']), DateTime(2026, 11, 21, 14));
      expect(doc['needsFlyerCollection'], isTrue);
      expect(doc['contactPerson'], 'John');
      expect(doc['contactPhone'], '082 123 4567');
      expect(
          (doc['updates'] as List).map((u) => (u as Map)['fieldName']),
          containsAll(
              ['timeSlot', 'needsFlyerCollection', 'contactPerson']));
    });

    test('clearing the contact and unticking reach the database', () async {
      final (provider, job) = await seeded(_job(
        needsFlyerCollection: true,
        contactPerson: 'John',
        contactPhone: '082 123 4567',
      ));
      await provider.updateJobListItemWithTracking(
          job,
          job.copyWith(
              needsFlyerCollection: false,
              contactPerson: '',
              contactPhone: ''));
      await saved();

      final doc = await _stored(db, job.id);
      expect(doc['needsFlyerCollection'], isFalse);
      expect(doc['contactPerson'], '');
      expect(doc['contactPhone'], '');
    });

    test('an edit from an older app version keeps the new fields', () async {
      final (_, job) = await seeded(_job(
        timeSlot: '10:00',
        timeSlots: 3,
        needsFlyerCollection: true,
        contactPerson: 'John',
        contactPhone: '082 123 4567',
      ));
      // An older version's save: the whole job, minus the keys it has never
      // heard of, through the same update().
      final olderSave = job.copyWith(specialInstructions: 'Gate code').toMap()
        ..remove('storageFolderPath')
        ..remove('contactPerson')
        ..remove('contactPhone')
        ..remove('needsFlyerCollection');
      await db
          .collection('jobLists')
          .doc(_month)
          .collection('items')
          .doc(job.id)
          .update(olderSave);

      final doc = await _stored(db, job.id);
      expect(doc['specialInstructions'], 'Gate code');
      expect(doc['contactPerson'], 'John');
      expect(doc['contactPhone'], '082 123 4567');
      expect(doc['needsFlyerCollection'], isTrue);
      expect(doc['timeSlot'], '10:00');
    });

    test('moving to another month keeps them', () async {
      final (_, job) = await seeded(_job(
        timeSlot: '10:00',
        timeSlots: 3,
        needsFlyerCollection: true,
        contactPerson: 'John',
        contactPhone: '082 123 4567',
      ));
      final moved = job.withAppointment(DateTime(2026, 12, 3, 10),
          onCollectionSchedule: true);
      await service.moveJobListItemToMonth(moved, job.date, moved.date);

      final doc = await _stored(db, job.id, month: 'Dec 2026');
      expect(_civil(doc['date']), DateTime(2026, 12, 3, 10));
      expect(doc['timeSlot'], '10:00');
      expect(doc['timeSlots'], 3);
      expect(doc['needsFlyerCollection'], isTrue);
      expect(doc['contactPerson'], 'John');
      expect(doc['contactPhone'], '082 123 4567');
      final old = await db
          .collection('jobLists')
          .doc(_month)
          .collection('items')
          .doc(job.id)
          .get();
      expect(old.exists, isFalse);
    });

    test('a month move by an older app version keeps them too', () async {
      final (_, job) = await seeded(_job(
        timeSlot: '10:00',
        timeSlots: 3,
        contactPerson: 'John',
        contactPhone: '082 123 4567',
      ));
      // The committed (older) moveJobListItemToMonth: the stored document,
      // then that version's toMap — which has no contact or tick keys — on
      // top, set in the new month, deleted from the old.
      final olderToMap = job.copyWith(date: DateTime(2026, 12, 3, 10)).toMap()
        ..remove('storageFolderPath')
        ..remove('contactPerson')
        ..remove('contactPhone')
        ..remove('needsFlyerCollection');
      final oldRef =
          db.collection('jobLists').doc(_month).collection('items').doc(job.id);
      final newRef = db
          .collection('jobLists')
          .doc('Dec 2026')
          .collection('items')
          .doc(job.id);
      await db.runTransaction((txn) async {
        final stored = (await txn.get(oldRef)).data()!;
        txn.set(newRef, {...stored, ...olderToMap});
        txn.delete(oldRef);
      });

      final doc = await _stored(db, job.id, month: 'Dec 2026');
      expect(doc['timeSlot'], '10:00');
      expect(doc['timeSlots'], 3);
      expect(doc['contactPerson'], 'John');
      expect(doc['contactPhone'], '082 123 4567');
    });
  });

  group('documents in the old shape', () {
    // Before the slot had its own field: the time lived on `date` and the
    // length on quantityDistributed; no contact, no tick.
    Future<String> storeOld(Map<String, dynamic> overrides) async {
      final map = _job().toMap()
        ..remove('timeSlot')
        ..remove('timeSlots')
        ..remove('contactPerson')
        ..remove('contactPhone')
        ..remove('needsFlyerCollection')
        ..addAll(overrides);
      final ref =
          db.collection('jobLists').doc(_month).collection('items').doc();
      await ref.set(map);
      return ref.id;
    }

    test('read with the right defaults and the same booking', () async {
      final id = await storeOld({
        'client': 'Mrs Smith 082 123 4567',
        'date': Timestamp.fromDate(
            scheduleCivilToInstant(DateTime(2026, 11, 20, 9, 30))),
        'quantityDistributed': 4,
      });
      final job = (await service.getJobListItemById(id, DateTime(2026, 11)))!;

      expect(job.needsFlyerCollection, isFalse);
      expect(job.contactPerson, '');
      expect(job.timeSlot, '');
      expect(job.resolvedTimeSlot, '09:30');
      expect(job.resolvedTimeSlots, 4);
      expect(job.timeSlotRangeDisplay, '09:30–11:30');

      // The dropsheet rings the number typed on the client's name.
      expect(job.siteContact, (contact: 'Mrs Smith', tel: '082 123 4567'));
      expect(DropsheetProvider.appointmentTimeForTest(job, _JobTypes()),
          '09:30');
    });

    test('an edit in this version adds the new keys and keeps the old ones',
        () async {
      final id = await storeOld({
        'date': Timestamp.fromDate(
            scheduleCivilToInstant(DateTime(2026, 11, 20, 9, 30))),
      });
      final job = (await service.getJobListItemById(id, DateTime(2026, 11)))!;
      final provider = JobListProvider(service, _FakeAuth());
      await provider.updateJobListItemWithTracking(
          job, job.copyWith(contactPerson: 'John'));
      await Future<void>.delayed(const Duration(milliseconds: 700));

      final doc = await _stored(db, id);
      expect(doc['contactPerson'], 'John');
      expect(_civil(doc['date']), DateTime(2026, 11, 20, 9, 30));
      final reread = JobListItem.fromMap(id, doc);
      expect(reread.resolvedTimeSlot, '09:30');
    });
  });

  group('one booking, read the same everywhere', () {
    final jtp = _JobTypes();

    test('added on the Collection Schedule before this fix (midnight date)',
        () {
      final job = _job(
          date: DateTime(2026, 11, 20), timeSlot: '13:30', timeSlots: 2);
      expect(job.resolvedTimeSlot, '13:30');
      expect(DropsheetProvider.appointmentTimeForTest(job, jtp), '13:30',
          reason: 'the dropsheet used to show no time for these');
    });

    test('re-timed in an older Add/Edit Job, which left the slot behind', () {
      final job = _job(
          date: DateTime(2026, 11, 20, 15), timeSlot: '13:30', timeSlots: 2);
      expect(job.resolvedTimeSlot, '15:00',
          reason: 'the time the user typed last wins');
      expect(DropsheetProvider.appointmentTimeForTest(job, jtp), '15:00');
    });

    test('no time booked', () {
      final job = _job(date: DateTime(2026, 11, 20));
      expect(job.resolvedTimeSlot, '00:00');
      expect(job.timeSlotRangeDisplay, '');
      expect(DropsheetProvider.appointmentTimeForTest(job, jtp), '');
    });

    test('a collection date on the 1st or in January counts', () {
      expect(_job().hasCollectionDate, isFalse);
      expect(
          _job().copyWith(collectionDate: DateTime(2026, 12, 1)).hasCollectionDate,
          isTrue);
      expect(
          _job().copyWith(collectionDate: DateTime(2027, 1, 15)).hasCollectionDate,
          isTrue);
    });
  });
}
