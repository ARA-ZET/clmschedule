// Appointment time slots (Junk & Stuff and Happy Sun jobs): a From–To in
// the Collection Schedule's half-hour rows, saved on the Job List job as
// timeSlot + timeSlots. The Collection Schedule reads those before the
// job's date, so every edit has to keep them — and a collection day set by
// dragging there — in step, or the booking never moves.
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/providers/auth_provider.dart';
import 'package:clmschedule/providers/job_list_provider.dart';
import 'package:clmschedule/services/job_list_service.dart';
import 'package:clmschedule/utils/appointment_slots.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter_test/flutter_test.dart';

final _sentinel = DateTime(2000, 1, 1);

JobListItem _job({
  DateTime? date,
  DateTime? collectionDate,
  String timeSlot = '',
  int timeSlots = 0,
}) {
  final d = date ?? DateTime(2026, 11, 20, 10);
  return JobListItem(
    id: 'jl-1',
    invoice: '',
    amount: 0,
    client: 'Mrs Smith',
    jobStatusId: 'standby',
    jobTypeId: 'junkCollection',
    area: 'Bellville',
    quantity: 0,
    manDays: 1,
    date: d,
    collectionAddress: '1 Main Rd',
    collectionDate: collectionDate ?? _sentinel,
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: '',
    reportAddresses: '',
    whoToInvoice: '',
    timeSlot: timeSlot,
    timeSlots: timeSlots,
  );
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

class _FakeJobListService implements JobListService {
  final saved = <JobListItem>[];
  @override
  String getMonthlyDocumentId(DateTime date) => '${date.year}-${date.month}';
  @override
  Future<void> updateJobListItem(JobListItem jobListItem,
      [DateTime? date]) async {
    saved.add(jobListItem);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('slot helper', () {
    test('starts are the Collection Schedule rows, 07:30 to 20:00', () {
      final starts = appointmentStartTimes();
      expect(starts.first, '07:30');
      expect(starts.last, '20:00');
      expect(starts, hasLength(26));
      expect(starts, contains('12:30'));
    });

    test('ranges, ends and lengths', () {
      expect(slotEnd('10:00', 3), '11:30');
      expect(slotRange('10:00', 3), '10:00–11:30');
      expect(slotLength(1), '30 min');
      expect(slotLength(2), '1 h');
      expect(slotLength(3), '1 h 30');
    });

    test('a booking can run to 20:30 at the latest', () {
      expect(slotLengthOptions('19:00'), [1, 2, 3]);
      expect(slotLengthOptions('20:00'), [1]);
      expect(slotLengthOptions('07:30').last, 26);
    });

    test('overlap', () {
      expect(slotsOverlap('10:00', 2, '10:30', 1), isTrue);
      expect(slotsOverlap('10:00', 2, '11:00', 1), isFalse,
          reason: 'back to back is fine');
      expect(slotsOverlap('10:00', 1, '09:30', 1), isFalse);
      expect(slotsOverlap('10:00', 1, 'not a time', 4), isFalse);
    });
  });

  group('withAppointment', () {
    test('a new booking sets the start, the length and the date', () {
      final booked = _job(date: DateTime(2026, 11, 20)).withAppointment(
        DateTime(2026, 11, 20, 14),
        slots: 3,
        onCollectionSchedule: true,
      );
      expect(booked.date, DateTime(2026, 11, 20, 14));
      expect(booked.timeSlot, '14:00');
      expect(booked.timeSlots, 3);
      expect(booked.resolvedTimeSlot, '14:00');
      expect(booked.timeSlotRangeDisplay, '14:00–15:30');
      expect(booked.collectionDate, _sentinel,
          reason: 'never dragged on the Collection Schedule: date is the day');
    });

    test('a later time wins over the time the schedule saved', () {
      // Booked for 09:00, with the Collection Schedule's day set to the 21st
      // (the Job List's Collection Date cell).
      final dragged = _job(
        date: DateTime(2026, 11, 20, 9),
        collectionDate: DateTime(2026, 11, 21, 9),
        timeSlot: '09:00',
        timeSlots: 2,
      );
      expect(dragged.resolvedTimeSlot, '09:00');

      // Only the time changed in Add/Edit Job: the schedule's day stays.
      final retimed = dragged.withAppointment(
        DateTime(2026, 11, 20, 13, 30),
        slots: 2,
        onCollectionSchedule: true,
        moveCollectionDay: false,
      );
      expect(retimed.resolvedTimeSlot, '13:30');
      expect(retimed.collectionDate, DateTime(2026, 11, 21, 13, 30));
    });

    test('a new day moves the booking on the Collection Schedule too', () {
      final dragged = _job(
        collectionDate: DateTime(2026, 11, 21, 9),
        timeSlot: '09:00',
        timeSlots: 2,
      );
      final moved = dragged.withAppointment(
        DateTime(2026, 11, 25, 9),
        onCollectionSchedule: true,
      );
      expect(moved.collectionDate, DateTime(2026, 11, 25, 9));
      expect(moved.timeSlots, 2, reason: 'length unchanged when not given');
    });

    test('a Happy Sun collection date is the user\'s own: left alone', () {
      final job = _job(collectionDate: DateTime(2026, 11, 22, 8));
      final booked = job.withAppointment(
        DateTime(2026, 11, 20, 11),
        slots: 4,
        onCollectionSchedule: false,
      );
      expect(booked.collectionDate, DateTime(2026, 11, 22, 8));
      expect(booked.timeSlotRangeDisplay, '11:00–13:00');
    });

    test('midnight books no time: only the day moves', () {
      final job = _job(timeSlot: '10:00', timeSlots: 2);
      final moved = job.withAppointment(DateTime(2026, 11, 24),
          onCollectionSchedule: true);
      expect(moved.timeSlot, '10:00');
      expect(moved.date, DateTime(2026, 11, 24));
    });
  });

  test('a time slot change is one history line, From–To', () {
    final job = _job(timeSlot: '10:00', timeSlots: 2);
    // As every save sends it: the new start on the date and in the slot.
    final changed = job.copyWithTrackedChange(
      userId: 'u1',
      userDisplayName: 'Barrie',
      date: DateTime(2026, 11, 20, 14),
      timeSlot: '14:00',
      timeSlots: 3,
    );
    expect(changed.timeSlot, '14:00');
    expect(changed.timeSlots, 3);
    final line =
        changed.updates.singleWhere((u) => u.fieldName == 'timeSlot');
    expect(line.fieldName, 'timeSlot');
    expect(line.oldValueDisplay, '10:00–11:00');
    expect(line.newValueDisplay, '14:00–15:30');
  });

  group('saving an edit', () {
    // These went through as "no changes" before: the edit check compared
    // neither the time slot nor the flyer tick, so they never saved.
    test('a time slot change is saved', () async {
      final service = _FakeJobListService();
      final provider = JobListProvider(service, _FakeAuth());
      final job = _job(timeSlot: '10:00', timeSlots: 2);

      await provider.updateJobListItemWithTracking(
          job, job.copyWith(specialInstructions: 'Gate code 1234'));
      final first = provider.getJobListItemById('jl-1')!;

      await provider.updateJobListItemWithTracking(
          first, first.copyWith(timeSlot: '14:00', timeSlots: 3));
      final edited = provider.getJobListItemById('jl-1')!;
      expect(edited.timeSlot, '14:00');
      expect(edited.timeSlots, 3);

      await Future<void>.delayed(const Duration(milliseconds: 700));
      expect(service.saved.last.timeSlot, '14:00');
    });

    test('a flyer tick on its own is saved', () async {
      final service = _FakeJobListService();
      final provider = JobListProvider(service, _FakeAuth());
      final job = _job();

      await provider.updateJobListItemWithTracking(
          job, job.copyWith(specialInstructions: 'x'));
      final first = provider.getJobListItemById('jl-1')!;
      await provider.updateJobListItemWithTracking(
          first, first.copyWith(needsFlyerCollection: true));
      expect(provider.getJobListItemById('jl-1')!.needsFlyerCollection, isTrue);
    });
  });
}
