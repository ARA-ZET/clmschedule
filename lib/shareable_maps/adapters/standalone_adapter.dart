import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../models/shareable_map.dart';
import 'map_data_adapter.dart';

/// Adapter for the existing standalone map editor behavior.
///
/// Creates a blank map in memory with no persistence. This preserves
/// the original behavior of the shareable map editor before the adapter
/// pattern was introduced.
class StandaloneAdapter extends MapDataAdapter {
  final String mapName;
  final String mapDescription;
  final LatLng? defaultCenter;

  StandaloneAdapter({
    this.mapName = 'Untitled Map',
    this.mapDescription = '',
    this.defaultCenter,
  });

  @override
  String get adapterId => 'standalone';

  @override
  String get displayName => mapName;

  @override
  MapEditorCapabilities get capabilities => const MapEditorCapabilities.full();

  @override
  Future<ShareableMap> load() async {
    return ShareableMap.createWithDefaultLayer(
      name: mapName,
      description: mapDescription,
      defaultCenter: defaultCenter,
    );
  }

  @override
  Future<void> save(ShareableMap map) async {
    // No persistence in standalone mode.
    // Future: could save to Firestore `/shareableMaps/{id}`.
  }
}
