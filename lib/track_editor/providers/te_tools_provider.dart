// track_editor/providers/te_tools_provider.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

final teToolsRiverpod = riverpod.ChangeNotifierProvider<TEToolsProvider>(
    (ref) => TEToolsProvider());

/// Active drawing tool for the map.
enum TEDrawingMode {
  none,
  polygon,
  point,
}

/// Holds the active state of map tools (scissors, drawing, future tools) so both
/// the tab bar and the map widget can read/write the same state.
class TEToolsProvider extends ChangeNotifier {
  bool _scissorsMode = false;
  TEDrawingMode _drawingMode = TEDrawingMode.none;

  bool get scissorsMode => _scissorsMode;
  TEDrawingMode get drawingMode => _drawingMode;
  bool get isDrawing => _drawingMode != TEDrawingMode.none;

  void toggleScissors() {
    _scissorsMode = !_scissorsMode;
    if (_scissorsMode) _drawingMode = TEDrawingMode.none;
    notifyListeners();
  }

  void disableScissors() {
    if (_scissorsMode) {
      _scissorsMode = false;
      notifyListeners();
    }
  }

  void setDrawingMode(TEDrawingMode mode) {
    _drawingMode = mode;
    if (mode != TEDrawingMode.none) _scissorsMode = false;
    notifyListeners();
  }

  void toggleDrawPolygon() {
    _drawingMode = _drawingMode == TEDrawingMode.polygon
        ? TEDrawingMode.none
        : TEDrawingMode.polygon;
    if (_drawingMode != TEDrawingMode.none) _scissorsMode = false;
    notifyListeners();
  }

  void toggleDrawPoint() {
    _drawingMode = _drawingMode == TEDrawingMode.point
        ? TEDrawingMode.none
        : TEDrawingMode.point;
    if (_drawingMode != TEDrawingMode.none) _scissorsMode = false;
    notifyListeners();
  }

  void cancelDrawing() {
    _drawingMode = TEDrawingMode.none;
    notifyListeners();
  }
}
