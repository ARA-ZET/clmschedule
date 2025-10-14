import 'package:flutter/material.dart';

class TogglerProvider with ChangeNotifier {
  bool _isFullview = false;

  bool get isFullview => _isFullview;

  void toggleFullview() {
    _isFullview = !_isFullview;
    notifyListeners();
  }

  void setFullview(bool value) {
    _isFullview = value;
    notifyListeners();
  }
}
