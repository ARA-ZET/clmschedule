// track_editor/providers/te_files_provider.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'te_mode_provider.dart';

final teFilesRiverpod = riverpod.ChangeNotifierProvider<TEFilesProvider>(
    (ref) => TEFilesProvider());

class TEFilesProvider extends ChangeNotifier {
  final Map<TEMode, List<String>> _filesByMode = {
    TEMode.import: [],
    TEMode.trim: [],
    TEMode.processing: [],
    TEMode.update: [],
  };
  TEMode _activeMode = TEMode.processing;

  List<String> get selectedFileNames => _filesByMode[_activeMode]!;

  void setActiveMode(TEMode mode) {
    if (_activeMode == mode) return;
    _activeMode = mode;
    notifyListeners();
  }

  void clearFileNames() {
    _filesByMode[_activeMode]!.clear();
    notifyListeners();
  }

  void setFileNames(List<String> fileNames) {
    _filesByMode[_activeMode] = fileNames;
    notifyListeners();
  }

  void addFileNames(List<String> fileNames) {
    _filesByMode[_activeMode]!.addAll(fileNames);
    notifyListeners();
  }

  void removeFileNames(List<String> fileNames) {
    _filesByMode[_activeMode]!.removeWhere((f) => fileNames.contains(f));
    notifyListeners();
  }

  void removeFileNameAt(int index) {
    final list = _filesByMode[_activeMode]!;
    if (index >= 0 && index < list.length) {
      list.removeAt(index);
      notifyListeners();
    }
  }

  /// Clear files across all modes.
  void clearAll() {
    for (final mode in TEMode.values) {
      _filesByMode[mode]!.clear();
    }
    notifyListeners();
  }
}
