import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../services/route_planner_service.dart';
import '../../shareable_maps/adapters/map_data_adapter.dart';
import '../../shareable_maps/models/map_layer.dart';
import '../../shareable_maps/models/map_point.dart';
import '../../shareable_maps/models/map_polyline.dart';
import '../../shareable_maps/models/shareable_map.dart';
import '../../utils/polyline_codec.dart';
import '../../utils/route_marker_icons.dart';
import '../models/erf_property.dart';

/// Builds the client-facing map for a planned delivery run.
///
/// Used as a *builder*: [load] produces the [ShareableMap] that gets
/// written into the maps gallery, after which the editor opens that saved
/// document rather than this in-memory one. A client map that exists only
/// for the lifetime of a screen is not something you can send anyone.
///
/// This is where the three halves of the tool meet: the cadastral parcels
/// from the ERF register, the stop order from the route planner, and the
/// shareable map the client actually receives. It produces four layers, in
/// draw order:
///
///  1. **Context parcels** — the surrounding erven, muted and off by
///     default so the map opens readable.
///  2. **Delivery parcels** — the boundary of every parcel being delivered
///     to, tinted along the run so early and late stops read differently.
///  3. **Route** — the driven roads.
///  4. **Stops** — numbered pins, on top so a number is never buried under
///     a polygon.
///
/// Stops are last deliberately: layer order is z-order on the map, and a
/// pin hidden behind a parcel fill is the one thing that would make the
/// drive order unreadable.
class ErfRouteAdapter extends MapDataAdapter {
  final PlannedRoute route;

  /// Parcels keyed by [ErfProperty.id]; stops without one simply get a pin.
  final Map<String, ErfProperty> parcels;

  /// Surrounding parcels drawn as muted context.
  final List<ErfProperty> contextParcels;

  final String title;
  final String? description;

  /// Cap on context parcels drawn, mirroring [ErfPropertyAdapter] — the
  /// editor draws every polygon with no viewport culling.
  final int maxContextPolygons;

  ErfRouteAdapter({
    required this.route,
    required this.title,
    this.parcels = const {},
    this.contextParcels = const [],
    this.description,
    this.maxContextPolygons = 8000,
  });

  @override
  String get adapterId => 'erf_route';

  @override
  String get displayName => title;

  /// The run is a snapshot of a plan, not a document to edit in place —
  /// but it must stay exportable and savable so it can reach a client.
  @override
  MapEditorCapabilities get capabilities => const MapEditorCapabilities(
        canDrawPolygons: false,
        canDrawPolylines: false,
        canDrawPoints: false,
        canImportKml: false,
        canImportGpx: false,
        canExport: true,
        canManageLayers: true,
        canEditStyle: true,
        canDelete: false,
        showSaveButton: false,
        readOnly: false,
      );

