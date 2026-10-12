import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/models/custom_job_type.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/track_editor/services/te_track_clients.dart';

/// Processing only offers clients whose work leaves GPS waypoints behind;
/// collection and window-cleaning clients are hidden.
void main() {
  const types = [
    CustomJobType(
        id: 'flyerDistribution',
        label: 'Flyer Distribution',
        createsCloudFolder: true),
    CustomJobType(id: 'junkCollection', label: 'Junk Collection'),
    CustomJobType(id: 'windowCleaning', label: 'Window Cleaning'),
  ];

  ({String client, String jobTypeId}) item(String c, String t) =>
      (client: c, jobTypeId: t);

  test('collection and window-cleaning clients are hidden', () {
    final hidden = clientsWithoutTracks([
      item('Acme Flyers', 'flyerDistribution'),
      item('Smith Junk', 'junkCollection'),
      item('Glass Co', 'windowCleaning'),
    ], types);
    expect(hidden, {'Smith Junk', 'Glass Co'});
  });

  test('a client with any distribution entry stays visible', () {
    final hidden = clientsWithoutTracks([
      item('Both Ltd', 'junkCollection'),
      item('Both Ltd', 'flyerDistribution'),
    ], types);
    expect(hidden, isEmpty);
  });

  test('an unknown job type is kept rather than hidden', () {
    final hidden = clientsWithoutTracks([item('New Co', 'mystery')], types);
    expect(hidden, isEmpty);
  });

  test('a client missing from the Job List is never hidden', () {
    expect(clientsWithoutTracks(const [], types), isEmpty);
  });

  JobListItem listed(String client, String type) => JobListItem(
        id: client,
        invoice: '',
        amount: 0,
        client: client,
        jobStatusId: '',
        jobTypeId: type,
        area: '',
        quantity: 0,
        manDays: 0,
        date: DateTime(2026, 9, 1),
        collectionAddress: '',
        collectionDate: DateTime(2026, 9, 1),
        specialInstructions: '',
        quantityDistributed: 0,
        invoiceDetails: '',
        reportAddresses: '',
        whoToInvoice: '',
      );

  test('schedule clients match the in-memory Job List ignoring case', () {
    final hidden = findClientsWithoutTracks(
      clients: ['smith junk ', 'Acme Flyers', 'Unlisted'],
      jobListItems: [
        listed('Smith Junk', 'junkCollection'),
        listed('Acme Flyers', 'flyerDistribution'),
      ],
      jobTypes: types,
    );
    // Reported as the schedule spells it, so the caller can filter by it.
    expect(hidden, {'smith junk '});
  });
}
