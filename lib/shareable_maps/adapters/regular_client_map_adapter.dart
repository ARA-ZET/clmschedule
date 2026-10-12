import 'package:flutter/material.dart';

import '../../models/custom_polygon.dart';
import '../../models/regular_client.dart';
import '../../services/regular_client_service.dart';
import '../models/shareable_map.dart';
import '../providers/shareable_map_provider.dart';
import '../services/shareable_maps_firestore_service.dart';
import 'map_data_adapter.dart';

/// Shows a regular client's gallery map coloured by its allocation plan:
/// grey where no slot holds a polygon, the slot's colour where one does, and a
/// heavy outline where several share it.
///
/// The gallery map is only read. Geometry is edited in the gallery itself, so
/// [save] does nothing and the plan's colours never reach the shared map. The
/// plan is written through [RegularClientService] by [applyPlan].
class RegularClientMapAdapter extends MapDataAdapter {
  final RegularClientService _service;
  final ShareableMapsFirestoreService _maps;

  RegularClient _client;

  /// The gallery map as loaded, before restyling.
  ShareableMap? _source;

  RegularClientMapAdapter(
    RegularClient client, {
    RegularClientService? service,
    ShareableMapsFirestoreService? maps,
  })  : _client = client,
        _service = service ?? RegularClientService(),
        _maps = maps ?? ShareableMapsFirestoreService();

  static const Color unallocatedColor = Color(0xFF9E9E9E);

  /// Areas narrower than this are pins or lines, not something to allocate.
  static bool isArea(CustomPolygon p) => p.isPolygon && p.points.length >= 3;

  RegularClient get client => _client;

  @override
  String get adapterId => 'regular_client_${_client.id}';

  @override
  String get displayName => _client.name;

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.viewOnly();

  /// Every allocatable polygon of the gallery map, unstyled, in layer order.
  List<RegularClientArea> get areas {
    final map = _source;
    if (map == null) return const [];
    return [
      for (final layer in map.layers)
        for (var i = 0; i < layer.polygons.length; i++)
          if (isArea(layer.polygons[i]) &&
              (layer.polygons[i].id ?? '').isNotEmpty)
            RegularClientArea(layer.id, i, layer.polygons[i]),
    ];
  }

  /// The area behind an editor element id (`layerId_polygon_N`), or null.
  RegularClientArea? areaForElement(String elementId) {
    final m = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(elementId);
    if (m == null) return null;
    final layerId = m.group(1)!;
    final index = int.parse(m.group(2)!);
    for (final a in areas) {
      if (a.layerId == layerId && a.index == index) return a;
    }
    return null;
  }

  @override
  Future<ShareableMap> load() async {
    final map = await _maps.getMap(_client.mapMonthKey, _client.mapId);
    if (map == null) {
      throw StateError(
          'The map "${_client.mapName}" is no longer in the gallery.');
    }
    _source = map;
    return _styled();
  }

  @override
  Future<void> save(ShareableMap map) async {}

  /// Persist [next] as the plan and recolour the open map.
  Future<void> applyPlan(
      RegularClient next, ShareableMapProvider provider) async {
    _client = next;
    if (_source != null) provider.applyAdapterMap(_styled());
    await _service.save(next);
  }

  ShareableMap _styled() {
    final map = _source!;
    return map.copyWith(
      name: _client.name,
      layers: [
        for (final layer in map.layers)
          layer.copyWith(polygons: [
            for (final p in layer.polygons) isArea(p) ? _style(p) : p,
          ]),
      ],
    );
  }

  CustomPolygon _style(CustomPolygon p) {
    final holdings = _client.holdingsOf(p.id ?? '');
    if (holdings.isEmpty) {
      return p.copyWith(
        color: unallocatedColor,
        fillOpacity: 0.25,
        strokeWidth: 2,
        description: 'Not allocated',
      );
    }
    final shared = {for (final h in holdings) h.slot.id}.length > 1;
    return p.copyWith(
      color: holdings.first.slot.color,
      fillOpacity: 0.45,
      strokeWidth: shared ? 5 : 2,
      description: holdings.map((h) => h.label).join(', '),
    );
  }
}

/// One allocatable polygon and where the editor finds it.
class RegularClientArea {
  final String layerId;
  final int index;
  final CustomPolygon polygon;

  const RegularClientArea(this.layerId, this.index, this.polygon);

  String get id => polygon.id!;
  String get name => polygon.name.isEmpty ? 'Area ${index + 1}' : polygon.name;
}
