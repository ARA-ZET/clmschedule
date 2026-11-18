import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/utils/distribution_lag.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _item(String id, String client, DateTime date, double manDays) =>
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
    );

Job _job(String id, List<String> clients, DateTime date) => Job(
      id: id,
      clients: clients,
      workingAreas: const [],
      workMaps: const [],
      distributorId: 'd-$id',
      date: date,
      statusId: 'scheduled',
    );

void main() {
  test('client key ignores case and stray spaces', () {
    // The Job List refuses a second job under the same key, so these must
    // all count as one name.
    expect(jobListClientKey('  ABC  Pizza '), 'abc pizza');
    expect(jobListClientKey('abc\tpizza'), jobListClientKey('ABC Pizza'));
    expect(jobListClientKey('ABC Pizza 2'), isNot(jobListClientKey('ABC Pizza')));
  });

  test('thresholds: same day green, under 3 orange, else red', () {
    expect(lagForDays(0), DistributionLag.onTime);
    expect(lagForDays(1), DistributionLag.late);
    expect(lagForDays(2), DistributionLag.late);
    expect(lagForDays(3), DistributionLag.overdue);
  });

  test('days go to the nearest item; overflow runs on past the next one', () {
    final lag = computeDistributionLagDays(
      items: [
        _item('big', 'Acme', DateTime(2026, 9, 1), 3),
        _item('weekly', 'acme ', DateTime(2026, 9, 8), 1),
      ],
      jobs: [
        _job('a', ['Acme'], DateTime(2026, 9, 1)),
        _job('b', ['Acme'], DateTime(2026, 9, 2)),
        _job('c', ['Acme'], DateTime(2026, 9, 9)),
        // Overflow of "big", landing after "weekly" took its day.
        _job('d', ['Acme'], DateTime(2026, 9, 10)),
      ],
    );
    expect(lag['a'], 0);
    expect(lag['b'], 1);
    expect(lag['c'], 1); // weekly, 8 Sep → 9 Sep
    expect(lag['d'], 9); // big, 1 Sep → 10 Sep
  });

  test('work done early is on time, not the previous item running late', () {
    // Westerford Spar, Sep–Oct 2026: the 30 Sep item was distributed on
    // 28 Sep and the 6 Oct one on 5 Oct. Measuring only forward pinned the
    // 5 Oct days on the 30 Sep item as 5 days late.
    final lag = computeDistributionLag(
      items: [
        _item('sep30', 'Westerford Spar', DateTime(2026, 9, 30), 2),
        _item('oct6', 'Westerford Spar', DateTime(2026, 10, 6), 2),
      ],
      jobs: [
        _job('s1', ['Westerford Spar'], DateTime(2026, 9, 28)),
        _job('s2', ['Westerford Spar'], DateTime(2026, 9, 28)),
        _job('o1', ['Westerford Spar'], DateTime(2026, 10, 5)),
        _job('o2', ['Westerford Spar'], DateTime(2026, 10, 5)),
      ],
    );
    expect(lag['s1']!.days, -2);
    expect(lag['o1']!.days, -1);
    expect(lag['o2']!.listDate, DateTime.utc(2026, 10, 6));
    expect(lagForDays(lag['o1']!.days), DistributionLag.onTime);
  });

  test('a shared cell names the client that is behind', () {
    final lag = computeDistributionLag(
      items: [
        _item('h', 'Henru', DateTime(2026, 10, 6, 10), 2),
        _item('k', 'Kestrel Routing', DateTime(2026, 10, 5, 14), 2),
      ],
      jobs: [_job('hk', ['Henru', 'Kestrel Routing'], DateTime(2026, 10, 6))],
    );
    expect(lag['hk']!.days, 1);
    expect(lag['hk']!.client, 'Kestrel Routing');
  });

  test('combined job takes its latest client; unmatched jobs are left out',
      () {
    final lag = computeDistributionLagDays(
      items: [
        _item('x', 'X', DateTime(2026, 9, 10), 1),
        _item('y', 'Y', DateTime(2026, 9, 5), 1),
      ],
      jobs: [
        _job('xy', ['X', 'Y'], DateTime(2026, 9, 10)),
        _job('z', ['Unknown'], DateTime(2026, 9, 10)),
        _job('early', ['X'], DateTime(2026, 9, 1)),
      ],
    );
    expect(lag['xy'], 5);
    expect(lag.containsKey('z'), isFalse);
    expect(lag.containsKey('early'), isFalse);
  });

  test('extra days beyond man-days measure from the latest earlier item', () {
    final lag = computeDistributionLagDays(
      items: [_item('i', 'C', DateTime(2026, 9, 1), 1)],
      jobs: [
        _job('one', ['C'], DateTime(2026, 9, 1)),
        _job('extra', ['C'], DateTime(2026, 9, 4)),
      ],
    );
    expect(lag['one'], 0);
    expect(lag['extra'], 3);
  });
}
