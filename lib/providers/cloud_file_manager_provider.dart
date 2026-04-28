// providers/cloud_file_manager_provider.dart
//
// State management for browsing Cloud Storage folders and files.
// Root: "Distribution/" — navigates year → month → client → round → files.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/gpx_storage_service.dart';

/// Hierarchy depth constants for the folder structure:
/// 0: Distribution (root)
/// 1: Year (e.g. 2026)
/// 2: Month (e.g. Apr 2026)
/// 3: Client name
/// 4: Round (e.g. Round 1)
/// 5+: Sub-folders inside a round
enum FolderLevel { root, year, month, client, round, sub }

class CloudFileManagerProvider with ChangeNotifier {
  final GpxStorageService _storage = GpxStorageService();

  static const String rootPath = 'Distribution';

  // Navigation stack — each entry is (folderPath, displayName)
  final List<({String path, String name})> _breadcrumbs = [
    (path: rootPath, name: 'Distribution'),
  ];

  List<StorageFolderItem> _folders = [];
  List<StorageFileItem> _files = [];
  bool _isLoading = false;
  String? _error;

  // Getters
  List<({String path, String name})> get breadcrumbs =>
      List.unmodifiable(_breadcrumbs);
  String get currentPath => _breadcrumbs.last.path;
  String get currentName => _breadcrumbs.last.name;
  List<StorageFolderItem> get folders => _folders;
  List<StorageFileItem> get files => _files;
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get isAtRoot => _breadcrumbs.length <= 1;
  int get depth => _breadcrumbs.length;

  /// Current folder level in the hierarchy.
  FolderLevel get currentLevel {
    // depth 1 = at root (Distribution), depth 2 = inside a year, etc.
    switch (depth) {
      case 1:
        return FolderLevel.root;
      case 2:
        return FolderLevel.year;
      case 3:
        return FolderLevel.month;
      case 4:
        return FolderLevel.client;
      case 5:
        return FolderLevel.round;
      default:
        return FolderLevel.sub;
    }
  }

  /// Label describing what kind of folder can be created at this level.
  String get newFolderLabel {
    switch (currentLevel) {
      case FolderLevel.root:
        return 'Year';
      case FolderLevel.year:
        return 'Month';
      case FolderLevel.month:
        return 'Client';
      case FolderLevel.client:
        return 'Round';
      case FolderLevel.round:
      case FolderLevel.sub:
        return 'Folder';
    }
  }

  /// Suggested default names for new folders at this level.
  List<String> get suggestedFolderNames {
    final now = DateTime.now();
    switch (currentLevel) {
      case FolderLevel.root:
        // Suggest current year ± 1
        final y = now.year;
        return ['$y', '${y + 1}', '${y - 1}'];
      case FolderLevel.year:
        // Suggest months in "MMM YYYY" format
        final existingNames = _folders.map((f) => f.name).toSet();
        final suggestions = <String>[];
        for (int m = 1; m <= 12; m++) {
          final date = DateTime(now.year, m);
          final label = DateFormat('MMM yyyy').format(date);
          if (!existingNames.contains(label)) {
            suggestions.add(label);
          }
        }
        return suggestions;
      case FolderLevel.month:
        // Client name — no suggestions, free text
        return [];
      case FolderLevel.client:
        // Suggest next round number
        final existingRounds = _folders
            .map((f) => RegExp(r'^Round (\d+)$').firstMatch(f.name))
            .where((m) => m != null)
            .map((m) => int.parse(m!.group(1)!))
            .toList();
        final nextRound = existingRounds.isEmpty
            ? 1
            : (existingRounds.reduce((a, b) => a > b ? a : b) + 1);
        return ['Round $nextRound'];
      case FolderLevel.round:
      case FolderLevel.sub:
        return [];
    }
  }

