import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../../models/custom_polygon.dart';
import '../../shareable_maps/adapters/map_data_adapter.dart';
import '../../shareable_maps/models/map_layer.dart';
import '../../shareable_maps/models/shareable_map.dart';
import '../models/csg_region.dart';
import '../models/erf_property.dart';
import '../services/erf_kml_service.dart';
import '../services/erf_property_firestore_service.dart';

/// Adapter that bridges the ShareableMapEditor to ERF property data.
///
/// **Load**: Puts the parcels the user selected on a "Selected ERFs" layer in
/// the highlight colour, and any surrounding parcels on a separate, muted
/// "Surrounding ERFs" layer beneath them — so a pasted list reads as a set of
/// highlighted properties in their cadastral context rather than as one
/// undifferentiated blanket of polygons.
///
/// **Save**: Read-only — ERF data comes from the cadastral register and is
/// not edited in the map editor.
class ErfPropertyAdapter extends MapDataAdapter {
  /// Built on first use rather than in the constructor: the common path
  /// passes [preloadedProperties] and never touches Firestore, and eagerly
  /// reaching for `FirebaseFirestore.instance` would require an initialised
  /// app just to construct the adapter.
  ErfPropertyFirestoreService? _firestoreService;
  ErfPropertyFirestoreService get _firestore =>
      _firestoreService ??= ErfPropertyFirestoreService();

  /// Parcels to highlight. When empty, [preloadedProperties] (or the suburb
  /// query) is shown on its own without a highlight layer.
  final List<ErfProperty> selectedProperties;

  /// Optional suburb filter used when no properties are supplied directly.
  final String? suburbFilter;

  /// Optional pre-loaded parcels to show as context (skips the Firestore
  /// read).
  final List<ErfProperty>? preloadedProperties;

  /// Optional initial center for the map.
  final LatLng? initialCenter;

  /// Name shown as the map title.
  final String? title;

  /// Upper bound on parcels drawn as context.
  ///
  /// The map editor renders every polygon it is given with no viewport
  /// culling, so an unbounded layer would stall the browser. The default is
  /// set above a typical suburb — Constantia is about 10 000 parcels — so a
  /// whole suburb draws completely; the cap only bites on metro-sized areas.
  ///
  /// When it does bite, the parcels nearest the centre of interest are kept
  /// so the result is one coherent area rather than scattered fragments, and
  /// [truncatedContext] reports it so the UI can say so out loud.
  final int maxContextPolygons;

  /// How many context parcels were dropped by [maxContextPolygons] on the
  /// last [load]. Zero when everything was drawn.
  int truncatedContext = 0;

  ErfPropertyAdapter({
    ErfPropertyFirestoreService? firestoreService,
    this.selectedProperties = const [],
    this.suburbFilter,
    this.preloadedProperties,
    this.initialCenter,
    this.title,
    this.maxContextPolygons = 12000,
  }) : _firestoreService = firestoreService;

  @override
  String get adapterId => 'erf_property';

  @override
  String get displayName {
    if (title != null && title!.isNotEmpty) return title!;
    if (selectedProperties.isNotEmpty) {
      return 'Selected ERFs (${selectedProperties.length})';
    }
    return suburbFilter != null
        ? 'ERF Properties — $suburbFilter'
        : 'ERF Properties';
  }

  @override
  MapEditorCapabilities get capabilities =>
      const MapEditorCapabilities.viewOnly();

