// Print Map and the distributor work areas map draw a schedule job's points
// from its clients' Job List bookings: a Junk & Stuff / Happy Sun point gets
// its job's pin and appointment time, and stacks in front of the drop-off.
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/services/client_address_pin.dart';
import 'package:clmschedule/services/job_client_bookings.dart';
import 'package:clmschedule/shareable_maps/adapters/date_schedule_adapter.dart';
import 'package:clmschedule/shareable_maps/adapters/schedule_job_adapter.dart';
import 'package:clmschedule/shareable_maps/models/map_point.dart';
import 'package:clmschedule/utils/map_pin_icons.dart';

CustomPolygon _point(
  String name, {
  PointCategory category = PointCategory.generic,
  LatLng at = const LatLng(-33.9, 18.6),
}) =>
    CustomPolygon(
      name: name,
      description: '',
      points: [at],
      color: Colors.red,
      type: MapElementType.point,
      pointCategory: category,
    );

Job _job(List<String> clients, List<CustomPolygon> maps, {LatLng? dropOff}) =>
    Job(
      id: 'j',
      clients: clients,
      workingAreas: const [],
      workMaps: maps,
      distributorId: 'd',
      date: DateTime(2026, 11, 2),
      statusId: 'scheduled',
      dropOffPoint: dropOff,
    );

void main() {
  const both = JobClientBookings(
    clients: ['Martin Vanlierde', 'Fagmeedah Petersen'],
    typeIds: {
      'martin vanlierde': 'junkCollection',
      'fagmeedah petersen': 'solarPanelCleaning',
    },
    times: {'martin vanlierde': '08:00', 'fagmeedah petersen': '11:30'},
  );

  group('JobClientBookings', () {
    test("a client's address pin shows that client's job and time", () {
      final pin = ClientAddressPin.asAutoPin(
          _point('3 Oak Rd', category: PointCategory.cleaning),
          'Fagmeedah Petersen');
      final style = both.styleFor(pin);
      expect(style.tag, contains('SOLAR'));
      expect(style.time, '11:30');
      expect(both.layerFor(pin), PinLayer.callOut);
    });

    test('a hand-placed point on a mixed job is a plain point', () {
      final robot = _point('Robot at Main Rd');
      expect(both.jobTypeFor(robot), isNull);
      expect(both.styleFor(robot).time, isNull);
      expect(both.layerFor(robot), PinLayer.point);
    });

    test('a job of one call-out client gives its points that job', () {
      const one = JobClientBookings(
        clients: ['Fagmeedah Petersen'],
        typeIds: {'fagmeedah petersen': 'solarPanelCleaning'},
        times: {'fagmeedah petersen': '11:30'},
      );
      final house = _point('3 Oak Rd', category: PointCategory.cleaning);
      expect(one.styleFor(house).time, '11:30');
      expect(one.layerFor(house), PinLayer.callOut);
    });

    test('the drop-off stacks behind everything', () {
      expect(both.layerFor(_point('Drop', category: PointCategory.dropoff)),
          PinLayer.dropOff);
      expect(PinLayer.dropOff, lessThan(PinLayer.point));
      expect(PinLayer.point, lessThan(PinLayer.callOut));
    });

    test('nothing known yet: category pictures, no times', () {
      final house = _point('3 Oak Rd', category: PointCategory.cleaning);
      expect(JobClientBookings.none.styleFor(house).tag, 'CLEANING');
      expect(JobClientBookings.none.layerFor(house), PinLayer.point);
    });
  });

  group('DateScheduleAdapter.pinsFor', () {
    test('gives every point the pin it gets on Print Map', () async {
      final pin = ClientAddressPin.asAutoPin(
          _point('3 Oak Rd', category: PointCategory.cleaning),
          'Fagmeedah Petersen');
      final job = _job([
        'Martin Vanlierde',
        'Fagmeedah Petersen'
      ], [
        _point('Drop', category: PointCategory.dropoff),
        pin,
      ]);
      final pins = DateScheduleAdapter.pinsFor([job], {'j': both});

      // The ids are the ones the adapter's map gives its points.
      final map =
          await DateScheduleAdapter(date: DateTime(2026, 11, 2), jobs: [job])
              .load();
      final ids = map.layers.single.points.map((p) => p.id).toSet();
      expect(pins.keys.toSet(), ids);

      final drop = pins['date_j_point_0']!;
      expect(drop.style, MapPinStyle.dropOff);
      expect(drop.zIndex, PinLayer.dropOff);
      final house = pins['date_j_point_1']!;
      expect(house.style.time, '11:30');
      expect(house.zIndex, PinLayer.callOut);
    });

    test('a drop-off stored only on the job gets the drop-off sign', () {
      final job = _job(['Martin Vanlierde'], [_point('Robot at Main Rd')],
          dropOff: const LatLng(-33.95, 18.5));
      final pins = DateScheduleAdapter.pinsFor([job], const {});
      expect(pins['date_j_dropoff']!.style, MapPinStyle.dropOff);
      expect(pins['date_j_dropoff']!.zIndex, PinLayer.dropOff);
    });
  });

  group('ScheduleJobAdapter.pinRule', () {
    MapPoint mapPoint(CustomPolygon p) => MapPoint(
          id: 'x',
          name: p.name,
          description: p.description,
          position: p.points.first,
          color: p.color,
          pointCategory: p.pointCategory,
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );

    test("pins the editor's live points as Print Map does", () {
      final rule = ScheduleJobAdapter.pinRule(both);
      expect(rule.layerIds, contains(kJobMapsLayerId));

      final house = rule.pinFor(mapPoint(ClientAddressPin.asAutoPin(
          _point('3 Oak Rd', category: PointCategory.cleaning),
          'Fagmeedah Petersen')))!;
      expect(house.style.time, '11:30');
      expect(house.zIndex, PinLayer.callOut);

      final drop = rule
          .pinFor(mapPoint(_point('Drop', category: PointCategory.dropoff)))!;
      expect(drop.style, MapPinStyle.dropOff);
      expect(drop.zIndex, PinLayer.dropOff);
    });
  });
}
