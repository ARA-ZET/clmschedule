// track_editor/providers/te_view_provider.dart
//
// Which of the two right-hand panes the distributor tab is showing: the
// editable map, or the analysis of the loaded tracklog and handout waypoints.
// Deliberately NOT per-mode (unlike the tabs/tracks/waypoints providers) —
// it is a view preference, so it stays put as the user moves between tabs.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

enum TEPaneView { map, analysis }

/// What the chart's second line tracks, alongside speed. One or the other —
/// never both at once, so the chart never grows a third axis.
enum TESecondarySeries { handouts, distance }

final teViewRiverpod =
    riverpod.ChangeNotifierProvider<TEViewProvider>((ref) => TEViewProvider());

class TEViewProvider extends ChangeNotifier {
  TEPaneView _view = TEPaneView.map;

  /// True when the analysis chart draws speed and the second series in a
  /// single plot with two y-axes; false when they are stacked as two plots
  /// sharing the time axis.
  bool _overlaySeries = true;

  TESecondarySeries _secondary = TESecondarySeries.handouts;

  TEPaneView get view => _view;
  bool get overlaySeries => _overlaySeries;
  TESecondarySeries get secondary => _secondary;

  void setView(TEPaneView v) {
    if (_view == v) return;
    _view = v;
    notifyListeners();
  }

  void toggleView() =>
      setView(_view == TEPaneView.map ? TEPaneView.analysis : TEPaneView.map);

  void setOverlaySeries(bool value) {
    if (_overlaySeries == value) return;
    _overlaySeries = value;
    notifyListeners();
  }

  void setSecondary(TESecondarySeries value) {
    if (_secondary == value) return;
    _secondary = value;
    notifyListeners();
  }
}
