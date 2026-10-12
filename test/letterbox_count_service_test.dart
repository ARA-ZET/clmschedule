import 'package:clmschedule/letterbox/models/letterbox_suburb.dart';
import 'package:clmschedule/letterbox/services/letterbox_codec.dart';
import 'package:clmschedule/letterbox/services/letterbox_count_service.dart';
import 'package:clmschedule/letterbox/services/letterbox_firestore_service.dart';
import 'package:clmschedule/letterbox/services/letterbox_storage_service.dart';
import 'package:clmschedule/letterbox/utils/letterbox_spatial_index.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

// ── Fakes ──────────────────────────────────────────────────────────────
// Both services resolve their Firebase handle lazily, so overriding every
// method used here keeps the tests free of an initialised Firebase app.

class _FakeFirestore extends LetterboxFirestoreService {
  final List<LetterboxSuburb> suburbs;
  int getAllCalls = 0;

  _FakeFirestore(this.suburbs);

  @override
  Future<List<LetterboxSuburb>> getAll() async {
    getAllCalls++;
    return suburbs;
  }
}

class _FakeStorage extends LetterboxStorageService {
  final Map<String, Uint8List> files;
  final List<String> loads = [];

  _FakeStorage(this.files);

  @override
  Future<Uint8List?> load(String suburbId) async {
    loads.add(suburbId);
    return files[suburbId];
  }
}

Uint8List _payload(String id, List<LatLng> points) =>
    LetterboxCodec.encode(suburbId: id, suburbName: id, points: points);

LetterboxSuburb _meta(
  String id,
  List<LatLng> points, {
  LetterboxSuburbStatus status = LetterboxSuburbStatus.verified,
}) {
  return LetterboxSuburb(
    suburbId: id,
    suburbName: id,
    count: points.length,
    status: status,
    storagePath: LetterboxStorageService.pathFor(id),
    storageBytes: 1,
    bounds: LetterboxBounds.fromPoints(points),
    formatVersion: LetterboxCodec.formatVersion,
  );
}

/// A closed square, counter-clockwise.
List<LatLng> _square({
  required double minLat,
  required double minLng,
  required double size,
}) {
  return [
    LatLng(minLat, minLng),
    LatLng(minLat, minLng + size),
    LatLng(minLat + size, minLng + size),
    LatLng(minLat + size, minLng),
  ];
}

