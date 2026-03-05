import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

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
