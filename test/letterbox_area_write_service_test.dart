// The real area-replacement path, driven end to end against fakes.
//
// `letterbox_area_replace_test.dart` pins the geometric rule in isolation;
// this exercises `LetterboxAreaWriteService` itself — the plan/apply/restore
// the curation page and the track editor both call — so a change to the
// service's storage, metadata or undo behaviour is caught, not just its maths.
import 'dart:typed_data';

import 'package:clmschedule/letterbox/models/letterbox_suburb.dart';
import 'package:clmschedule/letterbox/services/letterbox_area_write_service.dart';
import 'package:clmschedule/letterbox/services/letterbox_codec.dart';
import 'package:clmschedule/letterbox/services/letterbox_firestore_service.dart';
import 'package:clmschedule/letterbox/services/letterbox_storage_service.dart';
import 'package:clmschedule/models/work_suburb.dart';
import 'package:clmschedule/shareable_maps/services/suburb_data_service.dart';
import 'package:clmschedule/track_editor/providers/te_letterbox_write_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:gpx/gpx.dart';

class _FakeSuburbData extends SuburbDataService {
  _FakeSuburbData(this.result);
  final List<WorkSuburb> result;

  @override
  Future<List<WorkSuburb>> loadSuburbs({bool forceRefresh = false}) async =>
      result;
}

class _FakeStorage extends LetterboxStorageService {
  final Map<String, Uint8List> files = {};

  /// Suburb ids whose payload cannot be read — the "do not overwrite what you
  /// could not read" case.
  final Set<String> unreadable = {};

  /// Suburb ids whose save fails.
  final Set<String> unwritable = {};

  @override
  Future<Uint8List?> load(String suburbId) async {
    if (unreadable.contains(suburbId)) {
      throw StateError('network down for $suburbId');
    }
    return files[suburbId];
  }

  @override
  Future<int> save(String suburbId, Uint8List bytes) async {
    if (unwritable.contains(suburbId)) {
      throw StateError('write refused for $suburbId');
    }
    files[suburbId] = bytes;
    return bytes.length;
  }

  @override
  Future<void> delete(String suburbId) async => files.remove(suburbId);

  List<LatLng> pointsOf(String suburbId) {
    final bytes = files[suburbId];
    return bytes == null ? const [] : LetterboxCodec.decode(bytes);
  }
}

class _FakeFirestore extends LetterboxFirestoreService {
  final Map<String, LetterboxSuburb> docs = {};

  @override
  Future<LetterboxSuburb?> get(String suburbId) async => docs[suburbId];

  @override
  Future<void> save(LetterboxSuburb suburb) async {
    docs[suburb.suburbId] = suburb;
  }

  @override
  Future<void> delete(String suburbId) async {
    docs.remove(suburbId);
  }
}

List<LatLng> box(double minLat, double minLng, double size) => [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ];

WorkSuburb suburbOf(String id, String name, List<LatLng> boundary) =>
    WorkSuburb(id: id, name: name, description: '', polygonPoints: boundary);

