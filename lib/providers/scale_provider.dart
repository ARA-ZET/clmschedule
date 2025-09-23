import 'package:flutter/foundation.dart';

class ScaleProvider extends ChangeNotifier {
  double _scale = 1.0;
  static const double minScale = 0.5;
  static const double maxScale = 2.0;

  double get scale => _scale;

  // Scale bounds helpers
  bool get canIncrease => _scale < maxScale;
  bool get canDecrease => _scale > minScale;

  // Font sizes
  double get baseFontSize => 14.0 * _scale;
  double get smallFontSize => 8.0 * _scale;
  double get mediumFontSize => 10.0 * _scale;
  double get largeFontSize => 16.0 * _scale;
  double get xlargeFontSize => 20.0 * _scale;

  // Icon sizes
  double get smallIconSize => 16.0 * _scale;
  double get mediumIconSize => 20.0 * _scale;
  double get largeIconSize => 24.0 * _scale;
  double get xlargeIconSize => 60.0 * _scale;

  // Button and component sizes
  double get buttonHeight => 48.0 * _scale;
  double get cardPadding => 8.0 * _scale;
  double get spacing => 8.0 * _scale;

  void setScale(double newScale) {
    if (newScale >= minScale && newScale <= maxScale) {
      _scale = newScale;
      notifyListeners();
    }
  }

  void increaseScale() {
    setScale((_scale + 0.1).clamp(minScale, maxScale));
  }

  void decreaseScale() {
    setScale((_scale - 0.1).clamp(minScale, maxScale));
  }

  void resetScale() {
    setScale(1.0);
  }
}
