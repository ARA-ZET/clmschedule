import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_area_link.dart';
import 'package:clmschedule/models/job_linked_map.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/track_editor/services/te_track_clients.dart';
import 'package:clmschedule/utils/distribution_lag.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _item(
  String id,
  String client,
  DateTime date, {
  double manDays = 1,
  String mapId = '',
  String folder = '',
}) =>
    JobListItem(
      id: id,
      invoice: '',
      amount: 0,
      client: client,
      jobStatusId: 'standby',
      jobTypeId: 'flyers',
      area: '',
      quantity: 0,
      manDays: manDays,
      date: date,
      collectionAddress: '',
      collectionDate: date,
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      shareableMapId: mapId,
      storageFolderPath: folder,
    );

Job _job(
  String id,
  List<String> clients,
  DateTime date, {
  String areaFromMap = '',
  String linkedMap = '',
}) =>
    Job(
      id: id,
      clients: clients,
      workingAreas: const [],
      workMaps: const [],
      distributorId: 'd-$id',
      date: date,
      statusId: 'scheduled',
      areaLinks: [
        if (areaFromMap.isNotEmpty)
          JobAreaLink(mapId: areaFromMap, monthKey: '10-2026', polygonId: 'p1'),
      ],
      linkedMaps: [
        if (linkedMap.isNotEmpty)
          JobLinkedMap(mapId: linkedMap, monthKey: '10-2026'),
      ],
    );

/// A schedule job belongs to the Job List item whose client map it works
/// from; the date rule only decides the days nothing links.
void main() {
  test('a job holding areas from an item\'s map belongs to that item', () {
    final pairing = pairJobsWithJobListItems(
      items: [
        _item('round1', 'Acme', DateTime(2026, 10, 1), mapId: 'm1'),
        _item('round2', 'Acme', DateTime(2026, 10, 8), mapId: 'm2'),
      ],
      jobs: [
        // Nearer round 2 by date, but worked from round 1's map.
        _job('late', ['Acme'], DateTime(2026, 10, 7), areaFromMap: 'm1'),
        _job('plain', ['acme'], DateTime(2026, 10, 8)),
      ],
    );
    expect(pairing['late']!['acme']!.id, 'round1');
    expect(pairing['plain']!['acme']!.id, 'round2');
  });

  test('a linked map counts like allocated areas', () {
    final pairing = pairJobsWithJobListItems(
      items: [
        _item('a', 'Acme', DateTime(2026, 10, 1), mapId: 'm1'),
        _item('b', 'Acme', DateTime(2026, 10, 3), mapId: 'm2'),
      ],
      jobs: [_job('j', ['Acme'], DateTime(2026, 10, 3), linkedMap: 'm1')],
    );
    expect(pairing['j']!['acme']!.id, 'a');
  });

  test('another round keeps its own days', () {
    final pairing = pairJobsWithJobListItems(
      items: [
        _item('sep', 'Acme', DateTime(2026, 9, 28), manDays: 2),
        _item('oct', 'Acme', DateTime(2026, 10, 12), manDays: 1),
      ],
      jobs: [
        _job('a', ['Acme'], DateTime(2026, 9, 28)),
        _job('b', ['Acme'], DateTime(2026, 9, 29)),
        _job('c', ['Acme'], DateTime(2026, 10, 12)),
      ],
    );
    expect(pairing['a']!['acme']!.id, 'sep');
    expect(pairing['b']!['acme']!.id, 'sep');
    expect(pairing['c']!['acme']!.id, 'oct');
  });

  test('an item with no man-days still claims a day', () {
    final pairing = pairJobsWithJobListItems(
      items: [_item('i', 'Acme', DateTime(2026, 10, 1), manDays: 0)],
      jobs: [_job('j', ['Acme'], DateTime(2026, 10, 2))],
    );
    expect(pairing['j']!['acme']!.id, 'i');
  });

  group('track filing', () {
    test('tracks go to the paired item\'s own folder', () {
      // Round 2's folder is a `Round N` sub-folder of the month listed
      // before the track's — a path rebuilt from the name would miss it.
      final items = [
        _item('r1', 'Acme', DateTime(2026, 9, 2),
            folder: 'Distribution/2026/Sep 2026/Acme'),
        _item('r2', 'Acme', DateTime(2026, 9, 30),
            mapId: 'm2', folder: 'Distribution/2026/Sep 2026/Acme/Round 2'),
      ];
      final day = [
        _job('today', ['Acme'], DateTime(2026, 10, 2), areaFromMap: 'm2'),
      ];
      final byClient = jobListItemsForDayJobs(
        dayJobs: day,
        otherJobs: [_job('first', ['Acme'], DateTime(2026, 9, 2))],
        items: items,
      );
      expect(jobListTrackFolder(byClient['acme']),
          'Distribution/2026/Sep 2026/Acme/Round 2');
    });

    test('no item, or an item without a folder yet, gives no folder', () {
      final byClient = jobListItemsForDayJobs(
        dayJobs: [_job('j', ['Acme', 'Other'], DateTime(2026, 10, 2))],
        otherJobs: const [],
        items: [_item('i', 'Acme', DateTime(2026, 10, 2))],
      );
      expect(jobListTrackFolder(byClient['acme']), isNull);
      expect(jobListTrackFolder(byClient['other']), isNull);
    });
  });
}