void main() {
  // Two suburbs side by side, split at lng 18.42.
  final west = suburbOf('west', 'Westville', box(-33.94, 18.40, 0.02));
  final east = suburbOf('east', 'Eastville', [
    const LatLng(-33.94, 18.42),
    const LatLng(-33.94, 18.44),
    const LatLng(-33.92, 18.44),
    const LatLng(-33.92, 18.42),
  ]);

  // A re-surveyed area straddling the boundary: lng 18.415 → 18.425.
  final area = [
    const LatLng(-33.932, 18.415),
    const LatLng(-33.932, 18.425),
    const LatLng(-33.928, 18.425),
    const LatLng(-33.928, 18.415),
  ];

  const oldWestInside = LatLng(-33.930, 18.417);
  const oldWestOutside = LatLng(-33.935, 18.405);
  const oldEastInside = LatLng(-33.930, 18.423);
  const oldEastOutside = LatLng(-33.925, 18.435);

  const freshWest = LatLng(-33.9295, 18.4185);
  const freshEast = LatLng(-33.9305, 18.4215);

  late _FakeStorage storage;
  late _FakeFirestore firestore;
  late LetterboxAreaWriteService service;

  void seed(String id, String name, List<LatLng> points,
      {LetterboxSuburbStatus status = LetterboxSuburbStatus.inProgress}) {
    storage.files[id] =
        LetterboxCodec.encode(suburbId: id, suburbName: name, points: points);
    firestore.docs[id] = LetterboxSuburb(
      suburbId: id,
      suburbName: name,
      count: points.length,
      status: status,
      seededCount: points.length,
      storagePath: LetterboxStorageService.pathFor(id),
      bounds: LetterboxBounds.fromPoints(points),
      formatVersion: LetterboxCodec.formatVersion,
    );
  }

  setUp(() {
    storage = _FakeStorage();
    firestore = _FakeFirestore();
    service = LetterboxAreaWriteService(
      suburbData: _FakeSuburbData([west, east]),
      firestore: firestore,
      storage: storage,
    );
    seed('west', 'Westville', [oldWestInside, oldWestOutside]);
    seed('east', 'Eastville', [oldEastInside, oldEastOutside]);
  });

  group('plan', () {
    test('sends each fresh point to the suburb that contains it', () async {
      final plan = await service.plan(
        area: area,
        fresh: const [freshWest, freshEast],
      );

      final byId = {for (final s in plan.affected) s.suburbId: s};
      expect(byId['west']!.incoming, [freshWest]);
      expect(byId['east']!.incoming, [freshEast]);
    });

    test('each suburb loses only its own letterboxes inside the area',
        () async {
      final plan = await service.plan(
        area: area,
        fresh: const [freshWest, freshEast],
      );

      final byId = {for (final s in plan.affected) s.suburbId: s};
      expect(byId['west']!.removeCount, 1);
      expect(byId['west']!.kept, [oldWestOutside]);
      expect(byId['east']!.removeCount, 1);
      expect(byId['east']!.kept, [oldEastOutside]);
    });

    test('writes nothing — a plan is a question, not a change', () async {
      await service.plan(area: area, fresh: const [freshWest]);

      expect(storage.pointsOf('west'), [oldWestInside, oldWestOutside]);
      expect(firestore.docs['west']!.count, 2);
    });

    test('fresh points outside the area are ignored', () async {
      const farAway = LatLng(-33.90, 18.50);
      final plan =
          await service.plan(area: area, fresh: const [freshWest, farAway]);

      expect(plan.totalAdded, 1);
      expect(plan.unplacedFresh, 0,
          reason: 'a point outside the area was never in play at all');
    });

    test('counts fresh points the suburb layer cannot hold', () async {
      // An area hanging off the southern edge of Westville: half of it is over
      // ground no suburb boundary covers, so half the survey has nowhere to be
      // stored. The operator has to be told, not quietly given a short count.
      final overhang = [
        const LatLng(-33.945, 18.405),
        const LatLng(-33.945, 18.410),
        const LatLng(-33.935, 18.410),
        const LatLng(-33.935, 18.405),
      ];
      final plan = await service.plan(
        area: overhang,
        fresh: const [
          LatLng(-33.938, 18.407), // inside Westville
          LatLng(-33.942, 18.407), // south of every boundary
        ],
      );

      expect(plan.suburbs.map((s) => s.suburbId), contains('west'));
      expect(plan.totalAdded, 1);
      expect(plan.unplacedFresh, 1);
    });

    test('an area over ground no suburb covers plans nothing', () async {
      final plan = await service.plan(
        area: box(-33.90, 18.50, 0.01),
        fresh: const [LatLng(-33.895, 18.505)],
      );

      expect(plan.suburbs, isEmpty);
      expect(plan.hasChanges, isFalse);
    });

    test('an in-memory override outranks the stored payload', () async {
      const unsaved = LatLng(-33.9299, 18.4165);
      final plan = await service.plan(
        area: area,
        fresh: const [freshWest],
        existingOverrides: const {
          'west': [unsaved, oldWestOutside]
        },
      );

      final westPlan = plan.affected.firstWhere((s) => s.suburbId == 'west');
      expect(westPlan.existing, [unsaved, oldWestOutside]);
      expect(westPlan.kept, [oldWestOutside]);
    });

    test('a suburb whose payload will not load is flagged, not emptied',
        () async {
      storage.unreadable.add('east');
      final plan = await service.plan(
        area: area,
        fresh: const [freshWest, freshEast],
      );

      expect(plan.unreadable.map((s) => s.suburbId), ['east']);
      expect(plan.affected.map((s) => s.suburbId), ['west']);
      expect(plan.unplacedFresh, 0,
          reason: 'the east point had a home; we just could not open it');
    });
  });

  group('apply', () {
    test('writes the replacement to every affected suburb', () async {
      final plan =
          await service.plan(area: area, fresh: const [freshWest, freshEast]);
      final result = await service.apply(plan);

      expect(result.totalRemoved, 2);
      expect(result.totalAdded, 2);
      expect(storage.pointsOf('west'), [oldWestOutside, freshWest]);
      expect(storage.pointsOf('east'), [oldEastOutside, freshEast]);
      expect(firestore.docs['west']!.count, 2);
      expect(firestore.docs['east']!.count, 2);
    });

    test('leaves an unreadable suburb exactly as it was', () async {
      storage.unreadable.add('east');
      final before = storage.files['east'];

      final plan =
          await service.plan(area: area, fresh: const [freshWest, freshEast]);
      await service.apply(plan);

      expect(storage.files['east'], same(before));
      expect(firestore.docs['east']!.count, 2);
    });

    test('a verified suburb stays verified', () async {
      seed('west', 'Westville', [oldWestInside, oldWestOutside],
          status: LetterboxSuburbStatus.verified);

      final plan = await service.plan(area: area, fresh: const [freshWest]);
      final result = await service.apply(plan);

      expect(plan.verifiedAffected.map((s) => s.suburbId), ['west'],
          reason: 'east is affected too, but was never verified');
      expect(firestore.docs['west']!.status, LetterboxSuburbStatus.verified);
      expect(
          result.succeeded.firstWhere((o) => o.suburbId == 'west').wasVerified,
          isTrue);
    });

    test('a failed write is reported and does not sink the others', () async {
      storage.unwritable.add('east');

      final plan =
          await service.plan(area: area, fresh: const [freshWest, freshEast]);
      final result = await service.apply(plan);

      expect(result.failures.map((o) => o.suburbId), ['east']);
      expect(result.touchedSuburbIds, ['west']);
      expect(storage.pointsOf('west'), [oldWestOutside, freshWest]);
      expect(result.summary, contains('Failed: Eastville'));
    });

    test('a suburb the area only clips is not written at all', () async {
      // An area entirely within the west suburb: east overlaps the bounding
      // box but holds nothing inside the polygon.
      final westOnly = box(-33.934, 18.404, 0.004);
      final before = storage.files['east'];

      final plan = await service
          .plan(area: westOnly, fresh: const [LatLng(-33.9325, 18.4055)]);
      final result = await service.apply(plan);

      expect(result.touchedSuburbIds, ['west']);
      expect(storage.files['east'], same(before));
    });
  });

  group('undo', () {
    test('restores the exact points and count that were there before',
        () async {
      final plan =
          await service.plan(area: area, fresh: const [freshWest, freshEast]);
      final result = await service.apply(plan);

      await service.restore(result.undo!);

      expect(storage.pointsOf('west'), [oldWestInside, oldWestOutside]);
      expect(storage.pointsOf('east'), [oldEastInside, oldEastOutside]);
      expect(firestore.docs['west']!.count, 2);
    });

    test(
        'a suburb that stays verified through a write is still verified '
        'after the undo', () async {
      seed('west', 'Westville', [oldWestInside, oldWestOutside],
          status: LetterboxSuburbStatus.verified);

      final plan = await service.plan(area: area, fresh: const [freshWest]);
      final result = await service.apply(plan);
      await service.restore(result.undo!);

      expect(firestore.docs['west']!.status, LetterboxSuburbStatus.verified);
    });

    test('removes a suburb the write created from nothing', () async {
      storage.files.remove('west');
      firestore.docs.remove('west');

      final plan = await service.plan(area: area, fresh: const [freshWest]);
      final result = await service.apply(plan);
      expect(firestore.docs.containsKey('west'), isTrue);

      await service.restore(result.undo!);

      expect(firestore.docs.containsKey('west'), isFalse,
          reason: 'an undo must not leave a curated-to-nothing suburb behind');
      expect(storage.files.containsKey('west'), isFalse);
    });
  });

  group('TELetterboxWriteProvider.positionsOf', () {
    test(
        'drops waypoints with no coordinates rather than placing them at '
        'null island', () {
      final points = TELetterboxWriteProvider.positionsOf([
        Wpt(lat: -33.93, lon: 18.41),
        Wpt(lat: null, lon: 18.41),
        Wpt(lat: -33.93, lon: null),
        // `Wpt` defaults both coordinates to 0.0, so a <wpt> element that
        // carries no position parses as null island, not as null.
        Wpt(),
      ]);

      expect(points, [const LatLng(-33.93, 18.41)]);
    });
  });
}
