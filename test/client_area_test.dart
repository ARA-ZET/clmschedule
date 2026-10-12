// The Client Maps library: the model's storage round trip, the survey upsert
// that decides create-versus-refresh, and the map-editor adapter's save diff.
//
// The upsert rule is the one worth pinning: a re-survey of the same ground has
// to land on the same client area, or the library fills up with two copies of
// every area quoting two different numbers.
import 'package:clmschedule/models/client_area.dart';
import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/services/client_area_service.dart';
import 'package:clmschedule/shareable_maps/adapters/client_area_adapter.dart';
import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/shareable_maps/models/shareable_map.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// In-memory stand-in. Only the storage primitives are faked — the upsert and
/// revert logic under test is the real implementation.
class _FakeClientAreaService extends ClientAreaService {
  final Map<String, ClientArea> docs = {};
  int _next = 0;

  @override
  Future<List<ClientArea>> fetchAllOnce() async =>
      docs.values.toList(growable: false);

  @override
  Future<ClientArea?> get(String id) async => docs[id];

  @override
  Future<String> add(ClientArea area) async {
    final id = 'area_${_next++}';
    docs[id] = area.copyWith(id: id);
    return id;
  }

  @override
  Future<void> save(ClientArea area) async {
    docs[area.id] = area;
  }

  @override
  Future<void> delete(String id) async {
    docs.remove(id);
  }

  @override
  Future<ClientArea?> findForSurvey({
    String? sourcePolygonId,
    required String name,
  }) async {
    if (sourcePolygonId != null && sourcePolygonId.isNotEmpty) {
      for (final a in docs.values) {
        if (a.sourcePolygonId == sourcePolygonId) return a;
      }
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    for (final a in docs.values) {
      if (a.name == trimmed) return a;
    }
    return null;
  }
}

List<LatLng> box(double minLat, double minLng, double size) => [
      LatLng(minLat, minLng),
      LatLng(minLat, minLng + size),
      LatLng(minLat + size, minLng + size),
      LatLng(minLat + size, minLng),
    ];

void main() {
  final points = box(-33.94, 18.40, 0.02);
  const split =
      LetterBoxSplit(houses: 812, apartmentBoxes: 388, apartmentBlocks: 24);

  group('ClientArea', () {
    test('survives a round trip through storage, split and all', () {
      final surveyed = DateTime(2026, 9, 8, 14, 30);
      final area = ClientArea(
        id: 'a1',
        name: 'Pinelands North',
        client: 'Checkers',
        description: 'Round 3',
        polygonPoints: points,
        color: Colors.teal,
        letterBoxEstimate: 1200,
        letterBoxSplit: split,
        sourcePolygonId: 'poly-7',
        surveyedAt: surveyed,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: surveyed,
      );

      final back = ClientArea.fromMap(area.toMap());

      expect(back.id, 'a1');
      expect(back.name, 'Pinelands North');
      expect(back.client, 'Checkers');
      expect(back.description, 'Round 3');
      expect(back.polygonPoints, points);
      // A stored colour comes back as a plain Color, not the MaterialColor
      // it was written from — the same 32-bit value either way.
      expect(back.color.toARGB32(), Colors.teal.toARGB32());
      expect(back.letterBoxEstimate, 1200);
      expect(back.letterBoxSplit, split);
      expect(back.sourcePolygonId, 'poly-7');
      expect(back.surveyedAt, surveyed);
      expect(back.isSurveyed, isTrue);
    });

    test('an area with no split reads back as never computed, not as zero', () {
      final area = ClientArea(
        id: 'a1',
        name: 'Hand drawn',
        polygonPoints: points,
        letterBoxEstimate: 400,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      );

      expect(ClientArea.fromMap(area.toMap()).letterBoxSplit, isNull);
      expect(ClientArea.fromMap(area.toMap()).isSurveyed, isFalse);
    });

    test('carries its estimate and split onto the editor polygon', () {
      final polygon = ClientArea(
        id: 'a1',
        name: 'Pinelands North',
        polygonPoints: points,
        letterBoxEstimate: 1200,
        letterBoxSplit: split,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ).toCustomPolygon();

      expect(polygon.id, 'a1');
      expect(polygon.letterBoxEstimate, 1200);
      expect(polygon.letterBoxSplit, split);
    });
  });

  group('upsertFromSurvey', () {
    late _FakeClientAreaService service;

    setUp(() => service = _FakeClientAreaService());

    test('files a new area when nothing matches', () async {
      final result = await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1200,
        letterBoxSplit: split,
        client: 'Checkers',
        sourcePolygonId: 'poly-7',
      );

      expect(result.wasCreated, isTrue);
      expect(service.docs, hasLength(1));
      expect(result.saved.letterBoxSplit, split);
      expect(result.saved.client, 'Checkers');
      expect(result.saved.isSurveyed, isTrue);
    });

    test('a re-survey refreshes the same area instead of filing a second',
        () async {
      await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1200,
        letterBoxSplit: split,
        sourcePolygonId: 'poly-7',
      );

      final again = await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1310,
        letterBoxSplit: const LetterBoxSplit(
            houses: 900, apartmentBoxes: 410, apartmentBlocks: 26),
        sourcePolygonId: 'poly-7',
      );

      expect(again.wasCreated, isFalse);
      expect(service.docs, hasLength(1));
      expect(service.docs.values.single.letterBoxEstimate, 1310);
      expect(service.docs.values.single.letterBoxSplit!.houses, 900);
    });

