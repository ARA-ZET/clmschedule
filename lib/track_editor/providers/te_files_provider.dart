// track_editor/providers/te_files_provider.dart
import 'package:flutter/material.dart';

class TEFilesProvider extends ChangeNotifier {
  List<String> _selectedFileNames = [];
  List<String> get selectedFileNames => _selectedFileNames;

  void clearFileNames() {
    _selectedFileNames.clear();
    notifyListeners();
  }

  void setFileNames(List<String> fileNames) {
    _selectedFileNames = fileNames;
    notifyListeners();
  }

  void addFileNames(List<String> fileNames) {
    _selectedFileNames.addAll(fileNames);
    notifyListeners();
  }

  void removeFileNames(List<String> fileNames) {
    _selectedFileNames.removeWhere((f) => fileNames.contains(f));
    notifyListeners();
  }

  void removeFileNameAt(int index) {
    if (index >= 0 && index < _selectedFileNames.length) {
      _selectedFileNames.removeAt(index);
      notifyListeners();
    }
  }
}