  @override
  Future<ShareableMap> load() async {
    final context = await _loadContextProperties();

    final selectedIds = selectedProperties.map((p) => p.id).toSet();
    final contextOnly = context
        .where((p) => !selectedIds.contains(p.id))
        .where((p) => p.polygon.length >= 3)
        .toList();

    final trimmedContext = _trimContext(contextOnly);

    final now = DateTime.now();
    final layers = <MapLayer>[];

    if (trimmedContext.isNotEmpty) {
      layers.add(MapLayer(
        id: 'erf_context_layer',
        name: 'All parcels in area',
        description: trimmedContext.length < contextOnly.length
            ? '${trimmedContext.length} of ${contextOnly.length} nearby parcels'
            : '${trimmedContext.length} nearby parcels',
        // Hidden when there is a selection, so the map opens showing only
        // what was searched for and stays interactive. Thousands of parcels
        // are one tick away in the layers panel when the surrounding context
        // is actually wanted.
        isVisible: selectedProperties.isEmpty,
        order: 0,
        defaultColor: ErfKmlService.contextColor,
        polygons: trimmedContext
            .map((p) => _erfToPolygon(p, ErfKmlService.contextColor,
                fillOpacity: 0.12, strokeWidth: 1))
            .toList(),
        createdAt: now,
        updatedAt: now,
      ));
    }

    if (selectedProperties.isNotEmpty) {
      layers.add(MapLayer(
        id: 'erf_selected_layer',
        name: 'Searched ERFs',
        description: '${selectedProperties.length} selected parcels',
        order: layers.length,
        defaultColor: ErfKmlService.highlightColor,
        polygons: selectedProperties
            .where((p) => p.polygon.length >= 3)
            .map((p) => _erfToPolygon(p, ErfKmlService.highlightColor,
                fillOpacity: 0.5, strokeWidth: 3))
            .toList(),
        createdAt: now,
        updatedAt: now,
      ));
    }

    // The map frames the selection when there is one, and the whole area
    // otherwise.
    final framingPoints = (selectedProperties.isNotEmpty
            ? selectedProperties
            : trimmedContext)
        .map((p) => p.centroid)
        .toList();
    final bounds = ErfBounds.fromPoints(framingPoints);

    return ShareableMap(
      id: 'erf_properties_map',
      name: displayName,
      description: selectedProperties.isNotEmpty
          ? '${selectedProperties.length} selected of '
              '${trimmedContext.length + selectedProperties.length} parcels'
          : '${trimmedContext.length} ERF parcels',
      layers: layers,
      defaultCenter:
          initialCenter ?? bounds?.center ?? const LatLng(-33.905, 18.510),
      defaultZoom: selectedProperties.length == 1 ? 18.0 : 16.0,
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    // Read-only adapter — ERF data is not edited in the map editor.
  }

  // ── Loading helpers ─────────────────────────────────────────────────

  Future<List<ErfProperty>> _loadContextProperties() async {
    if (preloadedProperties != null) return preloadedProperties!;
    if (suburbFilter != null) {
      return _firestore.getPropertiesBySuburb(suburbFilter!);
    }
    return const [];
  }

  /// Keep the context parcels closest to the centre of interest, up to
  /// [maxContextPolygons].
  ///
  /// The anchor is the selection when there is one, and otherwise the centre
  /// of the parcels themselves — never an arbitrary prefix of the list. A
  /// prefix follows the register's own row order, which is not spatial, so
  /// it used to scatter the drawn parcels in patches across the suburb and
  /// read as missing data.
  List<ErfProperty> _trimContext(List<ErfProperty> context) {
    truncatedContext = 0;
    if (context.length <= maxContextPolygons) return context;

    // Median rather than the bounding-box centre: one far-flung parcel would
    // drag a box centre halfway towards itself and push genuine neighbours
    // out of the kept set. The median barely moves.
    final anchor = _medianCentre(selectedProperties.isNotEmpty
        ? selectedProperties
        : context);

    final sorted = List<ErfProperty>.from(context);
    if (anchor != null) {
      sorted.sort((a, b) => _squaredDistance(a.centroid, anchor)
          .compareTo(_squaredDistance(b.centroid, anchor)));
    }

    truncatedContext = context.length - maxContextPolygons;
    return sorted.sublist(0, maxContextPolygons);
  }

  /// The median centroid of [properties], or null when there are none.
  static LatLng? _medianCentre(List<ErfProperty> properties) {
    if (properties.isEmpty) return null;

    final lats = properties.map((p) => p.centroid.latitude).toList()..sort();
    final lngs = properties.map((p) => p.centroid.longitude).toList()..sort();
    final mid = lats.length ~/ 2;
    return LatLng(lats[mid], lngs[mid]);
  }

  /// Squared degree distance — only ever used for ordering, so there is no
  /// need to convert to metres.
  static double _squaredDistance(LatLng a, LatLng b) {
    final dLat = a.latitude - b.latitude;
    final dLng = a.longitude - b.longitude;
    return dLat * dLat + dLng * dLng;
  }

  // ── Conversion helpers ──────────────────────────────────────────────

  /// Convert an [ErfProperty] to a [CustomPolygon] for the map editor.
  static CustomPolygon _erfToPolygon(
    ErfProperty erf,
    Color color, {
    required double fillOpacity,
    required int strokeWidth,
  }) {
    return CustomPolygon(
      id: erf.id,
      name: erf.displayLabel,
      description: 'ERF ${erf.tagValue.isNotEmpty ? erf.tagValue : erf.erfNumber}\n'
          '${erf.minRegion}\n'
          '${erf.area.toStringAsFixed(1)} m²',
      points: List<LatLng>.from(erf.polygon),
      color: color,
      fillOpacity: fillOpacity,
      strokeWidth: strokeWidth,
    );
  }
}
