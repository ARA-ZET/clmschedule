// providers/cloud_file_manager_provider.dart
//
// State management for browsing Cloud Storage folders and files.
// Root: "Distribution/" — navigates year → month → client → round → files.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/gpx_storage_service.dart';
import '../shareable_maps/services/shareable_maps_firestore_service.dart';

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

  // Bulk-task progress state. While [_taskTotal] > 0 a long-running
  // batch operation (upload/copy/move/delete) is in progress and the UI
  // can show a progress dialog driven by these fields.
  String _taskLabel = '';
  int _taskTotal = 0;
  int _taskCompleted = 0;
  String _taskCurrentItem = '';
  String _taskDetail = '';

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

  // Bulk-task progress getters.
  bool get isTaskRunning => _taskTotal > 0;
  String get taskLabel => _taskLabel;
  int get taskTotal => _taskTotal;
  int get taskCompleted => _taskCompleted;
  String get taskCurrentItem => _taskCurrentItem;
  String get taskDetail => _taskDetail;
  double get taskProgress =>
      _taskTotal == 0 ? 0.0 : (_taskCompleted / _taskTotal).clamp(0.0, 1.0);

  void _beginTask(String label, int total) {
    _taskLabel = label;
    _taskTotal = total;
    _taskCompleted = 0;
    _taskCurrentItem = '';
    _taskDetail = '';
    notifyListeners();
  }

  void _updateTask({String? currentItem, String? detail, int? completed}) {
    if (currentItem != null) _taskCurrentItem = currentItem;
    if (detail != null) _taskDetail = detail;
    if (completed != null) _taskCompleted = completed;
    notifyListeners();
  }

  void _endTask() {
    _taskLabel = '';
    _taskTotal = 0;
    _taskCompleted = 0;
    _taskCurrentItem = '';
    _taskDetail = '';
    notifyListeners();
  }

  /// Run [task] over [items] with at most [concurrency] in flight.
  /// Increments task progress as each item completes.
  Future<List<R>> _runWithLimit<T, R>(
    List<T> items,
    int concurrency,
    Future<R> Function(T item) task,
  ) async {
    final results = List<R?>.filled(items.length, null);
    int next = 0;

    Future<void> worker() async {
      while (true) {
        final idx = next++;
        if (idx >= items.length) return;
        try {
          results[idx] = await task(items[idx]);
        } catch (e) {
          debugPrint('_runWithLimit task failed: $e');
        } finally {
          _taskCompleted++;
          notifyListeners();
        }
      }
    }

    final workers = List.generate(
      concurrency.clamp(1, items.isEmpty ? 1 : items.length),
      (_) => worker(),
    );
    await Future.wait(workers);
    return results.whereType<R>().toList();
  }

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

  /// Delete many files in parallel. Returns the number successfully deleted.
  /// The Storage Cloud Function recompiles `_compiled_*.json` automatically
  /// when GPX files are deleted, so we no longer wait on a client-side
  /// rebuild here (that would re-download every remaining GPX in the
  /// folder and made deletes feel slow).
  Future<int> deleteFiles(Iterable<StorageFileItem> files) async {
    final list = files.toList();
    if (list.isEmpty) return 0;
    _beginTask('Deleting files', list.length);
    int ok = 0;
    try {
      await _runWithLimit<StorageFileItem, bool>(list, 6, (f) async {
        _updateTask(currentItem: f.name);
        try {
          await _storage.deleteFile(f.fullPath);
          ok++;
          return true;
        } catch (e) {
          debugPrint('deleteFiles: failed ${f.fullPath}: $e');
          return false;
        }
      });
    } finally {
      _endTask();
    }
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

  /// Copy files into [destinationFolder] in parallel.
  /// Returns how many succeeded.
  /// The Cloud Function compiles `_compiled_*.json` in the destination
  /// folder automatically as the new GPX files land there. We also trigger
  /// a client-side rebuild for immediate feedback.
  Future<int> copyFiles(
    Iterable<StorageFileItem> files,
    String destinationFolder,
  ) async {
    final list = files.toList();
    if (list.isEmpty) return 0;
    _beginTask('Copying to ${_shortFolder(destinationFolder)}', list.length);
    int ok = 0;
    final copiedGpxFolders = <String>{};
    try {
      await _runWithLimit<StorageFileItem, bool>(list, 4, (f) async {
        final dst = '$destinationFolder/${f.name}';
        if (dst == f.fullPath) return false; // skip copy to self
        _updateTask(currentItem: f.name);
        try {
          await _storage.copyFile(f.fullPath, dst);
          ok++;
          if (f.extension == 'gpx') copiedGpxFolders.add(destinationFolder);
          return true;
        } catch (e) {
          debugPrint('copyFiles: failed ${f.fullPath} \u2192 $dst: $e');
          return false;
        }
      });
    } finally {
      _endTask();
    }
    await loadCurrentFolder();
    if (copiedGpxFolders.isNotEmpty) {
      unawaited(_rebuildCompiledFor(copiedGpxFolders));
    }
    return ok;
  }

  /// Move files into [destinationFolder] in parallel.
  /// Returns how many succeeded. The Cloud Function rebuilds compiled JSON
  /// in both the source and destination folders automatically. We also
  /// trigger a client-side rebuild for immediate feedback.
  Future<int> moveFiles(
    Iterable<StorageFileItem> files,
    String destinationFolder,
  ) async {
    final list = files.toList();
    if (list.isEmpty) return 0;
    final sourceFolder = currentPath;
    _beginTask('Moving to ${_shortFolder(destinationFolder)}', list.length);
    int ok = 0;
    final movedGpxFolders = <String>{};
    try {
      await _runWithLimit<StorageFileItem, bool>(list, 4, (f) async {
        final dst = '$destinationFolder/${f.name}';
        if (dst == f.fullPath) return false;
        _updateTask(currentItem: f.name);
        try {
          await _storage.moveFile(f.fullPath, dst);
          ok++;
          if (f.extension == 'gpx') {
            movedGpxFolders.add(sourceFolder);
            movedGpxFolders.add(destinationFolder);
          }
          return true;
        } catch (e) {
          debugPrint('moveFiles: failed ${f.fullPath} \u2192 $dst: $e');
          return false;
        }
      });
    } finally {
      _endTask();
    }
    await loadCurrentFolder();
    if (movedGpxFolders.isNotEmpty) {
      unawaited(_rebuildCompiledFor(movedGpxFolders));
    }
    return ok;
  }

  /// Last segment of a folder path, for display in progress labels.
  String _shortFolder(String path) {
    final slash = path.lastIndexOf('/');
    return slash >= 0 ? path.substring(slash + 1) : path;
  }

  /// List every folder path under the Distribution root. Useful as the data
  /// source for a move/copy-destination picker.
  Future<List<String>> listAllFolderPaths() =>
      _storage.listAllFolderPaths(rootPath: rootPath);

  /// List the immediate subfolders of [folderPath]. Used by the navigator
  /// destination-folder picker so each level is loaded on demand instead of
  /// fetching the entire tree at once.
  Future<List<StorageFolderItem>> listSubfolders(String folderPath) =>
      _storage.listSubfolders(folderPath);

  /// Trigger a compiled-tracks + compiled-waypoints rebuild for each folder.
  /// Used by callers (e.g. the track editor) that want an immediate local
  /// rebuild without waiting for the Storage Cloud Function. Skipped on
  /// failure rather than failing the surrounding operation.
  Future<void> _rebuildCompiledFor(Iterable<String> folders) async {
    for (final f in folders) {
      if (f.isEmpty) continue;
      try {
        await _storage.regenerateCompiledFiles(f);
      } catch (e) {
        debugPrint('_rebuildCompiledFor($f): $e');
      }
    }
  }

  /// Rename a folder by recursively copying its contents to a new name under
  /// the same parent, then deleting the original. Also updates every Firestore
  /// document (shareable maps, job list items) that referenced the old path so
  /// links remain valid after the rename.
  ///
  /// Returns `({newPath, mapsUpdated, jobsUpdated})`. `newPath` is `null` on
  /// failure.
  Future<({String? newPath, int mapsUpdated, int jobsUpdated})> renameFolder(
      StorageFolderItem folder, String newName) async {
    final sanitized = newName.trim();
    if (sanitized.isEmpty || sanitized == folder.name) {
      return (newPath: null, mapsUpdated: 0, jobsUpdated: 0);
    }
    try {
      final newPath = await _storage.renameFolder(folder.fullPath, sanitized);

      // Update Firestore references to point to the new folder path so
      // shareable maps and job list items keep loading their cloud data.
      final refs = await ShareableMapsFirestoreService()
          .updateFolderPathReference(folder.fullPath, newPath);

      // Rebuild compiled tracks/waypoints in the new folder.
      unawaited(_rebuildCompiledFor({newPath}));

      await loadCurrentFolder();
      return (
        newPath: newPath,
        mapsUpdated: refs.maps,
        jobsUpdated: refs.jobs,
      );
    } catch (e) {
      _error = 'Failed to rename folder: $e';
      debugPrint(_error);
      notifyListeners();
      return (newPath: null, mapsUpdated: 0, jobsUpdated: 0);
    }
  }

  /// Download the entire [folder] tree as a ZIP archive.
  /// Returns the raw ZIP bytes, or `null` on failure.
  /// Task progress is reported via [taskCompleted] / [taskTotal].
  Future<Uint8List?> downloadFolderAsZip(StorageFolderItem folder) async {
    _beginTask('Downloading \u201c${folder.name}\u201d\u2026', 0);
    try {
      final bytes = await _storage.downloadFolderAsZip(
        folder.fullPath,
        onProgress: (done, total) {
          _taskTotal = total;
          _taskCompleted = done;
          _taskCurrentItem = '';
          notifyListeners();
        },
      );
      return bytes;
    } catch (e) {
      _error = 'Download failed: $e';
      debugPrint(_error);
      notifyListeners();
      return null;
    } finally {
      _endTask();
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

  /// Upload many files to the current folder in parallel with progress.
  /// The Cloud Function compiles `_compiled_tracks.json` and
  /// `_compiled_waypoints.json` automatically once the new GPX files land,
  /// so multi-file uploads always end up with up-to-date compiled aggregates.
  /// Returns the number of files that uploaded successfully.
  Future<int> uploadFiles(
    List<({String name, Uint8List bytes, String? contentType})> entries,
  ) async {
    if (entries.isEmpty) return 0;
    _beginTask('Uploading files', entries.length);
    int ok = 0;
    final folder = currentPath;
    try {
      await _runWithLimit<({String name, Uint8List bytes, String? contentType}),
          bool>(entries, 4, (e) async {
        _updateTask(currentItem: e.name);
        try {
          await _storage.uploadFileBytes(folder, e.name, e.bytes,
              contentType: e.contentType);
          ok++;
          return true;
        } catch (err) {
          debugPrint('uploadFiles: failed ${e.name}: $err');
          return false;
        }
      });
    } finally {
      _endTask();
    }
    await loadCurrentFolder();
    return ok;
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
