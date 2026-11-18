// A worker given a Junk & Stuff / Happy Sun client on the Schedule
// gets the client's address from the Job List as a map point, so their
// dropsheet drop-off lands at the house. These pin down which jobs qualify,
// which Job List job is used, and what the pinned job looks like.
import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/models/job_area_link.dart';
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/client_address_pin.dart';

const _house = LatLng(-33.9005, 18.6285);

const _itemPoint = CustomPolygon(
  name: '12 Durban Rd, Bellville',
  description: '',
  points: [_house],
  color: Colors.green,
  type: MapElementType.point,
  pointCategory: PointCategory.pickup,
);

const _handPlaced = CustomPolygon(
  name: 'Corner',
  description: '',
  points: [LatLng(-33.91, 18.63)],
  color: Colors.red,
  type: MapElementType.point,
);

const _polygon = CustomPolygon(
  name: 'Bellville Central',
  description: '',
  points: [LatLng(-33.90, 18.62), LatLng(-33.90, 18.63), LatLng(-33.91, 18.63)],
  color: Colors.blue,
);

Job _job({
  List<String> clients = const ['Mrs Smith'],
  List<String> areas = const [],
  List<CustomPolygon> maps = const [],
  List<JobAreaLink> links = const [],
  DateTime? date,
}) =>
    Job(
      id: 'j',
      clients: clients,
      workingAreas: areas,
      workMaps: maps,
      areaLinks: links,
      distributorId: 'd',
      date: date ?? DateTime(2026, 10, 22),
      statusId: 'scheduled',
    );

JobListItem _item({
  String id = 'i',
  String client = 'Mrs Smith',
  String type = 'junkCollection',
  DateTime? date,
  String area = '12 Durban Rd, Bellville',
  String collectionAddress = '',
  List<CustomPolygon> polygons = const [_itemPoint],
}) {
  final d = date ?? DateTime(2026, 10, 22);
  return JobListItem(
    id: id,
    invoice: '',
    amount: 0,
    client: client,
    jobStatusId: 'pending',
    jobTypeId: type,
    area: area,
    quantity: 0,
    manDays: 0,
    date: d,
    collectionAddress: collectionAddress,
    collectionDate: d,
    specialInstructions: '',
    quantityDistributed: 0,
    invoiceDetails: '',
    reportAddresses: '',
    whoToInvoice: '',
    customPolygons: polygons,
  );
}

Job _pinned(Job job, JobListItem item) {
  final key = ClientAddressPin.unpinnedClientKeys(job).first;
  return ClientAddressPin.apply(
      job, {key: (item, ClientAddressPin.pointFromItem(item)!)});
}

