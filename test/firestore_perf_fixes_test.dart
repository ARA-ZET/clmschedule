// Unit tests for the pure pieces of the 2026-10-28 Firestore performance
// pass: the v2 schedule audit-log diff, the payroll no-op write check, the
// client-map fingerprint and the dropsheet job-list fingerprint.
import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/distributor_payroll_profile.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/models/payroll_settings.dart';
import 'package:clmschedule/models/payroll_payslip.dart';
import 'package:clmschedule/providers/dropsheet_provider.dart';
import 'package:clmschedule/services/area_link_resolver.dart';
import 'package:clmschedule/services/payroll_service.dart';
import 'package:clmschedule/services/schedule_mutation_types.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

Map<String, dynamic> _job(String id, {String status = 'scheduled'}) => {
      'id': id,
      'clients': ['Client $id'],
      'statusId': status,
      'date': Timestamp.fromMillisecondsSinceEpoch(1761602400000),
    };

JobListItem _item(String id, {String area = ''}) {
  final date = DateTime(2026, 10, 28);
  return JobListItem(
    id: id,
    invoice: '',
    amount: 0,
    client: 'Client $id',
    jobStatusId: 'standby',
    jobTypeId: 'furnitureMove',
    area: area,
    quantity: 0,
    manDays: 1,
    date: date,
    collectionAddress: '',
    collectionDate: date,
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: '',
    reportAddresses: '',
    whoToInvoice: '',
  );
}

CustomPolygon _polygon(String id, {String name = 'Area'}) => CustomPolygon(
      id: id,
      name: name,
      description: '',
      points: const [
        LatLng(-33.9, 18.4),
        LatLng(-33.9, 18.5),
        LatLng(-33.8, 18.5),
      ],
      color: Colors.green,
    );

void main() {
  group('scheduleDayLogDiff', () {
    test('records added, removed and changed jobs only', () {
      final before = {
        'date': '2026-10-28',
        'jobs': [_job('a'), _job('b'), _job('c')],
      };
      final after = {
        'date': '2026-10-28',
        'jobs': [_job('a'), _job('b', status: 'done'), _job('d')],
      };

      final diff = scheduleDayLogDiff(beforeDoc: before, afterDoc: after);

      expect((diff['added'] as List).map((j) => j['id']), ['d']);
      expect((diff['removed'] as List).map((j) => j['id']), ['c']);
      final changed = diff['changed'] as List;
      expect(changed, hasLength(1));
      expect(changed.single['id'], 'b');
      expect(changed.single['before']['statusId'], 'scheduled');
      expect(changed.single['after']['statusId'], 'done');
      expect(diff.containsKey('order'), isFalse);
      expect(diff['fieldChanges'], isEmpty);
    });

    test('a reorder with no content change records the new order', () {
      final before = {
        'jobs': [_job('a'), _job('b')],
      };
      final after = {
        'jobs': [_job('b'), _job('a')],
      };

      final diff = scheduleDayLogDiff(beforeDoc: before, afterDoc: after);

      expect(diff['added'], isEmpty);
      expect(diff['removed'], isEmpty);
      expect(diff['changed'], isEmpty);
      expect(diff['order'], ['b', 'a']);
    });

    test('a new day logs every job as added and its new fields', () {
      final after = {
        'date': '2026-10-28',
        'jobs': [_job('a')],
      };

      final diff = scheduleDayLogDiff(beforeDoc: null, afterDoc: after);

      expect((diff['added'] as List).map((j) => j['id']), ['a']);
      expect(diff['removed'], isEmpty);
      expect(diff['fieldChanges'], {
        'date': {'before': null, 'after': '2026-10-28'},
      });
    });

    test('day-level field changes and removals are recorded', () {
      final before = {
        'jobs': [_job('a')],
        'confirmationStatus': 'confirmed',
        'confirmedBy': 'Sam',
      };
      final after = {
        'jobs': [_job('a')],
        'confirmationStatus': 'unconfirmed',
      };

      final diff = scheduleDayLogDiff(beforeDoc: before, afterDoc: after);

      expect(diff['changed'], isEmpty);
      expect(diff['fieldChanges'], {
        'confirmationStatus': {'before': 'confirmed', 'after': 'unconfirmed'},
        'confirmedBy': {'before': 'Sam', 'after': null},
      });
    });

    test('jobs without an id are matched by content', () {
      final noId = {'clients': ['Walk-in']};
      final before = {
        'jobs': [noId, _job('a')],
      };
      final after = {
        'jobs': [
          {'clients': ['Walk-in']},
          _job('a'),
          {'clients': ['Other']},
        ],
      };

      final diff = scheduleDayLogDiff(beforeDoc: before, afterDoc: after);

      expect(diff['added'], [
        {'clients': ['Other']},
      ]);
      expect(diff['removed'], isEmpty);
    });
  });

  group('payslipsMatchIgnoringStamp', () {
    final settings = PayrollSettings.defaults();
    PayrollPayslip blank() => PayrollPayslip.blank(
          distributorId: 'd1',
          distributorName: 'Dumi',
          weekStart: DateTime(2026, 10, 23),
          settings: settings,
          profile: const DistributorPayrollProfile(),
        );

    test('ignores who saved it (and when)', () {
      final a = blank().copyWith(updatedBy: 'admin1@clm');
      final b = blank().copyWith(updatedBy: 'admin2@clm');
      expect(payslipsMatchIgnoringStamp(a, b), isTrue);
    });

    test('sees a changed day entry', () {
      final a = blank();
      final key = a.dailyEntries.keys.first;
      final b = a.copyWith(dailyEntries: {
        ...a.dailyEntries,
        key: a.dailyEntries[key]!.copyWith(worked: true),
      });
      expect(payslipsMatchIgnoringStamp(a, b), isFalse);
    });
  });

  group('AreaLinkResolver.sameLinkedContent', () {
    ({bool exists, String name, Map<String, CustomPolygon> polygons}) map(
            Map<String, CustomPolygon> polygons,
            {bool exists = true,
            String name = 'Map'}) =>
        (exists: exists, name: name, polygons: polygons);

    test('equal maps match whatever the key order', () {
      expect(
          AreaLinkResolver.sameLinkedContent(
            map({'p1': _polygon('p1'), 'p2': _polygon('p2')}),
            map({'p2': _polygon('p2'), 'p1': _polygon('p1')}),
          ),
          isTrue);
    });

    test('a renamed polygon, map rename, new polygon or deletion differs', () {
      final base = map({'p1': _polygon('p1')});
      expect(
          AreaLinkResolver.sameLinkedContent(
              base, map({'p1': _polygon('p1', name: 'Other')})),
          isFalse);
      expect(
          AreaLinkResolver.sameLinkedContent(
              base, map({'p1': _polygon('p1')}, name: 'Renamed')),
          isFalse);
      expect(
          AreaLinkResolver.sameLinkedContent(
              base, map({'p1': _polygon('p1'), 'p2': _polygon('p2')})),
          isFalse);
      expect(
          AreaLinkResolver.sameLinkedContent(
              base, map(const {}, exists: false)),
          isFalse);
    });
  });

  group('jobListItemsFingerprint', () {
    test('stable for the same items, changes when one changes', () {
      final items = [_item('a'), _item('b')];
      expect(jobListItemsFingerprint(items),
          jobListItemsFingerprint([_item('a'), _item('b')]));
      expect(jobListItemsFingerprint([_item('a'), _item('b', area: 'Rondebosch')]),
          isNot(jobListItemsFingerprint(items)));
      expect(jobListItemsFingerprint([_item('a')]),
          isNot(jobListItemsFingerprint(items)));
    });
  });
}