  @override
  Future<ShareableMap> load() async {
    final now = DateTime.now();
    final layers = <MapLayer>[];
    final stops = route.stops;

    // ── 1. Context parcels ──────────────────────────────────────────────
    final deliveryIds = parcels.keys.toSet();
    final context = contextParcels
        .where((p) => !deliveryIds.contains(p.id) && p.polygon.length >= 3)
        .take(maxContextPolygons)
        .toList();

    if (context.isNotEmpty) {
      layers.add(MapLayer(
        id: 'erf_route_context',
        name: 'Surrounding parcels',
        description: '${context.length} nearby erven',
        isVisible: false,
        order: layers.length,
        defaultColor: const Color(0xFF90A4AE),
        polygons: [
          for (final parcel in context)
            _parcelPolygon(parcel, const Color(0xFF90A4AE),
                fillOpacity: 0.10, strokeWidth: 1),
        ],
        createdAt: now,
        updatedAt: now,
      ));
    }

    // ── 2. Delivery parcels ─────────────────────────────────────────────
    final deliveryPolygons = <CustomPolygon>[];
    for (var i = 0; i < stops.length; i++) {
      final stop = stops[i];
      final parcel = parcels[stop.address.erfId];
      if (parcel == null || parcel.polygon.length < 3) continue;

      final color = stop.isDepot
          ? const Color(0xFF6A1B9A)
          : RouteMarkerIcons.colorForPosition(i, stops.length);

      deliveryPolygons.add(_parcelPolygon(
        parcel,
        color,
        fillOpacity: 0.38,
        strokeWidth: 3,
        name: stop.isDepot
            ? 'Start · ${parcel.displayLabel}'
            : '${stop.sequence}. ${parcel.displayLabel}',
        description: _stopDescription(stop, parcel),
      ));
    }

    if (deliveryPolygons.isNotEmpty) {
      layers.add(MapLayer(
        id: 'erf_route_parcels',
        name: 'Delivery parcels',
        description: '${deliveryPolygons.length} erven on this run',
        order: layers.length,
        defaultColor: const Color(0xFF1565C0),
        polygons: deliveryPolygons,
        createdAt: now,
        updatedAt: now,
      ));
    }

    // ── 3. Route ────────────────────────────────────────────────────────
    final path = simplifyPath(route.fullPath, toleranceMeters: 3);
    if (path.length >= 2) {
      layers.add(MapLayer(
        id: 'erf_route_path',
        name: 'Route',
        description: '${route.totalDistanceFormatted} · '
            '${route.totalDrivingFormatted} driving',
        order: layers.length,
        defaultColor: const Color(0xFF1565C0),
        polylines: [
          MapPolyline(
            id: 'erf_route_line',
            name: 'Delivery route',
            description: '${route.deliveryStops.length} stops · '
                '${route.totalDistanceFormatted}',
            points: path,
            color: const Color(0xFF1565C0),
            strokeWidth: 5,
            distanceMeters: route.totalDistanceMeters,
            createdAt: now,
            updatedAt: now,
          ),
        ],
        createdAt: now,
        updatedAt: now,
      ));
    }

    // ── 4. Numbered stops ───────────────────────────────────────────────
    final points = <MapPoint>[];
    for (var i = 0; i < stops.length; i++) {
      final stop = stops[i];
      final address = stop.address;
      if (address.latitude == null || address.longitude == null) continue;

      final parcel = parcels[address.erfId];
      points.add(MapPoint(
        id: 'stop_${stop.sequence}_${address.id}',
        name: stop.isDepot
            ? 'Start · ${address.displayName}'
            : address.displayName,
        description: _stopDescription(stop, parcel),
        position: LatLng(address.latitude!, address.longitude!),
        color: stop.isDepot
            ? const Color(0xFF6A1B9A)
            : RouteMarkerIcons.colorForPosition(i, stops.length),
        // Drives the numbered bitmap on the map and the zero-padded name in
        // the KML export.
        routeSequence: stop.isDepot ? 0 : stop.sequence,
        createdAt: now,
        updatedAt: now,
      ));
    }

    if (points.isNotEmpty) {
      layers.add(MapLayer(
        id: 'erf_route_stops',
        name: 'Stops in order',
        description: '${route.deliveryStops.length} deliveries',
        order: layers.length,
        defaultColor: const Color(0xFF2E7D32),
        points: points,
        createdAt: now,
        updatedAt: now,
      ));
    }

    final centre = _centre(points.map((p) => p.position).toList());

    return ShareableMap(
      id: 'erf_route_map',
      name: title,
      description: description ??
          '${route.deliveryStops.length} stops · '
              '${route.totalDistanceFormatted} · '
              '${route.totalDrivingFormatted} driving',
      layers: layers,
      defaultCenter: centre ?? const LatLng(-33.9249, 18.4241),
      defaultZoom: 14,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    // A planned run is a snapshot. Saving it as a client map goes through
    // the gallery ("Save as new map"), which owns its own storage — writing
    // back here would silently mutate the plan behind the planner's back.
  }

  // ── Helpers ───────────────────────────────────────────────────────────

  static CustomPolygon _parcelPolygon(
    ErfProperty parcel,
    Color color, {
    required double fillOpacity,
    required int strokeWidth,
    String? name,
    String? description,
  }) {
    return CustomPolygon(
      id: parcel.id,
      name: name ?? parcel.displayLabel,
      description: description ??
          'ERF ${parcel.tagValue.isNotEmpty ? parcel.tagValue : parcel.erfNumber}\n'
              '${parcel.minRegion}\n'
              '${parcel.area.toStringAsFixed(1)} m²',
      points: List<LatLng>.from(parcel.polygon),
      color: color,
      fillOpacity: fillOpacity,
      strokeWidth: strokeWidth,
    );
  }

  static String _stopDescription(PlannedStop stop, ErfProperty? parcel) {
    final address = stop.address;
    return [
      if (!stop.isDepot) 'Stop ${stop.sequence}',
      address.fullAddress,
      if (parcel != null)
        'ERF ${parcel.tagValue.isNotEmpty ? parcel.tagValue : parcel.erfNumber}'
            ' · ${parcel.area.toStringAsFixed(0)} m²',
      if (!stop.isDepot)
        '${stop.legDistanceKm.toStringAsFixed(2)} km from the previous stop '
            '(${stop.legDurationFormatted})',
      'Cumulative ${stop.cumulativeDistanceKm.toStringAsFixed(2)} km',
      if (stop.arrival != null)
        'ETA ${stop.arrival!.hour.toString().padLeft(2, '0')}:'
            '${stop.arrival!.minute.toString().padLeft(2, '0')}',
      if (address.notes?.isNotEmpty ?? false) 'Note: ${address.notes}',
    ].where((line) => line.trim().isNotEmpty).join('\n');
  }

  static LatLng? _centre(List<LatLng> points) {
    if (points.isEmpty) return null;
    var lat = 0.0;
    var lng = 0.0;
    for (final p in points) {
      lat += p.latitude;
      lng += p.longitude;
    }
    return LatLng(lat / points.length, lng / points.length);
  }
}
