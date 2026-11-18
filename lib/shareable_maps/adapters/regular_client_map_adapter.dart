import 'package:flutter/material.dart';

import '../../models/custom_polygon.dart';
import '../../models/regular_client.dart';
import '../../services/regular_client_service.dart';
import '../../utils/map_pin_icons.dart';
import '../models/map_point.dart';
import '../models/shareable_map.dart';
import '../providers/shareable_map_provider.dart';
import '../services/shareable_maps_firestore_service.dart';
import '../utils/linked_map_polygons.dart' show mapPointAsWorkMap;
import 'map_data_adapter.dart';

/// Shows a regular client's own map coloured by its allocation plan: grey
/// where no slot holds a polygon, the slot's colour where one does, and a
/// heavy outline where several share it.
///
/// Points (traffic-light handouts, poster spots) are allocated like areas,
/// by their id. They are drawn as descriptive pins carrying their name, in
/// the plan's colours, through the provider's draw-time pin rule
/// ([paintPoints]) rather than in the map, so a point keeps its own colour
/// and category when saved.
///
/// The map is the client's copy ([RegularClient.map]), never the gallery map
/// it was copied from — that one is a real client's map, shared in reports.
/// Polygons can be drawn, redrawn, renamed and deleted here, and [save] writes
/// them to the copy with each polygon's own colour, opacity, stroke and
/// description restored, so the plan's colours are only ever on screen. The
/// plan itself is written through [RegularClientService] by [applyPlan].
class RegularClientMapAdapter extends MapDataAdapter {
  final RegularClientService _service;
  final ShareableMapsFirestoreService _maps;

  RegularClient _client;

  /// The client's map as last loaded or saved, before restyling.
  ShareableMap? _source;

  /// Swaps a rebuilt map into the editor without saving — normally
  /// [ShareableMapProvider.applyAdapterMap]. Used after a save hands new
  /// polygons their stored ids, so the next edit saves under the same id.
  final void Function(ShareableMap map)? onReload;

  /// Whether the editor is mid-draw or mid-vertex-edit; a reload then would
  /// throw that work away, so it waits for the next save.
  final bool Function()? isBusyEditing;

