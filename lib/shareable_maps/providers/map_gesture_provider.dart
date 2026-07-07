import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Riverpod provider for MapGestureProvider.
final mapGestureRiverpod = riverpod.ChangeNotifierProvider<MapGestureProvider>(
    (ref) => MapGestureProvider());

/// Provider to manage web gesture handling for Google Maps
/// Controls whether map gestures should be enabled based on mouse position over UI widgets
class MapGestureProvider extends ChangeNotifier {
  WebGestureHandling _gestureHandling = WebGestureHandling.greedy;

  /// Current web gesture handling mode
  WebGestureHandling get gestureHandling => _gestureHandling;

  /// Set gesture handling to none (when mouse is over UI widgets)
  void disableMapGestures() {
    if (_gestureHandling != WebGestureHandling.none) {
      _gestureHandling = WebGestureHandling.none;
      debugPrint('Map gestures disabled');
      notifyListeners();
    }
  }

  /// Set gesture handling to greedy (when mouse is over map)
  void enableMapGestures() {
    if (_gestureHandling != WebGestureHandling.greedy) {
      _gestureHandling = WebGestureHandling.greedy;

      notifyListeners();
    }
  }
}

/// Riverpod provider for WidgetOverPolygonNotifier.
final widgetOverPolygonRiverpod =
    riverpod.ChangeNotifierProvider<WidgetOverPolygonNotifier>(
        (ref) => WidgetOverPolygonNotifier());

/// Tracks whether the mouse cursor is currently over a UI widget that is
/// positioned on top of a polygon layer. When true, polygon/polyline onTap
/// handlers return null so taps are not consumed by the map element beneath.
class WidgetOverPolygonNotifier extends ChangeNotifier {
  bool _isOver = false;

  bool get isOver => _isOver;

  void enable() {
    if (!_isOver) {
      _isOver = true;
      notifyListeners();
    }
  }

  void disable() {
    if (_isOver) {
      _isOver = false;
      notifyListeners();
    }
  }
}
