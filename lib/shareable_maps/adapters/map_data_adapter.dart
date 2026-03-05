import '../models/shareable_map.dart';

/// Feature flags that control which editor UI elements are available.
///
/// Each adapter declares its own capabilities, and the editor widget
/// hides/shows tools, buttons, and panels accordingly.
class MapEditorCapabilities {
  /// Can draw polygon shapes on the map.
  final bool canDrawPolygons;

  /// Can draw polyline (line) shapes on the map.
  final bool canDrawPolylines;

  /// Can place point markers on the map.
  final bool canDrawPoints;

  /// Can import KML/KMZ files.
  final bool canImportKml;

  /// Can import GPX files.
  final bool canImportGpx;

  /// Can export the map data (KML/GPX).
  final bool canExport;

  /// Can create, delete, and reorder layers.
  final bool canManageLayers;

  /// Can edit element styles (color, fill, stroke).
  final bool canEditStyle;

  /// Can delete elements from the map.
  final bool canDelete;

  /// Shows an explicit Save button in the app bar.
  /// When false, the adapter is either auto-save or read-only.
  final bool showSaveButton;

  /// When true, the map is non-editable (view only).
  final bool readOnly;

  const MapEditorCapabilities({
    this.canDrawPolygons = true,
    this.canDrawPolylines = true,
    this.canDrawPoints = true,
    this.canImportKml = true,
    this.canImportGpx = true,
    this.canExport = true,
    this.canManageLayers = true,
    this.canEditStyle = true,
    this.canDelete = true,
    this.showSaveButton = true,
    this.readOnly = false,
  });

  /// Preset: full editing (standalone map editor).
  const MapEditorCapabilities.full()
      : canDrawPolygons = true,
        canDrawPolylines = true,
        canDrawPoints = true,
        canImportKml = true,
        canImportGpx = true,
        canExport = true,
        canManageLayers = true,
        canEditStyle = true,
        canDelete = true,
        showSaveButton = false,
        readOnly = false;

  /// Preset: polygon-only editing (work areas, schedule jobs).
  const MapEditorCapabilities.polygonOnly()
      : canDrawPolygons = true,
        canDrawPolylines = false,
        canDrawPoints = false,
        canImportKml = true,
        canImportGpx = false,
        canExport = true,
        canManageLayers = false,
        canEditStyle = true,
        canDelete = true,
        showSaveButton = true,
        readOnly = false;

  /// Preset: view-only map display (no editing).
  const MapEditorCapabilities.viewOnly()
      : canDrawPolygons = false,
        canDrawPolylines = false,
        canDrawPoints = false,
        canImportKml = false,
        canImportGpx = false,
        canExport = false,
        canManageLayers = false,
        canEditStyle = false,
        canDelete = false,
        showSaveButton = false,
        readOnly = true;

  /// Whether any drawing tool is available.
  bool get canDraw => canDrawPolygons || canDrawPolylines || canDrawPoints;

  /// Whether any import format is supported.
  bool get canImport => canImportKml || canImportGpx;
}

/// Abstract interface that bridges the ShareableMapEditor to any data source.
///
/// Each concrete adapter knows how to load data from its source into a
/// [ShareableMap] and how to save changes back. The editor widget and
/// provider are completely decoupled from the underlying storage.
///
/// ### How to create a new adapter
///
/// 1. Extend [MapDataAdapter]
/// 2. Implement [load] to read data and return a [ShareableMap]
/// 3. Implement [save] to persist the map state
/// 4. Set [capabilities] to control which editor features are exposed
///
/// ```dart
/// class MyAdapter extends MapDataAdapter {
///   @override String get adapterId => 'my_adapter';
///   @override String get displayName => 'My Data Source';
///   @override MapEditorCapabilities get capabilities =>
///       const MapEditorCapabilities.full();
///
///   @override Future<ShareableMap> load() async { ... }
///   @override Future<void> save(ShareableMap map) async { ... }
/// }
/// ```
abstract class MapDataAdapter {
  /// Unique identifier for this adapter type (e.g. 'work_area', 'schedule_job').
  String get adapterId;

  /// Human-readable label displayed in the editor title / app bar.
  String get displayName;

  /// Feature flags controlling which editor tools are available.
  MapEditorCapabilities get capabilities;

  /// Load the initial data and return it as a [ShareableMap].
  ///
  /// Called once when the editor opens with this adapter.
  Future<ShareableMap> load();

  /// Persist the current map state back to the data source.
  ///
  /// Called when the user taps Save or when auto-save triggers.
  Future<void> save(ShareableMap map);

  /// When true, [save] is called on every state change automatically.
  /// Default is false (manual save via button).
  bool get autoSave => false;

  /// Called when the editor is closed. Use for cleanup.
  Future<void> dispose() async {}
}
