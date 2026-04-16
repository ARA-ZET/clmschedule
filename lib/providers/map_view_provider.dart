import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/custom_polygon.dart';

/// Riverpod provider for MapViewProvider
final mapViewRiverpod = riverpod.ChangeNotifierProvider<MapViewProvider>((ref) {
  return MapViewProvider();
});

class MapViewProvider extends ChangeNotifier {
  // Popup state
  bool _isPopupVisible = false;
  int? _selectedPolygonIndex;
  CustomPolygon? _selectedCustomPolygon;

  // Editing state
  bool _isEditing = false;
  List<LatLng> _editingPoints = [];
  bool _hasUnsavedChanges = false;

  // Polygon creation state
  bool _isCreatingNewPolygon = false;
  final List<LatLng> _newPolygonPoints = [];

  // Marker creation state
  bool _isPlacingMarker = false;

  // Polygon list
  List<CustomPolygon> _customPolygons = [];

  // Map center
  LatLng _center = const LatLng(-33.925, 18.425);
  bool _hasInitiallyPositioned = false;

  // Sidebar visibility
  bool _isSidebarVisible = true;

  // Getters
  bool get isPopupVisible => _isPopupVisible;
  int? get selectedPolygonIndex => _selectedPolygonIndex;
  CustomPolygon? get selectedCustomPolygon => _selectedCustomPolygon;
  bool get isEditing => _isEditing;
  List<LatLng> get editingPoints => _editingPoints;
  bool get hasUnsavedChanges => _hasUnsavedChanges;
  bool get isCreatingNewPolygon => _isCreatingNewPolygon;
  List<LatLng> get newPolygonPoints => _newPolygonPoints;
  bool get isPlacingMarker => _isPlacingMarker;
  List<CustomPolygon> get customPolygons => _customPolygons;
  LatLng get center => _center;
  bool get hasInitiallyPositioned => _hasInitiallyPositioned;
  bool get isSidebarVisible => _isSidebarVisible;

  // Initialize polygons from widget
  void initializePolygons(List<CustomPolygon>? polygons) {
    if (polygons != null && polygons.isNotEmpty) {
      _customPolygons = List.from(polygons);
      if (_selectedPolygonIndex == null && _customPolygons.isNotEmpty) {
        _selectedCustomPolygon = _customPolygons.first;
        _selectedPolygonIndex = 0;
      }
      print('MapViewProvider: Initialized ${_customPolygons.length} polygons');
      notifyListeners();
    }
  }

  // Popup management
  void openPopup(int polygonIndex, LatLng center) {
    _isPopupVisible = true;
    _selectedPolygonIndex = polygonIndex;
    if (polygonIndex < _customPolygons.length) {
      _selectedCustomPolygon = _customPolygons[polygonIndex];
    }
    print('MapViewProvider: Opening popup for polygon $polygonIndex');
    notifyListeners();
  }

  void closePopup() {
    print('MapViewProvider: Closing popup');
    _isPopupVisible = false;
    _selectedPolygonIndex = null;
    _selectedCustomPolygon = null;
    notifyListeners();
  }

  // Editing state management
  void startEditing(int polygonIndex) {
    if (polygonIndex >= _customPolygons.length) return;

    _isEditing = true;
    _selectedPolygonIndex = polygonIndex;
    _selectedCustomPolygon = _customPolygons[polygonIndex];
    _editingPoints = List<LatLng>.from(_customPolygons[polygonIndex].points);
    _hasUnsavedChanges = false;
    print('MapViewProvider: Started editing polygon $polygonIndex');
    notifyListeners();
  }

