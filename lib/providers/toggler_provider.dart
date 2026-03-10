import 'package:flutter/material.dart';

class TogglerProvider with ChangeNotifier {
  bool _isFullviewSchedule = false;
  bool _isFullviewCollection = false;

  bool get isFullviewCollection => _isFullviewCollection;
  bool get isFullviewSchedule => _isFullviewSchedule;

  void toggleFullview(Mode mode) {
    if (mode == Mode.collection) {
      _isFullviewCollection = !_isFullviewCollection;
    } else if (mode == Mode.schedule) {
      _isFullviewSchedule = !_isFullviewSchedule;
    }
    notifyListeners();
  }
}

enum Mode { collection, joblist, schedule }