void main() {
  group('needsPin', () {
    test('an empty job with a client needs one', () {
      expect(ClientAddressPin.needsPin(_job()), isTrue);
    });

    test('a job with no client does not', () {
      expect(ClientAddressPin.needsPin(_job(clients: const [])), isFalse);
    });

    test('anything placed by hand stops it', () {
      expect(ClientAddressPin.needsPin(_job(maps: const [_polygon])), isFalse);
      expect(
          ClientAddressPin.needsPin(_job(maps: const [_handPlaced])), isFalse);
      expect(
          ClientAddressPin.needsPin(_job(links: const [
            JobAreaLink(mapId: 'm', monthKey: '2026-10', polygonId: 'p'),
          ])),
          isFalse);
    });

    test('a drop-off point does not stop it, and stays when pinned', () {
      const dropOff = CustomPolygon(
        name: 'Constantia',
        description: '',
        points: [LatLng(-34.02, 18.44)],
        color: Colors.red,
        type: MapElementType.point,
        pointCategory: PointCategory.dropoff,
      );
      final job = _job(maps: const [dropOff]);
      expect(ClientAddressPin.needsPin(job), isTrue);

      final pinned = _pinned(job, _item());
      expect(pinned.workMaps, hasLength(2));
      expect(pinned.workMaps.first, dropOff);
      expect(ClientAddressPin.isAutoPin(pinned.workMaps.last), isTrue);
      expect(pinned.workingAreas, ['12 Durban Rd, Bellville']);
      expect(ClientAddressPin.needsPin(pinned), isFalse);
    });

    test('a job pinned for its client is done; a new client needs one', () {
      final pinned = _pinned(_job(), _item());
      expect(ClientAddressPin.needsPin(pinned), isFalse);
      expect(
          ClientAddressPin.needsPin(
              pinned.copyWith(clients: ['Mrs Smith', 'Mr Jones'])),
          isTrue);
    });
  });

  group('matchItems', () {
    test('only Junk & Stuff and Happy Sun jobs count', () {
      expect(
          ClientAddressPin.matchItems(
              _job(), [_item(type: 'flyerDistribution')]),
          isEmpty);
      expect(
          ClientAddressPin.matchItems(_job(), [_item(type: 'windowCleaning')]),
          hasLength(1));
    });

    test('the nearest-dated Job List job wins', () {
      final match = ClientAddressPin.matchItems(_job(), [
        _item(id: 'old', date: DateTime(2026, 10, 1)),
        _item(id: 'near', date: DateTime(2026, 10, 23)),
      ]);
      expect(match.values.single.id, 'near');
    });

    test('a Job List job more than a week later does not match', () {
      expect(
          ClientAddressPin.matchItems(
              _job(), [_item(date: DateTime(2026, 10, 30))]),
          isEmpty);
    });

    test('client names match ignoring case and spacing', () {
      expect(
          ClientAddressPin.matchItems(
              _job(clients: const ['mrs  smith ']), [_item()]),
          hasLength(1));
    });
  });

  test('pointFromItem is null when the Job List job has no point', () {
    expect(ClientAddressPin.pointFromItem(_item(polygons: const [])), isNull);
    expect(ClientAddressPin.pointFromItem(_item())!.points.single, _house);
  });

  test('addressText skips a map link for the collection address', () {
    final item = _item(
        area: 'https://maps.app.goo.gl/abc', collectionAddress: '3 Main Rd');
    expect(ClientAddressPin.addressText(item), '3 Main Rd');
  });

  group('apply', () {
    test('adds the pin, names the work area and drives the drop-off', () {
      final pinned = _pinned(_job(areas: const ['To be assigned']), _item());
      final pin = pinned.workMaps.single;
      expect(ClientAddressPin.isAutoPin(pin), isTrue);
      expect(pin.points.single, _house);
      expect(pinned.workingAreas, ['12 Durban Rd, Bellville']);

      final normalized = ScheduleProvider.normalizeDropOffPointForTest(pinned);
      expect(normalized.dropOffPoint, _house);
    });

    test('a work area someone typed is kept', () {
      final pinned = _pinned(_job(areas: const ['Front gate']), _item());
      expect(pinned.workingAreas, ['Front gate']);
    });

    test('changing the client replaces the old pin and its area name', () {
      final first = _pinned(_job(), _item());
      final changed = first.copyWith(clients: ['Mr Jones']);
      expect(ClientAddressPin.needsPin(changed), isTrue);

      const otherHouse = LatLng(-33.95, 18.50);
      final jones = _item(
        client: 'Mr Jones',
        type: 'windowCleaning',
        area: '7 Long St',
        polygons: [
          _itemPoint.copyWith(name: '7 Long St', points: [otherHouse]),
        ],
      );
      final second = _pinned(changed, jones);
      expect(second.workMaps.single.points.single, otherHouse);
      expect(second.workingAreas, ['7 Long St']);
    });

    test('a geocoded pin is a cleaning point for window cleaning', () {
      final pin = ClientAddressPin.pointAt(
          _item(type: 'windowCleaning', polygons: const []), _house);
      expect(pin.pointCategory, PointCategory.cleaning);
      expect(pin.name, '12 Durban Rd, Bellville');
    });

    test('every Happy Sun and Junk & Stuff job type is pinned', () {
      for (final type in [
        'junkCollection',
        'furnitureMove',
        'windowCleaning',
        'solarPanelCleaning',
      ]) {
        expect(ClientAddressPin.matchItems(_job(), [_item(type: type)]),
            hasLength(1),
            reason: type);
      }
    });

    test('a geocoded pin is a cleaning point for solar panel cleaning', () {
      final pin = ClientAddressPin.pointAt(
          _item(type: 'solarPanelCleaning', polygons: const []), _house);
      expect(pin.pointCategory, PointCategory.cleaning);
    });

    test('a geocoded pin is a loading point for a furniture move', () {
      final pin = ClientAddressPin.pointAt(
          _item(type: 'furnitureMove', polygons: const []), _house);
      expect(pin.pointCategory, PointCategory.loading);
    });
  });

  group('removing a client', () {
    test('takes its pin and the area name it gave', () {
      final pinned = _pinned(_job(), _item());
      final removed =
          ClientAddressPin.withoutStalePins(pinned.copyWith(clients: []));
      expect(removed.workMaps, isEmpty);
      expect(removed.workingAreas, ['To be assigned']);
      expect(removed.dropOffPoint, isNull);
    });

    test('keeps the pins of clients still on the job', () {
      final smith =
          _pinned(_job(clients: const ['Mrs Smith', 'Mr Jones']), _item());
      final jones = _item(
        client: 'Mr Jones',
        area: '7 Long St',
        polygons: [
          _itemPoint.copyWith(
              name: '7 Long St', points: [const LatLng(-33.95, 18.50)]),
        ],
      );
      final both = _pinned(smith, jones);
      final removed = ClientAddressPin.withoutStalePins(
          both.copyWith(clients: ['Mr Jones']));
      expect(removed.workMaps.map((p) => p.name), ['7 Long St']);
      expect(removed.workingAreas, ['7 Long St']);
    });

    test('leaves hand-placed maps and names alone', () {
      final job = _job(
          clients: const [],
          areas: const ['Corner'],
          maps: const [_handPlaced, _polygon]);
      expect(identical(ClientAddressPin.withoutStalePins(job), job), isTrue);
    });

    test('recognises an unmarked Job List address pin by its spot', () {
      final copied = _itemPoint.copyWith(name: 'Durban Road');
      expect(ClientAddressPin.isUnmarkedItemPin(copied, _item()), isTrue);
      expect(ClientAddressPin.isUnmarkedItemPin(_handPlaced, _item()), isFalse);
      final marked = ClientAddressPin.asAutoPin(_itemPoint, 'Mrs Smith');
      expect(ClientAddressPin.isUnmarkedItemPin(marked, _item()), isFalse);
      expect(ClientAddressPin.isAutoPin(marked), isTrue);
    });
  });
}
