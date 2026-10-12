import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/shareable_maps/models/map_point.dart';
import 'package:clmschedule/shareable_maps/models/shareable_map.dart';
import 'package:clmschedule/shareable_maps/providers/shareable_map_provider.dart';
import 'package:clmschedule/shareable_maps/utils/drawn_gpx.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

final _t = DateTime(2026, 9, 16);
const _here = LatLng(-33.92, 18.42);

MapLayer _layer(String id, {List<MapPoint> points = const []}) => MapLayer(
      id: id,
      name: 'Layer $id',
      order: 0,
      defaultColor: Colors.blue,
      points: points,
      createdAt: _t,
      updatedAt: _t,
    );

MapPoint _point(String id) => MapPoint(
      id: id,
      name: 'P $id',
      position: _here,
      color: Colors.red,
      createdAt: _t,
      updatedAt: _t,
    );

ShareableMapProvider _providerWith(List<MapLayer> layers) {
  final provider = ShareableMapProvider();
  provider.loadMap(ShareableMap(
    id: 'm',
    name: 'Map',
    layers: layers,
    defaultCenter: _here,
    createdAt: _t,
    updatedAt: _t,
  ));
  return provider;
}

List<String> _ids(List<MapLayer> layers) => layers.map((l) => l.id).toList();

