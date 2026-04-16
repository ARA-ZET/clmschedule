// track_editor/providers/te_tools_provider.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

final teToolsRiverpod = riverpod.ChangeNotifierProvider<TEToolsProvider>(
    (ref) => TEToolsProvider());

/// Holds the active state of map tools (scissors, future tools) so both
/// the tab bar and the map widget can read/write the same state.
class TEToolsProvider extends ChangeNotifier {
  bool _scissorsMode = false;

  bool get scissorsMode => _scissorsMode;

  void toggleScissors() {
    _scissorsMode = !_scissorsMode;
    notifyListeners();
  }

  void disableScissors() {
    if (_scissorsMode) {
      _scissorsMode = false;
      notifyListeners();
    }
  }
}
