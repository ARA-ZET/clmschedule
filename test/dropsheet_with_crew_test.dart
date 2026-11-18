// Junk & Stuff / Happy Sun jobs on the dropsheet say who works them
// ("Team: Sipho, Thabo" in Details), and every field edited — on the Job List
// or in the task editor — reaches the sheet.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/dropsheet_day.dart';
import 'package:clmschedule/models/dropsheet_task.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/providers/dropsheet_provider.dart';
import 'package:clmschedule/providers/job_type_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

final _date = DateTime(2026, 11, 20);

final _thabo = Distributor(id: 'dThabo', name: 'Thabo', index: 2);
final _sipho = Distributor(id: 'dSipho', name: 'Sipho', index: 1);
final _petros = Distributor(
    id: 'dPetros', name: 'Petros', index: 3, role: DistributorRole.driver);
final _dists = [_thabo, _sipho, _petros];

Job _job(String id, String distributorId, List<String> clients) => Job(
      id: id,
      clients: clients,
      workingAreas: const ['12 Main Rd'],
      workMaps: const [],
      distributorId: distributorId,
      date: _date,
      statusId: 'scheduled',
    );

JobListItem _item({
  String jobTypeId = 'junkCollection',
  String client = 'Mrs Smith',
  String area = '12 Main Rd, Bellville',
  String specialInstructions = '',
  String offloadingAddress = '',
}) =>
    JobListItem(
      id: 'jl-1',
      invoice: '',
      amount: 0,
      client: client,
      jobStatusId: 'standby',
      jobTypeId: jobTypeId,
      area: area,
      quantity: 0,
      manDays: 1,
      date: _date,
      collectionAddress: '',
      collectionDate: DateTime(2000, 1, 1),
      specialInstructions: specialInstructions,
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      offloadingAddress: offloadingAddress,
    );

