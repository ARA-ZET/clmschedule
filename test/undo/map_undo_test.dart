import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/shareable_maps/models/map_point.dart';
import 'package:clmschedule/shareable_maps/models/shareable_map.dart';
import 'package:clmschedule/shareable_maps/providers/shareable_map_provider.dart';
import 'package:clmschedule/shareable_maps/utils/map_undo_tracker.dart';
import 'package:clmschedule/undo/undo_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

final _t = DateTime(2026, 9, 16);
const _here = LatLng(-33.92, 18.42);
const _there = LatLng(-33.93, 18.43);
const _elsewhere = LatLng(-33.94, 18.44);

MapLayer _layer(String id, {List<MapPoint> points = const []}) => MapLayer(
      id: id,
      name: 'Layer $id',
      order: 0,
      defaultColor: Colors.blue,
      points: points,
      createdAt: _t,
      updatedAt: _t,
    );

MapPoint _point(String id, [LatLng at = _here]) => MapPoint(
      id: id,
      name: 'P $id',
      position: at,
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

List<String> _ids(ShareableMapProvider p) =>
    p.currentMap!.layers.map((l) => l.id).toList();

LatLng _pos(ShareableMapProvider p, String layerId) =>
    p.currentMap!.getLayer(layerId)!.points.single.position;

void main() {
  test('creating a layer is one step; undo removes it, redo brings it back',
      () async {
    final p = _providerWith([_layer('a')]);
    final id = p.createLayer(name: 'Fresh')!;
    final h = p.undoHistory!;
    expect(h.undoLabel, 'Add layer "Fresh"');

    expect((await h.undo()).applied, isTrue);
    expect(_ids(p), ['a']);
    expect((await h.redo()).applied, isTrue);
    expect(_ids(p), ['a', id]);
  });

  test('a deleted layer comes back in its old position', () async {
    final p = _providerWith([_layer('a'), _layer('b'), _layer('c')]);
    p.deleteLayer('b');
    expect(_ids(p), ['a', 'c']);
    await p.undoHistory!.undo();
    expect(_ids(p), ['a', 'b', 'c']);
  });

  test('a burst of marker moves undoes in one step', () async {
    final p = _providerWith([
      _layer('a', points: [_point('x')])
    ]);
    p.moveMarker('x', _there);
    p.moveMarker('x', _elsewhere);
    final h = p.undoHistory!;
    expect(h.undoCount, 1);
    expect(h.undoLabel, 'Move "P x"');
    await h.undo();
    expect(_pos(p, 'a'), _here);
    await h.redo();
    expect(_pos(p, 'a'), _elsewhere);
  });

  test('undo is skipped when someone else edited that layer since', () async {
    final p = _providerWith([
      _layer('a', points: [_point('x')])
    ]);
    p.moveMarker('x', _there);
    // Another tab moves the same marker.
    p.debugApplyRemoteMap(p.currentMap!
        .updateLayer('a', _layer('a', points: [_point('x', _elsewhere)])));

    final r = await p.undoHistory!.undo();
    expect(r.kind, UndoResultKind.conflict);
    expect(_pos(p, 'a'), _elsewhere);
  });

  test("someone else's edit to another layer survives an undo", () async {
    final p = _providerWith([
      _layer('a', points: [_point('x')]),
      _layer('b', points: [_point('y')]),
    ]);
    p.moveMarker('x', _there);
    p.debugApplyRemoteMap(p.currentMap!
        .updateLayer('b', _layer('b', points: [_point('y', _elsewhere)])));

    expect((await p.undoHistory!.undo()).applied, isTrue);
    expect(_pos(p, 'a'), _here);
    expect(_pos(p, 'b'), _elsewhere);
  });

  test('a remote echo of identical content is not a conflict', () async {
    // Real layer ids are positional: fromMap names them layer_<index>.
    final p = _providerWith([
      _layer('layer_0', points: [_point('x')])
    ]);
    p.moveMarker('x', _there);
    // The same content rebuilt from Firestore: new objects, same data,
    // timestamps cut to milliseconds.
    final echo = ShareableMap.fromMap('m', p.currentMap!.toMap());
    p.debugApplyRemoteMap(echo);
    expect((await p.undoHistory!.undo()).applied, isTrue);
    expect(_pos(p, 'layer_0'), _here);
  });

  test('renaming the map is undoable', () async {
    final p = _providerWith([_layer('a')]);
    p.updateMapMetadata(name: 'Renamed');
    expect(p.undoHistory!.undoLabel, 'Rename map');
    await p.undoHistory!.undo();
    expect(p.currentMap!.name, 'Map');
  });

  test('each map keeps its own history', () {
    final p = _providerWith([_layer('a')]);
    p.createLayer(name: 'One');
    final first = p.undoKey;
    p.loadMap(ShareableMap(
      id: 'other',
      name: 'Other',
      layers: [_layer('z')],
      defaultCenter: _here,
      createdAt: _t,
      updatedAt: _t,
    ));
    expect(p.undoKey, isNot(first));
    expect(p.undoHistory!.canUndo, isFalse);
  });

  test('restoreLayers leaves layers outside the step alone', () {
    final base = ShareableMap(
      id: 'm',
      name: 'Map',
      layers: [_layer('a'), _layer('b')],
      defaultCenter: _here,
      createdAt: _t,
      updatedAt: _t,
    );
    final current = base.updateLayer('b', _layer('b', points: [_point('n')]));
    final target = base.removeLayer('a');
    final restored =
        restoreLayers(current: current, target: target, layerIds: {'a'});
    expect(restored.layers.map((l) => l.id), ['b']);
    expect(restored.getLayer('b')!.points, hasLength(1));
  });
}