void main() {
  group('LetterboxSpatialIndex', () {
    test('reports its own bounds and count', () {
      final index = LetterboxSpatialIndex()
        ..insertAll(const [
          LatLng(-33.92, 18.42),
          LatLng(-33.90, 18.45),
        ]);

      expect(index.count, 2);
      expect(index.bounds!.minLat, closeTo(-33.92, 1e-9));
      expect(index.bounds!.maxLng, closeTo(18.45, 1e-9));
    });

    test('candidatesIn returns every point in the overlapping cells', () {
      final index = LetterboxSpatialIndex()
        ..insertAll(const [
          LatLng(-33.9200, 18.4200), // inside
          LatLng(-33.9210, 18.4210), // inside
          LatLng(-34.5000, 19.0000), // far away
        ]);

      final near = index.candidatesIn(const LetterboxBounds(
        minLat: -33.9250,
        minLng: 18.4150,
        maxLat: -33.9150,
        maxLng: 18.4250,
      ));

      expect(near, hasLength(2));
    });

    test('handles negative rows and columns without key collisions', () {
      // Southern and western hemispheres — the case that makes bit-shifted
      // cell keys unsafe.
      final index = LetterboxSpatialIndex()
        ..insertAll(const [
          LatLng(-33.92, -18.42),
          LatLng(33.92, 18.42),
          LatLng(-33.92, 18.42),
          LatLng(33.92, -18.42),
        ]);

      expect(index.count, 4);
      for (final p in index.all()) {
        final found = index.candidatesIn(LetterboxBounds(
          minLat: p.latitude - 0.001,
          minLng: p.longitude - 0.001,
          maxLat: p.latitude + 0.001,
          maxLng: p.longitude + 0.001,
        ));
        expect(found, contains(p));
      }
    });
  });

  group('LetterboxCountService.countIn', () {
    test('counts points inside and excludes points outside', () async {
      // Square spans lat [-33.9300, -33.9220], lng [18.4200, 18.4280].
      final points = const [
        LatLng(-33.9250, 18.4250), // inside
        LatLng(-33.9260, 18.4260), // inside
        LatLng(-33.9290, 18.4270), // inside, near the corner
        LatLng(-33.9290, 18.4290), // outside — east of the square
        LatLng(-33.9400, 18.4400), // outside
        LatLng(-33.9000, 18.4000), // outside
      ];

      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('a', points)]),
        storage: _FakeStorage({'a': _payload('a', points)}),
      );

      final result = await service.countIn(_square(
        minLat: -33.9300,
        minLng: 18.4200,
        size: 0.0080,
      ));

      expect(result.count, 3);
      expect(result.suburbIds, ['a']);
      expect(result.isTrusted, isTrue);
    });

    test('counts a letterbox on a shared border exactly once', () async {
      // Two work areas meeting along lng 18.4300. A letterbox sitting exactly
      // on the seam must land in one area or the other — never both (which
      // would over-quote) and never neither (which would under-quote).
      final onSeam = const [LatLng(-33.9250, 18.4300)];

      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('a', onSeam)]),
        storage: _FakeStorage({'a': _payload('a', onSeam)}),
      );

      // Literal coordinates, not arithmetic: the shared edge must be
      // bit-identical in both polygons. That is the realistic case, because
      // adjacent work areas are drawn by snapping to the same vertices.
      const west = [
        LatLng(-33.9300, 18.4200),
        LatLng(-33.9300, 18.4300),
        LatLng(-33.9200, 18.4300),
        LatLng(-33.9200, 18.4200),
      ];
      const east = [
        LatLng(-33.9300, 18.4300),
        LatLng(-33.9300, 18.4400),
        LatLng(-33.9200, 18.4400),
        LatLng(-33.9200, 18.4300),
      ];

      final westCount = (await service.countIn(west)).count;
      final eastCount = (await service.countIn(east)).count;

      expect(westCount + eastCount, 1,
          reason: 'a border letterbox must be counted once across two '
              'adjacent work areas, not twice and not zero times');
    });

    test('returns empty for a polygon still being drawn', () async {
      final service = LetterboxCountService(
        firestore: _FakeFirestore(const []),
        storage: _FakeStorage(const {}),
      );

      expect((await service.countIn(const [])).count, 0);
      expect(
        (await service
                .countIn(const [LatLng(-33.9, 18.4), LatLng(-33.8, 18.5)]))
            .count,
        0,
      );
    });

    test('sums across suburbs and flags the unverified ones', () async {
      final verified = const [LatLng(-33.9250, 18.4250)];
      final draft = const [LatLng(-33.9260, 18.4600)];

      final service = LetterboxCountService(
        firestore: _FakeFirestore([
          _meta('verified', verified),
          _meta('draft', draft, status: LetterboxSuburbStatus.seeded),
        ]),
        storage: _FakeStorage({
          'verified': _payload('verified', verified),
          'draft': _payload('draft', draft),
        }),
      );

      final result = await service.countIn(_square(
        minLat: -33.9300,
        minLng: 18.4200,
        size: 0.0500,
      ));

      expect(result.count, 2);
      expect(result.unverifiedSuburbs, ['draft']);
      // The headline number is right, but it must not be presented as fact.
      expect(result.isTrusted, isFalse);
    });

    test('skips suburbs whose bounds cannot overlap, without downloading them',
        () async {
      final near = const [LatLng(-33.9250, 18.4250)];
      final far = const [LatLng(-30.0000, 25.0000)];

      final storage = _FakeStorage({
        'near': _payload('near', near),
        'far': _payload('far', far),
      });

      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('near', near), _meta('far', far)]),
        storage: storage,
      );

      final result = await service.countIn(_square(
        minLat: -33.9300,
        minLng: 18.4200,
        size: 0.0100,
      ));

      expect(result.count, 1);
      // The whole point of storing bounds on the metadata document.
      expect(storage.loads, ['near']);
    });

    test('caches a suburb payload across repeated counts', () async {
      final points = const [LatLng(-33.9250, 18.4250)];
      final storage = _FakeStorage({'a': _payload('a', points)});
      final firestore = _FakeFirestore([_meta('a', points)]);

      final service =
          LetterboxCountService(firestore: firestore, storage: storage);

      final polygon = _square(minLat: -33.9300, minLng: 18.4200, size: 0.0100);
      for (var i = 0; i < 5; i++) {
        await service.countIn(polygon);
      }

      // Redrawing a polygon must not refetch — this is what makes it safe to
      // recount on every tick while drawing.
      expect(storage.loads, ['a']);
      expect(firestore.getAllCalls, 1);
    });

    test('invalidate forces a refetch after curation', () async {
      final before = const [LatLng(-33.9250, 18.4250)];
      final after = const [
        LatLng(-33.9250, 18.4250),
        LatLng(-33.9255, 18.4255),
      ];

      final storage = _FakeStorage({'a': _payload('a', before)});
      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('a', after)]),
        storage: storage,
      );

      final polygon = _square(minLat: -33.9300, minLng: 18.4200, size: 0.0100);
      expect((await service.countIn(polygon)).count, 1);

      storage.files['a'] = _payload('a', after);
      service.invalidate('a');

      expect((await service.countIn(polygon)).count, 2);
    });

    test('countInEach loads each suburb once for the whole batch', () async {
      final points = [
        for (var i = 0; i < 20; i++)
          LatLng(-33.9250 + i * 0.0002, 18.4250 + i * 0.0002),
      ];

      final storage = _FakeStorage({'a': _payload('a', points)});
      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('a', points)]),
        storage: storage,
      );

      final polygons = [
        for (var i = 0; i < 6; i++)
          _square(
            minLat: -33.9300 + i * 0.0010,
            minLng: 18.4200 + i * 0.0010,
            size: 0.0020,
          ),
      ];

      final results = await service.countInEach(polygons);

      expect(results, hasLength(6));
      // Tiering many work areas over one suburb downloads it once, not once
      // per polygon.
      expect(storage.loads, ['a']);
    });

    test('a missing payload is not retried on every query', () async {
      final points = const [LatLng(-33.9250, 18.4250)];
      final storage = _FakeStorage(const {}); // nothing uploaded yet
      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('a', points)]),
        storage: storage,
      );

      final polygon = _square(minLat: -33.9300, minLng: 18.4200, size: 0.0100);
      await service.countIn(polygon);
      await service.countIn(polygon);
      await service.countIn(polygon);

      expect(storage.loads, ['a']);
    });

    test('ignores suburbs that have no payload written yet', () async {
      final points = const [LatLng(-33.9250, 18.4250)];
      final storage = _FakeStorage({'a': _payload('a', points)});

      final service = LetterboxCountService(
        firestore: _FakeFirestore([
          LetterboxSuburb(
            suburbId: 'a',
            suburbName: 'a',
            status: LetterboxSuburbStatus.unseeded,
            bounds: LetterboxBounds.fromPoints(points),
          ),
        ]),
        storage: storage,
      );

      final result = await service
          .countIn(_square(minLat: -33.9300, minLng: 18.4200, size: 0.0100));

      expect(result.count, 0);
      expect(storage.loads, isEmpty);
    });
  });
  group('LetterboxCountService.countUnion — billing correctness', () {
    // Two adjacent 0.01-degree squares, sharing the edge at lng 18.4300.
    final west = _square(minLat: -33.9300, minLng: 18.4200, size: 0.0100);
    final east = _square(minLat: -33.9300, minLng: 18.4300, size: 0.0100);

    test('a plain union with no overlap sums the two areas exactly', () async {
      final points = const [
        LatLng(-33.9250, 18.4250), // west
        LatLng(-33.9260, 18.4260), // west
        LatLng(-33.9250, 18.4350), // east
      ];
      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('a', points)]),
        storage: _FakeStorage({'a': _payload('a', points)}),
      );

      final result = await service.countUnion([west, east]);

      expect(result.count, 3);
      expect(result.hasOverlaps, isFalse);
      expect(result.gapCapturedCount, 0);
    });

    test('overlapping polygons count each letterbox once, not twice', () async {
      // west spans lat [-33.9300,-33.9200], lng [18.4200,18.4300].
      // overlapping spans lat [-33.9260,-33.9240], lng [18.4260,18.4340] —
      // its western half sits inside west, its eastern half sticks out.
      final overlapping =
          _square(minLat: -33.9260, minLng: 18.4260, size: 0.0020);
      const inOverlap = LatLng(-33.9250, 18.4270); // inside BOTH squares
      const inWestOnly = LatLng(-33.9250, 18.4210);

      final service = LetterboxCountService(
        firestore: _FakeFirestore([
          _meta('a', const [inOverlap, inWestOnly])
        ]),
        storage: _FakeStorage({
          'a': _payload('a', const [inOverlap, inWestOnly])
        }),
      );

      final resultViaCountIn = [
        (await service.countIn(west)).count,
        (await service.countIn(overlapping)).count,
      ];
      expect(resultViaCountIn.reduce((a, b) => a + b), 3,
          reason: 'summing individually double-counts the shared letterbox — '
              'the very mistake countUnion exists to avoid');

      final result = await service.countUnion([west, overlapping]);

      expect(result.count, 2,
          reason: 'the shared letterbox must be counted once');
      expect(result.hasOverlaps, isTrue);
      expect(result.overlaps, [const PolygonOverlap(0, 1)]);
    });

    test('adjacent snapped polygons are not flagged as overlapping', () async {
      final service = LetterboxCountService(
        firestore: _FakeFirestore(const []),
        storage: _FakeStorage(const {}),
      );

      final result = await service.countUnion([west, east]);

      expect(result.hasOverlaps, isFalse,
          reason: 'sharing a drawn edge is not covering the same ground');
    });

    test('a letterbox in the gap between two sloppily-drawn areas is not lost',
        () async {
      // The user's stated worry: two polygons meant to be adjacent, but drawn
      // independently, can leave a small gap. A letterbox genuinely being
      // distributed to inside that gap must still be billed.
      //
      // Literal edges (not computed by addition) so the gap width is exact:
      // west's east edge at 18.42999, east's west edge at 18.43001 — a gap of
      // 0.00002 degrees, ~1.8 m at this latitude, split evenly either side of
      // the midpoint. Well within the module's default 3 m tolerance.
      final gappyWest = [
        const LatLng(-33.9300, 18.4200),
        const LatLng(-33.9300, 18.42999),
        const LatLng(-33.9200, 18.42999),
        const LatLng(-33.9200, 18.4200),
      ];
      final gappyEast = [
        const LatLng(-33.9300, 18.43001),
        const LatLng(-33.9300, 18.4400),
        const LatLng(-33.9200, 18.4400),
        const LatLng(-33.9200, 18.43001),
      ];
      const inTheGap = LatLng(-33.9250, 18.43000);

      final service = LetterboxCountService(
        firestore: _FakeFirestore([
          _meta('a', const [inTheGap])
        ]),
        storage: _FakeStorage({
          'a': _payload('a', const [inTheGap])
        }),
      );

      final missed = await service.countIn(gappyWest);
      expect(missed.count, 0,
          reason: 'sanity check: the point really does fall in the gap');

      final result = await service.countUnion([gappyWest, gappyEast]);

      expect(result.count, 1, reason: 'the gap must not swallow a real drop');
      expect(result.gapCapturedCount, 1);
    });

    test('gap tolerance does not reach across a genuine gap', () async {
      // A point 30 m past the edge is not a drawing slip — it is outside the
      // quoted area, and must stay excluded.
      final farOutside =
          _square(minLat: -33.9300, minLng: 18.4200, size: 0.0100);
      const wellClear = LatLng(-33.9250, 18.4600);

      final service = LetterboxCountService(
        firestore: _FakeFirestore([
          _meta('a', const [wellClear])
        ]),
        storage: _FakeStorage({
          'a': _payload('a', const [wellClear])
        }),
      );

      final result = await service.countUnion([farOutside]);

      expect(result.count, 0);
      expect(result.gapCapturedCount, 0);
    });

    test('gapToleranceMetres: 0 disables the bridge entirely', () async {
      final gappyWest = [
        const LatLng(-33.9300, 18.4200),
        const LatLng(-33.9300, 18.42999),
        const LatLng(-33.9200, 18.42999),
        const LatLng(-33.9200, 18.4200),
      ];
      final gappyEast = [
        const LatLng(-33.9300, 18.43001),
        const LatLng(-33.9300, 18.4400),
        const LatLng(-33.9200, 18.4400),
        const LatLng(-33.9200, 18.43001),
      ];
      const inTheGap = LatLng(-33.9250, 18.43000);

      final service = LetterboxCountService(
        firestore: _FakeFirestore([
          _meta('a', const [inTheGap])
        ]),
        storage: _FakeStorage({
          'a': _payload('a', const [inTheGap])
        }),
      );

      final result = await service
          .countUnion([gappyWest, gappyEast], gapToleranceMetres: 0);

      expect(result.count, 0);
      expect(result.gapCapturedCount, 0);
    });

    test('an unverified suburb in the union is flagged, not hidden', () async {
      final unionArea = [west, east];
      final points = const [LatLng(-33.9250, 18.4250)];

      final service = LetterboxCountService(
        firestore: _FakeFirestore([
          _meta('a', points, status: LetterboxSuburbStatus.seeded),
        ]),
        storage: _FakeStorage({'a': _payload('a', points)}),
      );

      final result = await service.countUnion(unionArea);

      expect(result.count, 1);
      expect(result.isTrusted, isFalse);
      expect(result.unverifiedSuburbs, ['a']);
    });

    test('a degenerate polygon in the list is ignored, not fatal', () async {
      final service = LetterboxCountService(
        firestore: _FakeFirestore(const []),
        storage: _FakeStorage(const {}),
      );

      final result = await service.countUnion([
        west,
        const [LatLng(-33.9, 18.4)], // only one point — not a polygon
      ]);

      expect(result.count, 0);
      expect(result.hasOverlaps, isFalse);
    });

    test('an empty list returns the empty result', () async {
      final service = LetterboxCountService(
        firestore: _FakeFirestore(const []),
        storage: _FakeStorage(const {}),
      );

      final result = await service.countUnion(const []);
      expect(result.count, 0);
    });

    test('breakdown covers the whole union, not per polygon', () async {
      // A block of 6 boxes straddling the boundary by under a metre either
      // side: 3 sit inside west, 3 inside east, but all 6 are within the 5 m
      // cluster radius of each other. It must read as ONE block of 6 once the
      // areas are considered together, even though neither polygon's own
      // count ever sees more than 3 of them (a cluster of 3 is below
      // minBlockBoxes, so counted in isolation each half reads as houses).
      final onSeam = [
        for (var i = 0; i < 3; i++)
          LatLng(-33.9250 + i * 0.0000005, 18.43 - 0.000003),
        for (var i = 0; i < 3; i++)
          LatLng(-33.9250 + i * 0.0000005, 18.43 + 0.000003),
      ];
      final service = LetterboxCountService(
        firestore: _FakeFirestore([_meta('a', onSeam)]),
        storage: _FakeStorage({'a': _payload('a', onSeam)}),
      );

      expect((await service.countIn(west)).count, lessThan(6),
          reason: 'sanity check: no single polygon sees the whole block');

      final result = await service.countUnion([west, east]);

      expect(result.count, 6);
      expect(result.breakdown.apartmentBlocks, 1);
      expect(result.breakdown.apartmentBoxes, 6);
    });
  });
}