class _JobTypes extends ChangeNotifier implements JobTypeProvider {
  _JobTypes({this.twoStop = false});
  final bool twoStop;
  @override
  String getJobTypeLabel(String id) =>
      twoStop ? 'Furniture Move' : 'Junk Collection';
  @override
  bool hasTwoStops(String id) => twoStop;
  @override
  String? dropsheetTaskTypeKey(String id) =>
      twoStop ? 'furnitureMove' : 'collection';
  @override
  bool needsTimeSlot(String id) => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A synced Junk & Stuff task for [client] (typeData as the sync writes it).
DropsheetTask _jsTask({
  String client = 'Mrs Smith',
  String jobType = 'junkCollection',
  String details = '',
  Map<String, dynamic> extra = const {},
}) =>
    DropsheetTask(
      id: 't_jl_1',
      type: DropsheetTaskType.collection,
      job: 'Collection: $client',
      details: details,
      sourceJobListItemId: 'jl-1',
      typeData: {
        'jobListItemId': 'jl-1',
        'client': client,
        'jobType': jobType,
        DropsheetTask.kJobListFingerprintKey: 'fp',
        ...extra,
      },
    );

DropsheetDriverSection _section(List<DropsheetTask> tasks) =>
    DropsheetDriverSection(
        id: 's_petros', driverId: 'drv', driverName: 'Petros', tasks: tasks);

DropsheetTask _only(List<DropsheetDriverSection> sections) =>
    sections.single.tasks.single;

void main() {
  group('Team: on Junk & Stuff / Happy Sun jobs', () {
    test('lists every distributor allocated to the client, in row order', () {
      final out = DropsheetProvider.withJobCrewsForTest(
        [_section([_jsTask()])],
        [
          _job('j1', 'dThabo', ['Mrs Smith']),
          _job('j2', 'dSipho', ['mrs  smith']), // same client, typed loosely
          _job('j3', 'dPetros', ['Someone Else']),
        ],
        _dists,
      );
      final t = _only(out);
      expect(t.withNames, ['Sipho', 'Thabo']);
      expect(t.detailsText, 'Team: Sipho, Thabo');
    });

    test('leads Details, followed by the notes', () {
      final t = _jsTask(details: 'Bring the big trailer', extra: {
        DropsheetTask.kWithKey: ['Sipho', 'Thabo'],
      });
      expect(t.detailsText, 'Team: Sipho, Thabo · Bring the big trailer');
    });

    test('Happy Sun jobs get it too', () {
      final out = DropsheetProvider.withJobCrewsForTest(
        [_section([_jsTask(jobType: 'windowCleaning')])],
        [_job('j1', 'dThabo', ['Mrs Smith'])],
        _dists,
      );
      expect(_only(out).withNames, ['Thabo']);
    });

    test('CLM jobs are left alone', () {
      final out = DropsheetProvider.withJobCrewsForTest(
        [_section([_jsTask(jobType: 'flyerDistribution')])],
        [_job('j1', 'dThabo', ['Mrs Smith'])],
        _dists,
      );
      expect(_only(out).withNames, isEmpty);
    });

    test('taking a distributor off the job takes them off the sheet', () {
      final sections = [
        _section([
          _jsTask(extra: {
            DropsheetTask.kWithKey: ['Sipho', 'Thabo'],
          })
        ])
      ];
      final out = DropsheetProvider.withJobCrewsForTest(
          sections, [_job('j1', 'dThabo', ['Mrs Smith'])], _dists);
      expect(_only(out).withNames, ['Thabo']);
      final none = DropsheetProvider.withJobCrewsForTest(sections, [], _dists);
      expect(_only(none).typeData.containsKey(DropsheetTask.kWithKey), isFalse);
    });

    test('an unchanged task is returned as is (no needless save)', () {
      final task = _jsTask(extra: {
        DropsheetTask.kWithKey: ['Thabo'],
      });
      final sections = [_section([task])];
      final out = DropsheetProvider.withJobCrewsForTest(
          sections, [_job('j1', 'dThabo', ['Mrs Smith'])], _dists);
      expect(identical(out.single, sections.single), isTrue);
    });

    test('nothing changes while the distributor list is still loading', () {
      final task = _jsTask(extra: {
        DropsheetTask.kWithKey: ['Thabo'],
      });
      final out = DropsheetProvider.withJobCrewsForTest(
          [_section([task])], [_job('j1', 'dThabo', ['Mrs Smith'])], const []);
      expect(_only(out).withNames, ['Thabo']);
    });

    test('the schedule sync stamps it', () {
      final day = DropsheetDay(date: _date, sections: [
        _section([_jsTask()])
      ]);
      final out = DropsheetProvider.computeSyncedDayForTest(
          day, [_job('j1', 'dThabo', ['Mrs Smith'])], _dists);
      final js = out.sections
          .expand((s) => s.tasks)
          .firstWhere((t) => t.sourceJobListItemId == 'jl-1');
      expect(js.withNames, ['Thabo']);
    });

    test('a Job List rebuild keeps the names', () {
      final existing = _jsTask(extra: {
        DropsheetTask.kWithKey: ['Thabo'],
        'address': '12 Main Rd, Bellville',
      });
      final rebuilt = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'Gate code 1234'), _JobTypes(),
          existingTask: existing);
      expect(rebuilt.withNames, ['Thabo']);
      expect(rebuilt.detailsText, 'Team: Thabo · Gate code 1234');
    });
  });

  group('edits reach the sheet', () {
    test('a Job List special-instructions edit updates Details', () {
      final existing = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'Old note'), _JobTypes());
      final rebuilt = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'New note'), _JobTypes(),
          existingTask: existing);
      expect(rebuilt.details, 'New note');
    });

    test('rewording only the label no longer freezes Details', () {
      final base = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'Old note'), _JobTypes());
      final edited = base.copyWith(
        job: 'Big junk job',
        typeData: DropsheetTask.markUserEdited(base.typeData, {'job'},
            wasEdited: false),
      );
      final rebuilt = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'New note'), _JobTypes(),
          existingTask: edited);
      expect(rebuilt.job, 'Big junk job'); // the user's
      expect(rebuilt.details, 'New note'); // the Job List's
    });

    test('Details the user typed stay theirs', () {
      final base = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'Old note'), _JobTypes());
      final edited = base.copyWith(
        details: 'Ring first',
        typeData: DropsheetTask.markUserEdited(base.typeData, {'details'},
            wasEdited: false),
      );
      final rebuilt = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'New note'), _JobTypes(),
          existingTask: edited);
      expect(rebuilt.details, 'Ring first');
    });

    test('a task flagged by an older build keeps every field', () {
      final base = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'Old note'), _JobTypes());
      final edited = base.copyWith(
        details: 'Old note',
        typeData: {...base.typeData, DropsheetTask.kUserEditedKey: true},
      );
      final rebuilt = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'New note'), _JobTypes(),
          existingTask: edited);
      expect(rebuilt.details, 'Old note');
    });

    test('a furniture move\'s Notes are its Details', () {
      final move = DropsheetProvider.buildJobListTaskForTest(
          _item(
              jobTypeId: 'furnitureMove',
              specialInstructions: 'Fragile mirror',
              offloadingAddress: '5 Long St'),
          _JobTypes(twoStop: true));
      expect(move.details, 'Fragile mirror');
      expect(move.typeData['notes'], 'Fragile mirror');
      expect(move.detailsText, 'Fragile mirror');
    });

    test('older furniture moves show notes kept only in typeData', () {
      const move = DropsheetTask(
        id: 'fm',
        type: DropsheetTaskType.furnitureMove,
        typeData: {'notes': 'Two flights of stairs'},
      );
      expect(move.detailsText, 'Two flights of stairs');
    });

    test('a changed Job List address drops the old pin', () {
      final placed = DropsheetProvider.buildJobListTaskForTest(
              _item(), _JobTypes())
          .copyWith(typeData: {
        ...DropsheetProvider.buildJobListTaskForTest(_item(), _JobTypes())
            .typeData,
        'lat': -33.9,
        'lng': 18.6,
      });
      final same = DropsheetProvider.buildJobListTaskForTest(
          _item(specialInstructions: 'x'), _JobTypes(),
          existingTask: placed);
      expect(same.typeData['lat'], -33.9);
      final moved = DropsheetProvider.buildJobListTaskForTest(
          _item(area: '9 Other Rd, Parow'), _JobTypes(),
          existingTask: placed);
      expect(moved.location, '9 Other Rd, Parow');
      expect(moved.typeData.containsKey('lat'), isFalse);
    });
  });

  group('markUserEdited', () {
    test('adds to what the user reworded before', () {
      final first =
          DropsheetTask.markUserEdited({}, {'job'}, wasEdited: false)!;
      final second =
          DropsheetTask.markUserEdited(first, {'tel'}, wasEdited: true)!;
      expect(second[DropsheetTask.kUserEditedFieldsKey], ['job', 'tel']);
      final t = DropsheetTask(id: 'x', typeData: second);
      expect(t.userEditedField('job'), isTrue);
      expect(t.userEditedField('details'), isFalse);
    });

    test('nothing touched marks nothing', () {
      expect(DropsheetTask.markUserEdited({}, {}, wasEdited: false), isNull);
    });

    test('an older build\'s flag stays "every field"', () {
      final out = DropsheetTask.markUserEdited(
          {DropsheetTask.kUserEditedKey: true}, {'job'},
          wasEdited: true)!;
      expect(out.containsKey(DropsheetTask.kUserEditedFieldsKey), isFalse);
      expect(DropsheetTask(id: 'x', typeData: out).userEditedField('details'),
          isTrue);
    });
  });
}
