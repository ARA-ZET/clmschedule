// One Collection Schedule sync serves both the Collection Schedule tab and
// the main Schedule grid's H/M/N van column (user rule 2026-11-18): the grid
// has no listener of its own, and each month has exactly one listener.
//
// Real CollectionScheduleProvider + JobListService against an in-memory
// Firestore (fake_cloud_firestore).
import 'package:clmschedule/models/collection_job.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/providers/collection_schedule_provider.dart';
import 'package:clmschedule/providers/job_type_provider.dart';
import 'package:clmschedule/providers/schedule_bookings_provider.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:clmschedule/services/job_list_service.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _job(String client, DateTime at,
        {int slots = 2, String type = 'junkCollection'}) =>
    JobListItem(
      id: '',
      invoice: '',
      amount: 0,
      client: client,
      jobStatusId: 'standby',
      jobTypeId: type,
      area: '12 Main Rd, Bellville',
      quantity: 0,
      manDays: 1,
      date: at,
      collectionAddress: '',
      collectionDate: DateTime(2000, 1, 1),
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      timeSlot: '',
      timeSlots: slots,
    );

class _JobTypes extends ChangeNotifier implements JobTypeProvider {
  @override
  bool appearsOnCollectionSchedule(String id) => id == 'junkCollection';
  @override
  String getJobTypeLabel(String id) => 'Junk Collection';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoFirestoreService implements FirestoreService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _settle() async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

int _key(int year, int month) => year * 100 + month;

void main() {
  late FakeFirebaseFirestore db;
  late JobListService service;
  late CollectionScheduleProvider sync;
  // A ProviderContainer that was handed [sync] disposes it itself.
  var disposedElsewhere = false;

  setUp(() {
    disposedElsewhere = false;
    JobTypeProvider.debugInstance = _JobTypes();
    db = FakeFirebaseFirestore();
    service = JobListService(db);
    sync = CollectionScheduleProvider(
      firestoreService: _NoFirestoreService(),
      jobListService: service,
    );
  });

  tearDown(() {
    if (!disposedElsewhere) sync.dispose();
    JobTypeProvider.debugInstance = null;
  });

  test('the grid gets its months from the sync without the tab open', () async {
    await service.addJobListItem(_job('Mrs Smith', DateTime(2026, 12, 3, 9)));
    await service.addJobListItem(
        _job('Flyers Co', DateTime(2026, 12, 3, 9), type: 'flyers'));

    sync.showOnScheduleGrid([DateTime(2026, 12)]);
    await _settle();

    expect(sync.servedMonths, {_key(2026, 12)});
    expect(sync.allCollectionJobs.map((j) => j.clients.single), ['Mrs Smith']);
    expect(sync.allCollectionJobs.single.timeSlot, '09:00');
  });

  test('a month both screens show has one listener, not two', () async {
    await sync.initialize();
    await sync.setCurrentMonth(DateTime(2026, 11));
    sync.showOnScheduleGrid([DateTime(2026, 11), DateTime(2026, 12)]);
    await _settle();

    expect(sync.servedMonths, {_key(2026, 11), _key(2026, 12)});
  });

  test('the tab keeps its own month; the grid adds months alongside', () async {
    await service.addJobListItem(_job('November', DateTime(2026, 11, 20, 10)));
    await service.addJobListItem(_job('December', DateTime(2026, 12, 3, 9)));

    await sync.initialize();
    await sync.setCurrentMonth(DateTime(2026, 11));
    sync.showOnScheduleGrid([DateTime(2026, 12)]);
    await _settle();

    // The tab still works from November only (its date range, loading).
    expect(sync.collectionJobs.map((j) => j.clients.single), ['November']);
    // The grid sees both served months.
    expect(sync.allCollectionJobs.map((j) => j.clients.single).toSet(),
        {'November', 'December'});
  });

  test('switching the tab to a month the grid already shows is instant',
      () async {
    await service.addJobListItem(_job('December', DateTime(2026, 12, 3, 9)));
    await sync.initialize();
    await sync.setCurrentMonth(DateTime(2026, 11));
    sync.showOnScheduleGrid([DateTime(2026, 12)]);
    await _settle();

    await sync.setCurrentMonth(DateTime(2026, 12));
    // No reload: December's data was already here for the grid.
    expect(sync.isLoading, isFalse);
    expect(sync.collectionJobs.map((j) => j.clients.single), ['December']);
    // November is no longer wanted by either screen.
    expect(sync.servedMonths, {_key(2026, 12)});
  });

  test('a month the grid leaves is dropped unless the tab is on it', () async {
    await service.addJobListItem(_job('December', DateTime(2026, 12, 3, 9)));
    await sync.initialize();
    await sync.setCurrentMonth(DateTime(2026, 11));
    sync.showOnScheduleGrid([DateTime(2026, 11), DateTime(2026, 12)]);
    await _settle();
    expect(sync.allCollectionJobs, hasLength(1));

    sync.showOnScheduleGrid(const []);
    await _settle();
    expect(sync.servedMonths, {_key(2026, 11)}); // the tab's month stays
    expect(sync.allCollectionJobs, isEmpty); // December's jobs went with it
  });

  test('a booking edited on the Job List reaches the grid live', () async {
    final id = await service
        .addJobListItem(_job('Mrs Smith', DateTime(2026, 12, 3, 9)));
    sync.showOnScheduleGrid([DateTime(2026, 12)]);
    await _settle();
    expect(sync.allCollectionJobs.single.timeSlot, '09:00');

    final item = (await service.getJobListItemById(id, DateTime(2026, 12)))!;
    await service.updateJobListItem(
        item.withAppointment(DateTime(2026, 12, 3, 13),
            slots: 3, onCollectionSchedule: true),
        item.date);
    await _settle();

    final job = sync.allCollectionJobs.single;
    expect((job.timeSlot, job.timeSlots), ('13:00', 3));
  });

  test("the grid's day bookings come from the same sync", () async {
    await service.addJobListItem(_job('Mrs Smith', DateTime(2026, 12, 3, 9)));
    await service.addJobListItem(_job('Mr Jones', DateTime(2026, 12, 4, 11)));
    sync.showOnScheduleGrid([DateTime(2026, 12)]);
    await _settle();

    final container = ProviderContainer(overrides: [
      collectionScheduleRiverpod.overrideWith((ref) => sync),
    ]);
    disposedElsewhere = true;
    addTearDown(container.dispose);

    final day = container.read(dayBookingsRiverpod(DateTime(2026, 12, 3)));
    expect(day.bookings.map((b) => b.clients.single), ['Mrs Smith']);
    expect(day.forVehicle(VehicleType.hyundai), hasLength(1));
    expect(container.read(dayBookingsRiverpod(DateTime(2026, 12, 5))).isEmpty,
        isTrue);
  });
}
