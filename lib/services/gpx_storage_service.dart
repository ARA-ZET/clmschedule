// services/gpx_storage_service.dart
//
// Manages GPX track/waypoint files in Firebase Cloud Storage.
// Folder structure: Distribution/{year}/{MMM YYYY}/{clientName}/Round {N}/
import 'dart:convert';

import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';

class GpxStorageService {
  static GpxStorageService? _instance;
  GpxStorageService._internal();
  factory GpxStorageService() => _instance ??= GpxStorageService._internal();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  /// Root prefix for all distribution files.
  static const String _root = 'Distribution';

  // ── Path building ─────────────────────────────────────────────────────────

  /// Build the base client folder path for a given date and client name.
  /// Example: Distribution/2026/Apr 2026/Seeff
  String clientFolderPath(DateTime date, String clientName) {
    final year = date.year.toString();
    final monthLabel = DateFormat('MMM yyyy').format(date); // "Apr 2026"
    final safeName = _sanitize(clientName);
    return '$_root/$year/$monthLabel/$safeName';
  }

  /// Build a round folder path.
  /// Example: Distribution/2026/Apr 2026/Seeff/Round 1
  String roundFolderPath(DateTime date, String clientName, int round) {
    return '${clientFolderPath(date, clientName)}/Round $round';
  }

  // ── Round management ──────────────────────────────────────────────────────

  /// Determine the next round number for a client by checking existing folders.
  /// Returns 1 if no rounds exist yet.
  Future<int> nextRoundNumber(DateTime date, String clientName) async {
    final basePath = clientFolderPath(date, clientName);
    try {
      final result = await _storage.ref(basePath).listAll();
      // Count prefixes matching "Round N"
      int maxRound = 0;
      for (final prefix in result.prefixes) {
        final name = prefix.name; // "Round 1", "Round 2", etc.
        final match = RegExp(r'^Round (\d+)$').firstMatch(name);
        if (match != null) {
          final n = int.parse(match.group(1)!);
          if (n > maxRound) maxRound = n;
        }
      }
      return maxRound + 1;
    } catch (e) {
      // Folder doesn't exist yet → first round
      debugPrint('nextRoundNumber: $e');
      return 1;
    }
  }

  /// Returns `true` if a client folder already exists under the month folder
  /// for [date] with a case-insensitive name match on [clientName]. Used to
  /// decide whether to default save operations into the existing client
  /// folder or to force the user to pick a folder instead.
  Future<bool> clientFolderExists(DateTime date, String clientName) async {
    final year = date.year.toString();
    final monthLabel = DateFormat('MMM yyyy').format(date);
    final monthPath = '$_root/$year/$monthLabel';
    final needle = _sanitize(clientName).toLowerCase();
    if (needle.isEmpty) return false;
    try {
      final result = await _storage.ref(monthPath).listAll();
      for (final p in result.prefixes) {
        if (p.name.toLowerCase() == needle) return true;
      }
      return false;
    } catch (e) {
      debugPrint('clientFolderExists($clientName): $e');
      return false;
    }
  }

  // ── Upload ────────────────────────────────────────────────────────────────

  /// Upload a GPX file (as string) to the given storage folder path.
  /// Returns the download URL.
  Future<String> uploadGpxFile(
      String folderPath, String fileName, String gpxContent) async {
    final ref = _storage.ref('$folderPath/$fileName');
    final bytes = Uint8List.fromList(gpxContent.codeUnits);
    await ref.putData(
      bytes,
      SettableMetadata(contentType: 'application/gpx+xml'),
    );
    return ref.getDownloadURL();
  }

  // ── List files ────────────────────────────────────────────────────────────

  /// List all files (any type) in a storage folder.
  Future<List<StorageFileItem>> listAllFiles(String folderPath) async {
    try {
      final result = await _storage.ref(folderPath).listAll();
      final files = <StorageFileItem>[];
      for (final item in result.items) {
        files.add(StorageFileItem(
          name: item.name,
          fullPath: item.fullPath,
        ));
      }
      return files;
    } catch (e) {
      debugPrint('listAllFiles error ($folderPath): $e');
      return [];
    }
  }