  void updateEditingPoints(List<LatLng> points) {
    _editingPoints = points;
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  void updateEditingPoint(int index, LatLng newPosition) {
    if (index < _editingPoints.length) {
      _editingPoints[index] = newPosition;
      _hasUnsavedChanges = true;
      notifyListeners();
    }
  }

  void insertEditingPoint(int index, LatLng point) {
    _editingPoints.insert(index, point);
    _hasUnsavedChanges = true;
    notifyListeners();
  }

  void cancelEditing() {
    _isEditing = false;
    _editingPoints.clear();
    _hasUnsavedChanges = false;
    print('MapViewProvider: Cancelled editing');
    notifyListeners();
  }

  void saveEditingChanges() {
    if (_isEditing && _selectedPolygonIndex != null) {
      final updatedPolygon = _customPolygons[_selectedPolygonIndex!].copyWith(
        points: List<LatLng>.from(_editingPoints),
      );
      _customPolygons[_selectedPolygonIndex!] = updatedPolygon;
      _selectedCustomPolygon = updatedPolygon;
      _isEditing = false;
      _editingPoints.clear();
      _hasUnsavedChanges = false;
      print(
          'MapViewProvider: Saved editing changes for polygon $_selectedPolygonIndex');
      notifyListeners();
    }
  }

  // Polygon creation
  void startCreatingPolygon() {
    _isCreatingNewPolygon = true;
    _newPolygonPoints.clear();
    print('MapViewProvider: Started creating new polygon');
    notifyListeners();
  }

  void addPolygonPoint(LatLng point) {
    _newPolygonPoints.add(point);
    print(
        'MapViewProvider: Added point to new polygon (${_newPolygonPoints.length} total)');
    notifyListeners();
  }

  void finishCreatingPolygon() {
    if (_newPolygonPoints.length >= 3) {
      final newPolygon = CustomPolygon(
        name: 'New Area ${_customPolygons.length + 1}',
        description: 'User created area',
        points: List.from(_newPolygonPoints),
        color: Colors.blue,
      );
      _customPolygons.add(newPolygon);
      _isCreatingNewPolygon = false;
      _newPolygonPoints.clear();
      _hasUnsavedChanges = true;
      print(
          'MapViewProvider: Finished creating polygon (total: ${_customPolygons.length})');
      notifyListeners();
    }
  }

  void cancelCreatingPolygon() {
    _isCreatingNewPolygon = false;
    _newPolygonPoints.clear();
    if (kDebugMode) {
      print('MapViewProvider: Cancelled creating polygon');
    }
    notifyListeners();
  }

  // Marker placement
  void startPlacingMarker() {
    _isPlacingMarker = true;
    _isCreatingNewPolygon = false;
    _isEditing = false;
    _newPolygonPoints.clear();
    if (kDebugMode) {
      print('MapViewProvider: Started placing marker');
    }
    notifyListeners();
  }

  void placeMarker(LatLng position) {
    final newMarker = CustomPolygon(
      name: 'Point ${_customPolygons.where((p) => p.isMarker).length + 1}',
      description: '',
      points: [position],
      color: Colors.red,
      type: MapElementType.point,
    );
    _customPolygons.add(newMarker);
    _isPlacingMarker = false;
    _hasUnsavedChanges = true;
    if (kDebugMode) {
      print(
          'MapViewProvider: Placed marker at ${position.latitude}, ${position.longitude}');
    }
    notifyListeners();
  }

  void cancelPlacingMarker() {
    _isPlacingMarker = false;
    if (kDebugMode) {
      print('MapViewProvider: Cancelled placing marker');
    }
    notifyListeners();
  }

  // Polygon property updates
  void updatePolygonProperty(int polygonIndex, {String? name, Color? color}) {
    if (polygonIndex >= _customPolygons.length) return;

    final currentPolygon = _customPolygons[polygonIndex];
    final updatedPolygon = currentPolygon.copyWith(
      name: name ?? currentPolygon.name,
      color: color ?? currentPolygon.color,
    );
    _customPolygons[polygonIndex] = updatedPolygon;
    if (_selectedPolygonIndex == polygonIndex) {
      _selectedCustomPolygon = updatedPolygon;
    }
    _hasUnsavedChanges = true;
    if (kDebugMode) {
      print('MapViewProvider: Updated polygon $polygonIndex properties');
    }
    notifyListeners();
  }

  // Polygon deletion
  void deletePolygon(int polygonIndex) {
    if (polygonIndex >= _customPolygons.length) return;

    _customPolygons.removeAt(polygonIndex);
    if (_selectedPolygonIndex == polygonIndex) {
      _selectedPolygonIndex = null;
      _selectedCustomPolygon = null;
    } else if (_selectedPolygonIndex != null &&
        _selectedPolygonIndex! > polygonIndex) {
      _selectedPolygonIndex = _selectedPolygonIndex! - 1;
    }
    _hasUnsavedChanges = true;
    print('MapViewProvider: Deleted polygon $polygonIndex');
    notifyListeners();
  }

  // Map center management
  void updateCenter(LatLng newCenter) {
    _center = newCenter;
    notifyListeners();
  }

  void markInitiallyPositioned() {
    _hasInitiallyPositioned = true;
    notifyListeners();
  }

  void resetInitialPositioning() {
    _hasInitiallyPositioned = false;
  }

  // Sidebar management
  void toggleSidebar() {
    _isSidebarVisible = !_isSidebarVisible;
    print('MapViewProvider: Sidebar visibility toggled to $_isSidebarVisible');
    notifyListeners();
  }

  // Polygon selection
  void selectPolygon(int polygonIndex) {
    if (polygonIndex >= _customPolygons.length) return;

    _selectedPolygonIndex = polygonIndex;
    _selectedCustomPolygon = _customPolygons[polygonIndex];
    notifyListeners();
  }

  void deselectPolygon() {
    _selectedPolygonIndex = null;
    _selectedCustomPolygon = null;
    notifyListeners();
  }

  // Bulk updates
  void updateAllPolygons(List<CustomPolygon> polygons) {
    _customPolygons = List.from(polygons);
    notifyListeners();
  }

  void clearUnsavedChanges() {
    _hasUnsavedChanges = false;
    notifyListeners();
  }

  void markAsInitiallyPositioned() {
    _hasInitiallyPositioned = true;
    notifyListeners();
  }

  void resetMapState() {
    _isPopupVisible = false;
    _selectedPolygonIndex = null;
    _selectedCustomPolygon = null;
    _isEditing = false;
    _editingPoints.clear();
    _hasUnsavedChanges = false;
    _isCreatingNewPolygon = false;
    _newPolygonPoints.clear();
    _isPlacingMarker = false;
    _customPolygons.clear();
    _center = const LatLng(-33.925, 18.425);
    _hasInitiallyPositioned = false;
    _isSidebarVisible = true;
    print('MapViewProvider: Reset all map state');
    notifyListeners();
  }
}