    test('a renamed polygon still refreshes its own area', () async {
      await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1200,
        sourcePolygonId: 'poly-7',
      );

      await service.upsertFromSurvey(
        name: 'Pinelands North (Nov)',
        points: points,
        letterBoxEstimate: 1250,
        sourcePolygonId: 'poly-7',
      );

      expect(service.docs, hasLength(1));
      expect(service.docs.values.single.name, 'Pinelands North (Nov)');
    });

    test('a nudged outline still refreshes the same area, not a second one',
        () async {
      // Work-map polygon ids are derived from name + geometry, so moving one
      // vertex changes the id for the same ground. The name is what holds.
      await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1200,
        sourcePolygonId: 'workmap_111_222',
      );

      final again = await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: box(-33.94, 18.40, 0.021),
        letterBoxEstimate: 1240,
        sourcePolygonId: 'workmap_111_999',
      );

      expect(again.wasCreated, isFalse);
      expect(service.docs, hasLength(1));
      expect(service.docs.values.single.letterBoxEstimate, 1240);
      expect(service.docs.values.single.sourcePolygonId, 'workmap_111_999');
    });

    test('the first survey adopts an area someone drew by hand', () async {
      // Drawn in the Client Maps editor, so it has no source polygon.
      await service.add(ClientArea(
        id: '',
        name: 'Pinelands North',
        client: 'Checkers',
        description: 'quoted Feb',
        polygonPoints: points,
        color: Colors.orange,
        letterBoxEstimate: 900,
        createdAt: DateTime(2026, 2, 1),
        updatedAt: DateTime(2026, 2, 1),
      ));

      final result = await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1200,
        letterBoxSplit: split,
        sourcePolygonId: 'poly-7',
      );

      expect(result.wasCreated, isFalse);
      expect(service.docs, hasLength(1));
      final saved = service.docs.values.single;
      expect(saved.letterBoxEstimate, 1200);
      expect(saved.sourcePolygonId, 'poly-7',
          reason: 'the hand-drawn area is now tied to the polygon');
      expect(saved.client, 'Checkers',
          reason: 'a survey with no client must not blank one that was set');
      expect(saved.description, 'quoted Feb');
      expect(saved.color, Colors.orange,
          reason: 'a re-survey changes the numbers, not the styling');
    });

    test('a survey that names a client overwrites the old one', () async {
      await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 900,
        client: 'Checkers',
        sourcePolygonId: 'poly-7',
      );

      await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 900,
        client: 'Pick n Pay',
        sourcePolygonId: 'poly-7',
      );

      expect(service.docs.values.single.client, 'Pick n Pay');
    });
  });

  group('revertUpsert', () {
    late _FakeClientAreaService service;

    setUp(() => service = _FakeClientAreaService());

    test('removes an area the survey created', () async {
      final result = await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1200,
        sourcePolygonId: 'poly-7',
      );

      await service.revertUpsert(result);

      expect(service.docs, isEmpty);
    });

    test('puts back the numbers a survey replaced', () async {
      await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 900,
        letterBoxSplit: const LetterBoxSplit(
            houses: 700, apartmentBoxes: 200, apartmentBlocks: 10),
        sourcePolygonId: 'poly-7',
      );

      final second = await service.upsertFromSurvey(
        name: 'Pinelands North',
        points: points,
        letterBoxEstimate: 1310,
        letterBoxSplit: split,
        sourcePolygonId: 'poly-7',
      );

      await service.revertUpsert(second);

      expect(service.docs, hasLength(1));
      final restored = service.docs.values.single;
      expect(restored.letterBoxEstimate, 900);
      expect(restored.letterBoxSplit!.houses, 700);
    });
  });

  group('ClientAreaCollectionAdapter', () {
    late _FakeClientAreaService service;
    late ClientAreaCollectionAdapter adapter;

    setUp(() {
      service = _FakeClientAreaService();
      adapter = ClientAreaCollectionAdapter(service: service);
    });

    Future<void> seed() async {
      await service.add(ClientArea(
        id: '',
        name: 'Pinelands North',
        client: 'Checkers',
        polygonPoints: points,
        letterBoxEstimate: 1200,
        letterBoxSplit: split,
        surveyedAt: DateTime(2026, 9, 8),
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
      ));
    }

    ShareableMap withPolygons(ShareableMap map, List<CustomPolygon> polygons) {
      final now = DateTime.now();
      return ShareableMap(
        id: map.id,
        name: map.name,
        description: map.description,
        defaultCenter: map.defaultCenter,
        defaultZoom: map.defaultZoom,
        createdAt: map.createdAt,
        updatedAt: now,
        layers: [
          MapLayer(
            id: ClientAreaCollectionAdapter.layerId,
            name: 'Client Maps',
            description: '',
            order: 0,
            defaultColor: ClientArea.defaultColor,
            polygons: polygons,
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
    }

    test('loads each area as a polygon carrying its split', () async {
      await seed();
      final map = await adapter.load();

      final polygon = map.layers.single.polygons.single;
      expect(polygon.name, 'Pinelands North');
      expect(polygon.letterBoxEstimate, 1200);
      expect(polygon.letterBoxSplit, split);
      expect(adapter.clientFor(polygon.id), 'Checkers');
      expect(adapter.surveyedAtFor(polygon.id), DateTime(2026, 9, 8));
    });

    test('an edit in the map editor keeps the client and the survey date',
        () async {
      await seed();
      final map = await adapter.load();
      final polygon = map.layers.single.polygons.single;

      await adapter.save(withPolygons(
        map,
        [polygon.copyWith(name: 'Pinelands N', letterBoxEstimate: 1150)],
      ));

      final saved = service.docs.values.single;
      expect(saved.name, 'Pinelands N');
      expect(saved.letterBoxEstimate, 1150);
      expect(saved.client, 'Checkers',
          reason: 'the editor cannot carry the client, so the adapter must');
      expect(saved.surveyedAt, DateTime(2026, 9, 8),
          reason: 'redrawing an outline does not re-survey it');
    });

    test('a polygon added in the editor becomes a new area', () async {
      await seed();
      final map = await adapter.load();

      await adapter.save(withPolygons(map, [
        ...map.layers.single.polygons,
        CustomPolygon(
          name: 'Thornton',
          description: '',
          points: box(-33.90, 18.50, 0.01),
          color: Colors.green,
          letterBoxEstimate: 300,
        ),
      ]));

      expect(service.docs, hasLength(2));
      final added = service.docs.values.firstWhere((a) => a.name == 'Thornton');
      expect(added.letterBoxEstimate, 300);
      expect(added.isSurveyed, isFalse);
    });

    test('a polygon removed in the editor deletes its area', () async {
      await seed();
      final map = await adapter.load();

      await adapter.save(withPolygons(map, const []));

      expect(service.docs, isEmpty);
    });
  });
}