  /// List all subfolders in a storage folder.
  Future<List<StorageFolderItem>> listSubfolders(String folderPath) async {
    try {
      final result = await _storage.ref(folderPath).listAll();
      return result.prefixes
          .map((p) => StorageFolderItem(name: p.name, fullPath: p.fullPath))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
    } catch (e) {
      debugPrint('listSubfolders error ($folderPath): $e');
      return [];
    }
  }

  /// List both subfolders and files in a storage folder.
  Future<({List<StorageFolderItem> folders, List<StorageFileItem> files})>
      listFolderContents(String folderPath) async {
    try {
      final result = await _storage.ref(folderPath).listAll();
      final folders = result.prefixes
          .map((p) => StorageFolderItem(name: p.name, fullPath: p.fullPath))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final fileItems = await Future.wait(
        result.items.map((item) async {
          try {
            final meta = await item.getMetadata();
            return StorageFileItem(
              name: item.name,
              fullPath: item.fullPath,
              lastModified: meta.updated ?? meta.timeCreated,
              sizeBytes: meta.size,
            );
          } catch (_) {
            return StorageFileItem(
              name: item.name,
              fullPath: item.fullPath,
            );
          }
        }),
      );
      fileItems.sort((a, b) => a.name.compareTo(b.name));
      return (folders: folders, files: fileItems);
    } catch (e) {
      debugPrint('listFolderContents error ($folderPath): $e');
      return (folders: <StorageFolderItem>[], files: <StorageFileItem>[]);
    }
  }

  /// Download any file as bytes.
  Future<Uint8List?> downloadFileBytes(String fullPath) async {
    try {
      return await _storage.ref(fullPath).getData();
    } catch (e) {
      debugPrint('downloadFileBytes error ($fullPath): $e');
      return null;
    }
  }

  /// Upload any file bytes to a folder.
  Future<String> uploadFileBytes(
      String folderPath, String fileName, Uint8List bytes,
      {String? contentType}) async {
    final ref = _storage.ref('$folderPath/$fileName');
    await ref.putData(
      bytes,
      SettableMetadata(contentType: contentType),
    );
    return ref.getDownloadURL();
  }

  /// Create a folder by uploading a hidden placeholder file.
  /// Firebase Storage doesn't have real folders — a folder only exists
  /// while it contains at least one file.
  Future<void> createFolder(String folderPath) async {
    final ref = _storage.ref('$folderPath/.folder');
    await ref.putData(
      Uint8List(0),
      SettableMetadata(contentType: 'application/x-empty'),
    );
  }

  /// List all GPX files in a storage folder.
  /// Returns a list of (name, fullPath, downloadUrl) records.
  Future<List<GpxStorageFile>> listFiles(String folderPath) async {
    try {
      final result = await _storage.ref(folderPath).listAll();
      final files = <GpxStorageFile>[];
      for (final item in result.items) {
        if (item.name.toLowerCase().endsWith('.gpx')) {
          final url = await item.getDownloadURL();
          files.add(GpxStorageFile(
            name: item.name,
            fullPath: item.fullPath,
            downloadUrl: url,
          ));
        }
      }
      return files;
    } catch (e) {
      debugPrint('listFiles error ($folderPath): $e');
      return [];
    }
  }

  /// List all rounds for a client folder.
  Future<List<String>> listRounds(DateTime date, String clientName) async {
    final basePath = clientFolderPath(date, clientName);
    try {
      final result = await _storage.ref(basePath).listAll();
      return result.prefixes
          .map((p) => p.name)
          .where((n) => RegExp(r'^Round \d+$').hasMatch(n))
          .toList()
        ..sort();
    } catch (e) {
      debugPrint('listRounds error: $e');
      return [];
    }
  }

