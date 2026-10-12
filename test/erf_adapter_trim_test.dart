import 'package:clmschedule/erf_property/adapters/erf_property_adapter.dart';
import 'package:clmschedule/erf_property/models/erf_property.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A parcel at a given position, with a square boundary around it.
ErfProperty _at(int n, double lat, double lng) => ErfProperty(
      id: 'p$n',
      erfNumber: n,
      tagValue: '$n',
      lpiCode: 'lpi$n',
      majRegion: 'CAPE',
      majCode: 'C0160000',
      minRegion: 'CONSTANTIA',
      minCode: 'C0160011',
      province: 'WESTERN CAPE',
      area: 500,
      centroid: LatLng(lat, lng),
      polygon: [
        LatLng(lat, lng),
        LatLng(lat + 1e-4, lng),
        LatLng(lat + 1e-4, lng + 1e-4),
        LatLng(lat, lng + 1e-4),
      ],
    );

void main() {
  group('ErfPropertyAdapter context trimming', () {
    test('draws every parcel of a normal suburb', () async {
      // Constantia is about 10 000 parcels and must render whole.
      final parcels = [
        for (var i = 0; i < 10139; i++) _at(i, -34.0 + i * 1e-5, 18.4),
      ];

      final adapter = ErfPropertyAdapter(preloadedProperties: parcels);
      final map = await adapter.load();

      expect(adapter.truncatedContext, 0);
      expect(map.layers.single.polygons, hasLength(10139));
    });

    test('keeps a spatially coherent block when it must trim', () async {
      // Interleave two distant clusters so that taking a prefix of the list
      // would straddle both — the bug that made the map look patchy.
      final parcels = <ErfProperty>[];
      for (var i = 0; i < 1000; i++) {
        parcels.add(_at(i, -34.0 + i * 1e-5, 18.4)); // near cluster
        parcels.add(_at(10000 + i, -33.0 + i * 1e-5, 19.4)); // far cluster
      }

      final adapter = ErfPropertyAdapter(
        preloadedProperties: parcels,
        selectedProperties: [_at(99999, -34.0, 18.4)],
        maxContextPolygons: 1000,
      );
      final map = await adapter.load();

      expect(adapter.truncatedContext, 1000);

      final drawn = map.layers.firstWhere((l) => l.id == 'erf_context_layer');
      // Every kept parcel should come from the cluster near the selection.
      expect(
        drawn.polygons.every((p) => p.points.first.longitude < 19.0),
        isTrue,
        reason: 'trimming must keep the nearest block, not a list prefix',
      );
    });

    test('trims around the parcels themselves when nothing is selected',
        () async {
      final parcels = <ErfProperty>[];
      for (var i = 0; i < 600; i++) {
        parcels.add(_at(i, -34.0 + i * 1e-5, 18.4));
      }
      // One far outlier that should be the first thing dropped.
      parcels.add(_at(9999, -30.0, 22.0));

      final adapter = ErfPropertyAdapter(
        preloadedProperties: parcels,
        maxContextPolygons: 600,
      );
      final map = await adapter.load();

      expect(adapter.truncatedContext, 1);
      final drawn = map.layers.single;
      expect(drawn.polygons.any((p) => p.points.first.latitude > -31), isFalse,
          reason: 'the outlier is furthest from the centre and goes first');
    });

    test('separates selected parcels onto their own layer', () async {
      final adapter = ErfPropertyAdapter(
        preloadedProperties: [_at(1, -34.0, 18.4), _at(2, -34.001, 18.4)],
        selectedProperties: [_at(1, -34.0, 18.4)],
      );
      final map = await adapter.load();

      expect(map.layers.map((l) => l.id),
          containsAll(['erf_context_layer', 'erf_selected_layer']));
      // The selected parcel must not also appear in the context layer.
      final context = map.layers.firstWhere((l) => l.id == 'erf_context_layer');
      expect(context.polygons, hasLength(1));
    });
  });
}
