// Which client map a promoter's route map links to: the Job List job whose
// folder holds the promoter's files, the deepest folder winning.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/services/te_report_map_links.dart';
import 'package:flutter_test/flutter_test.dart';

TEPromoterDay _day(List<String> paths) => TEPromoterDay(
      distributor: Distributor(id: 'd1', name: 'Nolan', index: 0),
      date: DateTime(2026, 5, 11),
      tracks: const [],
      waypoints: const [],
      sourcePaths: paths,
    );

JobListItem _item(String id, String folder) => JobListItem(
      id: id,
      invoice: '',
      amount: 0,
      client: 'Jo Lombard',
      jobStatusId: 'standby',
      jobTypeId: 'flyers',
      area: '',
      quantity: 0,
      manDays: 1,
      date: DateTime(2026, 5, 11),
      collectionAddress: '',
      collectionDate: DateTime(2026, 5, 11),
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
      storageFolderPath: folder,
    );

void main() {
  const client = 'Distribution/2026/May 2026/Jo Lombard';

  test('candidate folders run from the file up to the client folder', () {
    expect(teJobFolderCandidates('$client/Round 2/nolan.gpx'), [
      '$client/Round 2',
      client,
    ]);
    expect(teJobFolderCandidates('$client/nolan.gpx'), [client]);
    expect(teJobFolderCandidates('Distribution/2026/May 2026/x.gpx'), isEmpty);
  });

  test("the deepest job folder holding the day's files wins", () {
    final round1 = _item('r1', client);
    final round2 = _item('r2', '$client/Round 2/');
    final other = _item('o', 'Distribution/2026/May 2026/Someone Else');

    expect(teJobForDay(_day(['$client/Round 2/nolan.gpx']),
            [round1, round2, other])?.id,
        'r2');
    expect(teJobForDay(_day(['$client/nolan.gpx']), [round1, round2, other])
        ?.id, 'r1');
    expect(
        teJobForDay(_day(['Distribution/2026/May 2026/Jo Lombardi/x.gpx']),
            [round1, round2, other]),
        isNull,
        reason: 'a folder whose name merely starts the same is not a match');
  });
}