  // ── Download ──────────────────────────────────────────────────────────────

  /// Download a GPX file as string content.
  Future<String?> downloadGpxFile(String fullPath) async {
    try {
      final ref = _storage.ref(fullPath);
      final data = await ref.getData();
      if (data != null) return String.fromCharCodes(data);
    } catch (e) {
      debugPrint('downloadGpxFile error ($fullPath): $e');
    }
    return null;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Delete a single GPX file by full path.
  Future<void> deleteFile(String fullPath) async {
    await _storage.ref(fullPath).delete();
  }

  // ── Rename / Copy / Move ──────────────────────────────────────────────────

  /// Copy a file to another location by streaming its bytes.
  /// Returns the full path of the new file.
  /// Preserves content type when available. If a file already exists at the
  /// destination it will be overwritten.
  Future<String> copyFile(String fromFullPath, String toFullPath) async {
    final srcRef = _storage.ref(fromFullPath);
    final bytes = await srcRef.getData();
    if (bytes == null) {
      throw StateError('copyFile: source returned no data ($fromFullPath)');
    }
    String? contentType;
    try {
      final meta = await srcRef.getMetadata();
      contentType = meta.contentType;
    } catch (_) {
      // Metadata read is best-effort.
    }
    final dstRef = _storage.ref(toFullPath);
    await dstRef.putData(
      bytes,
      SettableMetadata(contentType: contentType),
    );
    return toFullPath;
  }

  /// Move a file by copying then deleting the source.
  Future<String> moveFile(String fromFullPath, String toFullPath) async {
    if (fromFullPath == toFullPath) return toFullPath;
    await copyFile(fromFullPath, toFullPath);
    try {
      await _storage.ref(fromFullPath).delete();
    } catch (e) {
      debugPrint('moveFile: source delete failed ($fromFullPath): $e');
    }
    return toFullPath;
  }

  /// Rename a file within the same folder.
  Future<String> renameFile(String fullPath, String newName) async {
    final slash = fullPath.lastIndexOf('/');
    final folder = slash > 0 ? fullPath.substring(0, slash) : '';
    final newPath = folder.isEmpty ? newName : '$folder/$newName';
    if (newPath == fullPath) return fullPath;
    return moveFile(fullPath, newPath);
  }

  /// List every folder path that exists anywhere under [rootPath] (depth-first).
  /// The returned list is sorted alphabetically and includes [rootPath] itself.
  /// Useful as the source set for a "move/copy to folder" picker.
  Future<List<String>> listAllFolderPaths({String? rootPath}) async {
    final root = rootPath ?? _root;
    final out = <String>{root};
    Future<void> walk(String path) async {
      try {
        final result = await _storage.ref(path).listAll();
        for (final p in result.prefixes) {
          out.add(p.fullPath);
          await walk(p.fullPath);
        }
      } catch (e) {
        debugPrint('listAllFolderPaths walk error ($path): $e');
      }
    }

    await walk(root);
    final list = out.toList()..sort();
    return list;
  }

  /// Recursively delete a folder and everything inside it. Firebase Storage
  /// has no real folders, so we walk [listAll] and delete every file found,
  /// descending into sub-prefixes. Safe to call on folders that only exist
  /// because of a `.folder` placeholder — that placeholder is simply deleted.
  ///
  /// Returns the total number of files removed.
  Future<int> deleteFolderRecursive(String folderPath) async {
    int removed = 0;
    try {
      final result = await _storage.ref(folderPath).listAll();

      // Delete files in this folder in parallel.
      if (result.items.isNotEmpty) {
        await Future.wait(result.items.map((item) async {
          try {
            await item.delete();
            removed++;
          } catch (e) {
            debugPrint('deleteFolderRecursive: failed to delete '
                '${item.fullPath}: $e');
          }
        }));
      }

      // Recurse into each subfolder.
      for (final prefix in result.prefixes) {
        removed += await deleteFolderRecursive(prefix.fullPath);
      }
    } catch (e) {
      debugPrint('deleteFolderRecursive error ($folderPath): $e');
      rethrow;
    }
    return removed;
  }

  // ── Compiled waypoints ────────────────────────────────────────────────────

  /// Rebuild `_compiled_waypoints.json` for [folderPath] by re-reading every
  /// waypoint GPX file in that folder and aggregating the waypoints. A file
  /// is treated as a waypoint source when its name contains "waypoint"
  /// (case-insensitive) OR when it exposes any `<wpt>` elements.
  ///
  /// The produced JSON has shape:
  /// ```json
  /// { "waypointCount": N,
  ///   "waypoints": [ { "lat":..., "lon":..., "name":..., "desc":...,
  ///                    "sourceFile":... }, ... ] }
  /// ```
  /// Returns the waypoint count on success, or `null` on failure.
  Future<int?> regenerateCompiledWaypoints(String folderPath) async {
    try {
      final result = await _storage.ref(folderPath).listAll();
      final gpxItems = result.items
          .where((i) => i.name.toLowerCase().endsWith('.gpx'))
          .toList();

      final aggregated = <Map<String, dynamic>>[];
      for (final item in gpxItems) {
        try {
          final bytes = await item.getData();
          if (bytes == null) continue;
          final xml = String.fromCharCodes(bytes);
          final gpx = GpxReader().fromString(xml);
          if (gpx.wpts.isEmpty) continue;
          for (final w in gpx.wpts) {
            if (w.lat == null || w.lon == null) continue;
            aggregated.add({
              'lat': w.lat,
              'lon': w.lon,
              if (w.name != null) 'name': w.name,
              if (w.desc != null) 'desc': w.desc,
              'sourceFile': item.name,
            });
          }
        } catch (e) {
          debugPrint('regenerateCompiledWaypoints: '
              'failed to parse ${item.fullPath}: $e');
        }
      }

      final compiledPath = '$folderPath/_compiled_waypoints.json';
      final compiledRef = _storage.ref(compiledPath);

      if (aggregated.isEmpty) {
        // No waypoints left — remove any stale compiled file if it exists.
        try {
          await compiledRef.delete();
        } catch (_) {
          // Ignore "object-not-found" errors.
        }
        return 0;
      }

      final payload = jsonEncode({
        'waypointCount': aggregated.length,
        'waypoints': aggregated,
      });
      await compiledRef.putData(
        Uint8List.fromList(utf8.encode(payload)),
        SettableMetadata(contentType: 'application/json'),
      );
      return aggregated.length;
    } catch (e) {
      debugPrint('regenerateCompiledWaypoints error ($folderPath): $e');
      return null;
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  /// Sanitize a name for use in a storage path.
  /// Keeps alphanumerics, spaces, hyphens, underscores.
  static String _sanitize(String name) {
    return name
        .replaceAll(RegExp(r'[^\w\s\-]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }
}

/// Represents a GPX file stored in Cloud Storage.
class GpxStorageFile {
  final String name;
  final String fullPath;
  final String downloadUrl;

  const GpxStorageFile({
    required this.name,
    required this.fullPath,
    required this.downloadUrl,
  });
}

/// Represents a file in Cloud Storage (any type).
class StorageFileItem {
  final String name;
  final String fullPath;
  final DateTime? lastModified;
  final int? sizeBytes;

  const StorageFileItem({
    required this.name,
    required this.fullPath,
    this.lastModified,
    this.sizeBytes,
  });

  String get extension =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';

  /// Human-readable file size (e.g. "1.2 MB", "340 KB").
  String? get sizeLabel {
    final s = sizeBytes;
    if (s == null) return null;
    if (s < 1024) return '$s B';
    if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(1)} KB';
    if (s < 1024 * 1024 * 1024) {
      return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(s / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// Represents a folder in Cloud Storage.
class StorageFolderItem {
  final String name;
  final String fullPath;

  const StorageFolderItem({required this.name, required this.fullPath});
}
