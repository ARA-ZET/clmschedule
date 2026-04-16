// services/gpx_storage_service.dart
//
// Manages GPX track/waypoint files in Firebase Cloud Storage.
// Folder structure: Distribution/{year}/{MMM YYYY}/{clientName}/Round {N}/
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
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

  const StorageFileItem({
    required this.name,
    required this.fullPath,
    this.lastModified,
  });

  String get extension =>
      name.contains('.') ? name.split('.').last.toLowerCase() : '';
}

/// Represents a folder in Cloud Storage.
class StorageFolderItem {
  final String name;
  final String fullPath;

  const StorageFolderItem({required this.name, required this.fullPath});
}