void main() {
  group('empty layers', () {
    test('the sidebar hides empty saved layers by default', () {
      final p = _providerWith([
        _layer('full', points: [_point('a')]),
        _layer('empty1'),
        _layer('empty2'),
      ]);

      expect(p.hideEmptyLayers, isTrue);
      expect(_ids(p.sidebarLayers), ['full']);
      expect(p.hiddenEmptyLayerCount, 2);
    });

    test('turning the filter off lists every layer again', () {
      final p = _providerWith([
        _layer('full', points: [_point('a')]),
        _layer('empty'),
      ]);

      p.setHideEmptyLayers(false);

      expect(_ids(p.sidebarLayers), ['full', 'empty']);
      expect(p.hiddenEmptyLayerCount, 0);
    });

    test('a layer created this session stays listed while empty', () {
      final p = _providerWith([
        _layer('full', points: [_point('a')])
      ]);

      final id = p.createLayer(name: 'Fresh');

      expect(p.sidebarLayers.map((l) => l.id), contains(id));
      expect(p.hiddenEmptyLayerCount, 0,
          reason: 'a just-created layer is not "hidden"');
    });

    test('remove deletes only the empty saved layers', () {
      final p = _providerWith([
        _layer('full', points: [_point('a')]),
        _layer('empty1'),
        _layer('empty2'),
      ]);

      expect(p.removeEmptyLayers(), 2);
      expect(_ids(p.currentMap!.layers), ['full']);
      expect(p.emptyLayers, isEmpty);
      expect(p.removeEmptyLayers(), 0);
    });

    test('remove keeps a non-empty layer that shares an id with an empty one',
        () {
      // Layer ids are millisecond timestamps, so this happens for real.
      final p = _providerWith([
        _layer('same'),
        _layer('same', points: [_point('a')]),
      ]);

      expect(p.removeEmptyLayers(), 1);
      expect(p.currentMap!.layers, hasLength(1));
      expect(p.currentMap!.layers.single.points, hasLength(1));
    });

    test('removing the selected layer moves the selection to a kept one', () {
      final p = _providerWith([
        _layer('empty'),
        _layer('full', points: [_point('a')]),
      ]);
      expect(p.selectedLayer?.id, 'empty');

      p.removeEmptyLayers();

      expect(p.selectedLayer?.id, 'full');
    });

    test('cloud layers are never hidden or removed, even when empty', () {
      final p = _providerWith([_layer('empty')]);
      p.addCloudFolderLink('Distribution/2026/Sep 2026/Seeff');

      final waypointLayers =
          p.layers.where((l) => p.isCloudWaypointsLayer(l.id)).toList();
      expect(waypointLayers, hasLength(1));
      expect(waypointLayers.single.isEmpty, isTrue);

      expect(_ids(p.sidebarLayers), contains(waypointLayers.single.id));
      p.removeEmptyLayers();
      expect(_ids(p.layers), contains(waypointLayers.single.id));
      expect(p.emptyLayers.where((l) => p.isCloudOverlayLayer(l.id)), isEmpty,
          reason: 'cloud layers are not saved layers');
    });
  });

  group('draw targets', () {
    test('a polygon can only go into saved layers', () {
      final p = _providerWith([_layer('a'), _layer('b')]);
      p.addCloudFolderLink('Distribution/2026/Sep 2026/Seeff');

      final targets = p.drawTargetsFor(DrawingMode.polygon);

      expect(targets.every((l) => !p.isCloudOverlayLayer(l.id)), isTrue);
      expect(_ids(targets), containsAll(['a', 'b']));
    });

    test('a point is offered the waypoint layers, empty or not', () {
      final p = _providerWith([_layer('a')]);
      p.addCloudFolderLink('Distribution/2026/Sep 2026/Seeff');

      final targets = p.drawTargetsFor(DrawingMode.point);

      expect(targets.where((l) => p.isCloudWaypointsLayer(l.id)), hasLength(1));
      expect(targets.where((l) => p.isCloudTracksLayer(l.id)), isEmpty);
    });

    test('a line is offered the track layers', () {
      final p = _providerWith([_layer('a')]);
      p.addCloudFolderLink('Distribution/2026/Sep 2026/Seeff');

      final targets = p.drawTargetsFor(DrawingMode.polyline);

      expect(targets.where((l) => p.isCloudTracksLayer(l.id)), hasLength(1));
      expect(targets.where((l) => p.isCloudWaypointsLayer(l.id)), isEmpty);
    });

    void drawPoint(ShareableMapProvider p) {
      p.setDrawingMode(DrawingMode.point);
      p.startDrawing();
      p.addDrawingPoint(_here);
    }

    test('a drawing goes into the chosen layer, which becomes selected', () {
      final p = _providerWith([_layer('a'), _layer('b')]);
      expect(p.selectedLayer?.id, 'a');

      drawPoint(p);
      p.completeDrawing(
        name: 'Drop',
        pointCategory: PointCategory.generic,
        targetLayerId: 'b',
      );

      expect(p.currentMap!.getLayer('a')!.points, isEmpty);
      expect(p.currentMap!.getLayer('b')!.points.single.name, 'Drop');
      expect(p.selectedLayer?.id, 'b');
    });

    test('a drawing can create its own layer', () {
      final p = _providerWith([_layer('a')]);

      drawPoint(p);
      p.completeDrawing(name: 'Drop', newLayerName: '  Depots  ');

      final created =
          p.currentMap!.layers.where((l) => l.name == 'Depots').single;
      expect(created.points.single.name, 'Drop');
      expect(p.selectedLayer?.id, created.id);
      expect(p.currentMap!.getLayer('a')!.points, isEmpty);
    });

    test('with no target given it still uses the selected layer', () {
      final p = _providerWith([_layer('a'), _layer('b')]);

      drawPoint(p);
      p.completeDrawing(name: 'Drop');

      expect(p.currentMap!.getLayer('a')!.points, hasLength(1));
    });
  });

  group('drawn GPX', () {
    test('a waypoint escapes its text and is a single wpt', () {
      final gpx = drawnWaypointGpx(
        name: 'Tom & "Jerry" <3',
        description: "Joe's",
        position: const LatLng(-33.9, 18.4),
      );

      expect(gpx, contains('<wpt lat="-33.9000000" lon="18.4000000">'));
      expect(gpx, contains('<name>Tom &amp; &quot;Jerry&quot; &lt;3</name>'));
      expect(gpx, contains('<desc>Joe&apos;s</desc>'));
      expect('<wpt'.allMatches(gpx), hasLength(1));
      expect(gpx, isNot(contains('<trk')));
    });

    test('a track carries no timestamps', () {
      final gpx = drawnTrackGpx(
        name: 'Line',
        points: const [LatLng(1, 2), LatLng(3, 4)],
      );

      expect('<trkpt'.allMatches(gpx), hasLength(2));
      expect(gpx, isNot(contains('<time>')),
          reason: 'invented times would move the report dates');
      expect(gpx, isNot(contains('<desc>')));
    });

    test('file names put each element in the right loader bucket', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1000);

      expect(drawnGpxFileName(isWaypoint: true, name: 'Box 12', at: at),
          'drawn_waypoint_box_12_1000.gpx');
      expect(drawnGpxFileName(isWaypoint: false, name: 'Route A', at: at),
          'drawn_track_route_a_1000.gpx');

      final sneaky =
          drawnGpxFileName(isWaypoint: false, name: 'Waypoint loop', at: at);
      expect(sneaky.toLowerCase(), isNot(contains('waypoint')));

      expect(drawnGpxFileName(isWaypoint: true, name: '///', at: at),
          'drawn_waypoint_1000.gpx');
    });
  });
}