  /// Load the current folder contents.
  Future<void> loadCurrentFolder() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final contents = await _storage.listFolderContents(currentPath);
      _folders = contents.folders;
      _files = contents.files;
    } catch (e) {
      _error = 'Failed to load folder: $e';
      debugPrint(_error);
    }

    _isLoading = false;
    notifyListeners();
  }

  /// Navigate into a subfolder.
  Future<void> openFolder(StorageFolderItem folder) async {
    _breadcrumbs.add((path: folder.fullPath, name: folder.name));
    await loadCurrentFolder();
  }

  /// Navigate back one level.
  Future<void> goBack() async {
    if (_breadcrumbs.length > 1) {
      _breadcrumbs.removeLast();
      await loadCurrentFolder();
    }
  }

  /// Navigate to a specific breadcrumb level.
  Future<void> goToBreadcrumb(int index) async {
    if (index < 0 || index >= _breadcrumbs.length) return;
    while (_breadcrumbs.length > index + 1) {
      _breadcrumbs.removeLast();
    }
    await loadCurrentFolder();
  }

  /// Download a file as bytes.
  Future<Uint8List?> downloadFile(StorageFileItem file) async {
    return _storage.downloadFileBytes(file.fullPath);
  }

  /// Download a file as string content (for GPX/KML).
  Future<String?> downloadFileAsString(StorageFileItem file) async {
    final bytes = await _storage.downloadFileBytes(file.fullPath);
    if (bytes != null) return String.fromCharCodes(bytes);
    return null;
  }

  /// Delete a file and refresh the folder.
  Future<void> deleteFile(StorageFileItem file) async {
    try {
      await _storage.deleteFile(file.fullPath);
      await loadCurrentFolder();
    } catch (e) {
      _error = 'Failed to delete: $e';
      debugPrint(_error);
      notifyListeners();
    }
  }

  /// Delete many files. Returns the number successfully deleted.
  /// Also triggers a compiled-waypoints rebuild per affected folder.
  Future<int> deleteFiles(Iterable<StorageFileItem> files) async {
    final affectedFolders = <String>{};
    int ok = 0;
    for (final f in files) {
      try {
        await _storage.deleteFile(f.fullPath);
        ok++;
        final slash = f.fullPath.lastIndexOf('/');
        if (slash > 0) affectedFolders.add(f.fullPath.substring(0, slash));
      } catch (e) {
        debugPrint('deleteFiles: failed ${f.fullPath}: $e');
      }
    }
    await _rebuildCompiledFor(affectedFolders);
    await loadCurrentFolder();
    return ok;
  }

  /// Rename a file inside its current folder. Returns the new full path
  /// on success or `null` on failure.
  Future<String?> renameFile(StorageFileItem file, String newName) async {
    final sanitized = newName.trim();
    if (sanitized.isEmpty || sanitized == file.name) return null;
    try {
      final newPath = await _storage.renameFile(file.fullPath, sanitized);
      // Rename inside a waypoint folder → the compiled aggregate lists a
      // `sourceFile`, so regenerate it.
      final slash = file.fullPath.lastIndexOf('/');
      if (slash > 0) {
        await _rebuildCompiledFor({file.fullPath.substring(0, slash)});
      }
      await loadCurrentFolder();
      return newPath;
    } catch (e) {
      _error = 'Failed to rename: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  /// Copy files into [destinationFolder]. Returns how many succeeded.
  Future<int> copyFiles(
    Iterable<StorageFileItem> files,
    String destinationFolder,
  ) async {
    int ok = 0;
    for (final f in files) {
      final dst = '$destinationFolder/${f.name}';
      if (dst == f.fullPath) continue; // skip copy to self
      try {
        await _storage.copyFile(f.fullPath, dst);
        ok++;
      } catch (e) {
        debugPrint('copyFiles: failed ${f.fullPath} → $dst: $e');
      }
    }
    await _rebuildCompiledFor({destinationFolder});
    await loadCurrentFolder();
    return ok;
  }

  /// Move files into [destinationFolder]. Returns how many succeeded.
  Future<int> moveFiles(
    Iterable<StorageFileItem> files,
    String destinationFolder,
  ) async {
    final affectedFolders = <String>{destinationFolder};
    int ok = 0;
    for (final f in files) {
      final dst = '$destinationFolder/${f.name}';
      if (dst == f.fullPath) continue;
      try {
        await _storage.moveFile(f.fullPath, dst);
        ok++;
        final slash = f.fullPath.lastIndexOf('/');
        if (slash > 0) affectedFolders.add(f.fullPath.substring(0, slash));
      } catch (e) {
        debugPrint('moveFiles: failed ${f.fullPath} → $dst: $e');
      }
    }
    await _rebuildCompiledFor(affectedFolders);
    await loadCurrentFolder();
    return ok;
  }

  /// List every folder path under the Distribution root. Useful as the data
  /// source for a move/copy-destination picker.
  Future<List<String>> listAllFolderPaths() =>
      _storage.listAllFolderPaths(rootPath: rootPath);

  /// Trigger a compiled-waypoints and compiled-tracks rebuild for each
  /// folder, skipping any operations that the storage service cannot
  /// service.
  Future<void> _rebuildCompiledFor(Iterable<String> folders) async {
    for (final f in folders) {
      if (f.isEmpty) continue;
      try {
        await _storage.regenerateCompiledWaypoints(f);
      } catch (e) {
        debugPrint('_rebuildCompiledFor($f) waypoints: $e');
      }
      try {
        await _storage.regenerateCompiledTracks(f);
      } catch (e) {
        debugPrint('_rebuildCompiledFor($f) tracks: $e');
      }
    }
  }

  /// Recursively delete a folder (all files and subfolders) and refresh.
  /// Returns the number of files removed, or `null` if the operation failed.
  Future<int?> deleteFolder(StorageFolderItem folder) async {
    try {
      final removed = await _storage.deleteFolderRecursive(folder.fullPath);
      await loadCurrentFolder();
      return removed;
    } catch (e) {
      _error = 'Failed to delete folder: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  /// Upload a file to the current folder and refresh.
  Future<String?> uploadFile(
      String fileName, Uint8List bytes, String? contentType) async {
    try {
      final url = await _storage.uploadFileBytes(currentPath, fileName, bytes,
          contentType: contentType);
      await loadCurrentFolder();
      return url;
    } catch (e) {
      _error = 'Failed to upload: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    }
  }

  /// Create a new subfolder in the current directory and refresh.
  Future<bool> createFolder(String folderName) async {
    final sanitized = folderName.trim();
    if (sanitized.isEmpty) return false;

    try {
      final newPath = '$currentPath/$sanitized';
      await _storage.createFolder(newPath);
      await loadCurrentFolder();
      return true;
    } catch (e) {
      _error = 'Failed to create folder: $e';
      debugPrint(_error);
      notifyListeners();
      return false;
    }
  }

  /// Reset to root.
  Future<void> goToRoot() async {
    _breadcrumbs.clear();
    _breadcrumbs.add((path: rootPath, name: 'Distribution'));
    await loadCurrentFolder();
  }

  /// Navigate directly to a specific folder path, building breadcrumbs from
  /// the path segments. E.g. "Distribution/2026/Apr 2026/Client/Round 1"
  /// produces breadcrumbs: Distribution > 2026 > Apr 2026 > Client > Round 1.
  Future<void> navigateToPath(String folderPath) async {
    _breadcrumbs.clear();
    final segments = folderPath.split('/').where((s) => s.isNotEmpty).toList();
    var accumulated = '';
    for (final seg in segments) {
      accumulated = accumulated.isEmpty ? seg : '$accumulated/$seg';
      _breadcrumbs.add((path: accumulated, name: seg));
    }
    if (_breadcrumbs.isEmpty) {
      _breadcrumbs.add((path: rootPath, name: 'Distribution'));
    }
    await loadCurrentFolder();
  }
}
