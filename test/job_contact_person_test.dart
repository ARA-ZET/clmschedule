// A Job List job's contact person and phone: typed on the Add/Edit Job
// form beside the client (no Job List column), and used for the dropsheet's
// Contact and Tel — Junk & Stuff and Happy Sun drivers ring them on the day.
import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/providers/auth_provider.dart';
import 'package:clmschedule/providers/dropsheet_provider.dart';
import 'package:clmschedule/providers/job_list_provider.dart';
import 'package:clmschedule/providers/job_type_provider.dart';
import 'package:clmschedule/services/job_list_service.dart';
import 'package:clmschedule/services/job_list_undo.dart';
import 'package:clmschedule/utils/job_list_search.dart';
import 'package:firebase_auth/firebase_auth.dart' show User;
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _job({
  String client = 'Mrs Smith',
  String contactPerson = '',
  String contactPhone = '',
}) =>
    JobListItem(
      id: 'jl-1',
      invoice: '',
      amount: 0,
      client: client,
      contactPerson: contactPerson,
      contactPhone: contactPhone,
      jobStatusId: 'standby',
      jobTypeId: 'junkCollection',
      area: '12 Main Rd, Bellville',
      quantity: 0,
      manDays: 1,
      date: DateTime(2026, 11, 20),
      collectionAddress: '',
      collectionDate: DateTime(2000, 1, 1),
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    );

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
  group('stored on the job', () {
    test('older jobs read as blank', () {
      final old = _job().toMap()
        ..remove('contactPerson')
        ..remove('contactPhone');
      final read = JobListItem.fromMap('jl-1', old);
      expect(read.contactPerson, '');
      expect(read.contactPhone, '');
    });

    test('always written, so clearing them reaches the server', () {
      final blank = _job().toMap();
      expect(blank['contactPerson'], '');
      expect(blank['contactPhone'], '');

      final map =
          _job(contactPerson: 'John', contactPhone: '082 123 4567').toMap();
      final read = JobListItem.fromMap('jl-1', map);
      expect(read.contactPerson, 'John');
      expect(read.contactPhone, '082 123 4567');
    });

    test('a change is in the job history', () {
      final changed = _job().copyWithTrackedChange(
        userId: 'u1',
        userDisplayName: 'Barrie',
        contactPerson: 'John',
        contactPhone: '082 123 4567',
      );
      expect(changed.contactPerson, 'John');
      expect(changed.contactPhone, '082 123 4567');
      expect(changed.updates.map((u) => u.fieldName),
          ['contactPerson', 'contactPhone']);
    });

    test('undo puts them back', () {
      final before = _job();
      final after = _job(contactPerson: 'John', contactPhone: '0821234567');
      final keys = changedJobListFields(before, after);
      expect(keys, ['contactPerson', 'contactPhone']);
      final undone = copyJobListFields(after, before, keys);
      expect(undone.contactPerson, '');
      expect(undone.contactPhone, '');
      expect(describeJobListEdit(after, keys),
          'Mrs Smith: change contact person, contact phone');
    });
  });

  group('who the driver rings', () {
    test('the contact person and phone when filled in', () {
      final c = _job(
        client: 'Smith Family Trust',
        contactPerson: 'John (son)',
        contactPhone: '082 123 4567',
      ).siteContact;
      expect(c.contact, 'John (son)');
      expect(c.tel, '082 123 4567');
    });

    test('else the client, with a number typed on its end split off', () {
      final c = _job(client: 'Mrs Smith 082 123 4567').siteContact;
      expect(c.contact, 'Mrs Smith');
      expect(c.tel, '082 123 4567');
      expect(_job().siteContact, (contact: 'Mrs Smith', tel: ''));
    });

    test('a phone without a person still names the client', () {
      final c = _job(contactPhone: '021 555 1234').siteContact;
      expect(c.contact, 'Mrs Smith');
      expect(c.tel, '021 555 1234');
    });

    test('a number too short to dial is caught; blank is fine', () {
      expect(JobListItem.contactPhoneProblem(''), isNull);
      expect(JobListItem.contactPhoneProblem(null), isNull);
      expect(JobListItem.contactPhoneProblem('082 123 4567'), isNull);
      expect(JobListItem.contactPhoneProblem('+27 82 123 4567'), isNull);
      expect(JobListItem.contactPhoneProblem('082 123'), isNotNull);
    });
  });

  group('on the dropsheet', () {
    final jtp = _JobTypes();

    test('Contact and Tel come from the job\'s contact', () {
      final task = DropsheetProvider.buildJobListTaskForTest(
        _job(contactPerson: 'John', contactPhone: '082 123 4567'),
        jtp,
      );
      expect(task.contact, 'John');
      expect(task.tel, '082 123 4567');
      expect(task.job, 'Collection: Mrs Smith',
          reason: 'the label still names the client');
    });

    test('a task built before the contact was filled in is rebuilt', () {
      final before = DropsheetProvider.buildJobListTaskForTest(_job(), jtp);
      expect(before.contact, 'Mrs Smith');
      expect(before.tel, '');

      final edited = _job(contactPerson: 'John', contactPhone: '0821234567');
      expect(DropsheetProvider.contactUpToDateForTest(before, edited), isFalse);

      final rebuilt = DropsheetProvider.buildJobListTaskForTest(edited, jtp,
          existingTask: before);
      expect(rebuilt.contact, 'John');
      expect(rebuilt.tel, '0821234567');
      expect(DropsheetProvider.contactUpToDateForTest(rebuilt, edited), isTrue);
    });

    test('an unchanged job is left alone', () {
      final job = _job(client: 'Mrs Smith 082 123 4567');
      final task = DropsheetProvider.buildJobListTaskForTest(job, jtp);
      expect(DropsheetProvider.contactUpToDateForTest(task, job), isTrue);
    });

    test('a contact typed on the dropsheet itself is kept', () {
      final built = DropsheetProvider.buildJobListTaskForTest(_job(), jtp);
      final reworded = built.copyWith(
        contact: 'Gate guard',
        tel: '079 000 0000',
        typeData: {
          ...built.typeData,
          DropsheetTask.kUserEditedKey: true,
        },
      );
      final job = _job(contactPerson: 'John', contactPhone: '0821234567');
      expect(DropsheetProvider.contactUpToDateForTest(reworded, job), isTrue);
      final rebuilt = DropsheetProvider.buildJobListTaskForTest(job, jtp,
          existingTask: reworded);
      expect(rebuilt.contact, 'Gate guard');
      expect(rebuilt.tel, '079 000 0000');
    });
  });

  test('a contact-only edit is saved', () async {
    final service = _FakeJobListService();
    final provider = JobListProvider(service, _FakeAuth());
    final job = _job();

    await provider.updateJobListItemWithTracking(
        job, job.copyWith(specialInstructions: 'Gate code 1234'));
    final first = provider.getJobListItemById('jl-1')!;

    await provider.updateJobListItemWithTracking(first,
        first.copyWith(contactPerson: 'John', contactPhone: '082 123 4567'));
    final edited = provider.getJobListItemById('jl-1')!;
    expect(edited.contactPerson, 'John');
    expect(edited.contactPhone, '082 123 4567');

    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(service.saved.last.contactPerson, 'John');
    expect(service.saved.last.contactPhone, '082 123 4567');
  });

  test('the Job List search finds a job by its contact or number', () {
    final job = _job(contactPerson: 'John Petersen', contactPhone: '082 123 4567');
    expect(JobListSearch('petersen').matches(job), isTrue);
    expect(JobListSearch('082 123 4567').matches(job), isTrue);
    expect(JobListSearch('0821234567').matches(job), isTrue);
  });
}