  RegularClientMapAdapter(
    RegularClient client, {
    RegularClientService? service,
    ShareableMapsFirestoreService? maps,
    this.onReload,
    this.isBusyEditing,
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

  /// Polygons and points only: colours belong to the plan.
  @override
  MapEditorCapabilities get capabilities => const MapEditorCapabilities(
        canDrawPolylines: false,
        canImportGpx: false,
        canManageLayers: false,
        canEditStyle: false,
        canCleanBoundaries: false,
      );

  /// Every allocatable polygon and point of [map] (the editor's live map,
  /// so indexes match what is on screen even before an edit is saved), in
  /// layer order, each layer's areas before its points. Polygons drawn since
  /// the last save have no id yet and are left out; points get theirs when
  /// placed.
  List<RegularClientArea> areasOf(ShareableMap? map) {
    if (map == null) return const [];
    return [
      for (final layer in map.layers) ...[
        for (var i = 0; i < layer.polygons.length; i++)
          if (isArea(layer.polygons[i]) &&
              (layer.polygons[i].id ?? '').isNotEmpty)
            RegularClientArea(layer.id, i, layer.polygons[i]),
        for (var i = 0; i < layer.points.length; i++)
          if (layer.points[i].id.isNotEmpty)
            RegularClientArea(
                layer.id, i, mapPointAsWorkMap(layer.points[i]),
                isPoint: true),
      ],
    ];
  }

  /// The area behind an editor element id (`layerId_polygon_N` for a
  /// polygon, the point's own id for a point), or null.
  RegularClientArea? areaForElement(ShareableMap? map, String elementId) {
    final areas = areasOf(map);
    final m = RegExp(r'^(.+)_polygon_(\d+)$').firstMatch(elementId);
    if (m != null) {
      final layerId = m.group(1)!;
      final index = int.parse(m.group(2)!);
      for (final a in areas) {
        if (!a.isPoint && a.layerId == layerId && a.index == index) return a;
      }
    }
    for (final a in areas) {
      if (a.isPoint && a.id == elementId) return a;
    }
    return null;
  }

  /// Draw every point as a pin with its name, coloured by the plan: grey
  /// when no slot holds it, else the first holding slot's colour. Draw-time
  /// only — the provider clears it when another map loads, and the panel
  /// puts it back after a reload or when a layer is added.
  void paintPoints(ShareableMapProvider provider) {
    final client = _client;
    final map = provider.currentMap ?? _source;
    provider.setPointPinRule(PointPinRule(
      layerIds: {for (final l in map?.layers ?? const []) l.id},
      pinFor: (MapPoint p) {
        final holdings = client.holdingsOf(p.id);
        final colour =
            holdings.isEmpty ? unallocatedColor : holdings.first.slot.color;
        return (
          style: MapPinStyle.named(mapPointAsWorkMap(p), colour),
          zIndex: PinLayer.point,
        );
      },
    ));
  }

  @override
  Future<ShareableMap> load() async {
    // A plan from before plans owned their map gets its copy now.
    _client = await _service.ensureOwnMap(_client, maps: _maps);
    final map = _client.map!;
    _source = map;
    return _styledFrom(map);
  }

  @override
  Future<void> save(ShareableMap map) async {
    final source = _source;
    if (source == null) return;
    final sourceById = {
      for (final l in source.layers)
        for (final p in l.polygons)
          if ((p.id ?? '').isNotEmpty) p.id!: p,
    };
    final restored = map.copyWith(
      name: source.name,
      description: source.description,
      layers: [
        for (final layer in map.layers)
          layer.copyWith(polygons: [
            for (final p in layer.polygons) _unstyled(p, sourceById[p.id]),
          ]),
      ],
    ).withStablePolygonIds();

    final hadNew = map.layers
            .expand((l) => l.polygons)
            .any((p) => isArea(p) && (p.id ?? '').isEmpty) ||
        // A point whose id clashed with another element is renumbered.
        !_samePointIds(map, restored);
    await _service.saveMap(_client.id, restored);
    _source = restored;
    _client = _client.copyWith(map: restored);

    // A new polygon got its id in the save (or a point a new one); give it
    // to the editor too (and its grey "unallocated" look) unless that would
    // interrupt an edit.
    if (hadNew && !(isBusyEditing?.call() ?? false)) {
      onReload?.call(_styledFrom(restored));
    }
  }

  static bool _samePointIds(ShareableMap a, ShareableMap b) {
    final ids = [
      for (final l in a.layers)
        for (final p in l.points) p.id
    ];
    final other = [
      for (final l in b.layers)
        for (final p in l.points) p.id
    ];
    if (ids.length != other.length) return false;
    for (var i = 0; i < ids.length; i++) {
      if (ids[i] != other[i]) return false;
    }
    return true;
  }

  /// [p] as the client's map should store it: its geometry, name and counts
  /// from the editor, its look from before the plan restyled it
  /// ([original]). A new polygon
  /// keeps what it was drawn with, less the plan's description.
  CustomPolygon _unstyled(CustomPolygon p, CustomPolygon? original) {
    if (!isArea(p)) return p;
    if (original == null) {
      return p.description == 'Not allocated' ? p.copyWith(description: '') : p;
    }
    return p.copyWith(
      color: original.color,
      fillOpacity: original.fillOpacity,
      strokeWidth: original.strokeWidth,
      description: original.description,
    );
  }

  /// Persist [next] as the plan and recolour the open map.
  Future<void> applyPlan(
      RegularClient next, ShareableMapProvider provider) async {
    _client = next;
    // Restyle what is on screen, not the last save, so an edit still waiting
    // for autosave is kept.
    final current = provider.currentMap ?? _source;
    if (current != null) provider.applyAdapterMap(_styledFrom(current));
    paintPoints(provider);
    await _service.save(next);
  }

  /// [map] coloured by the plan. Idempotent, so an already-styled map can be
  /// restyled after the plan changes.
  ShareableMap _styledFrom(ShareableMap map) {
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

/// One allocatable polygon or point and where the editor finds it.
class RegularClientArea {
  final String layerId;

  /// Position in the layer's `polygons`, or in its `points` for a point.
  final int index;

  /// The element as a schedule job holds it; a point is a point-type
  /// polygon carrying the point's id.
  final CustomPolygon polygon;

  final bool isPoint;

  const RegularClientArea(this.layerId, this.index, this.polygon,
      {this.isPoint = false});

  String get id => polygon.id!;
  String get name => polygon.name.trim().isNotEmpty
      ? polygon.name
      : (isPoint ? 'Point ${index + 1}' : 'Area ${index + 1}');
}
