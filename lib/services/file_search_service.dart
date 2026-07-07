// services/file_search_service.dart
//
// Searches Cloud Storage files by name via the `fileFolders` Firestore
// collection instead of recursively walking Storage folders. The collection
// is kept in sync by the `indexFileOnUpload` / `indexFileOnDelete` Cloud
// Functions (see functions/index.js), so every upload, rename, copy, move
// and delete under Distribution/ self-heals the index automatically.
//
// Unlike a one-doc-per-file design, `fileFolders` has one doc PER FOLDER,
// with every file inside it stored as an entry in a `files` map field.
// Reading "every file in this folder" costs exactly one document read no
// matter how many files it holds, so a scoped search's read cost tracks the
// number of *folders* in scope (grows slowly — one per client/round), not
// the number of files (grows with every upload, forever).
//
// Firestore has no substring/"contains" query operator, so a search is done
// in two steps:
//   1. Server-side: an indexed `array-contains` match on `ancestorFolders`
//      finds every folder doc under the folder being searched (recursively)
//      — one exact, indexed lookup against a collection that only grows
//      with folder count.
//   2. Client-side: each matching folder doc's `files` map is scanned for
//      names containing the query, since the search term is often in the
//      middle of a file name (e.g. client/suburb name), not a prefix of it.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class FileSearchResult {
  final String name;
  final String fullPath;
  final String folderPath;
  final String extension;
  final int? sizeBytes;
  final DateTime? updatedAt;

  const FileSearchResult({
    required this.name,
    required this.fullPath,
    required this.folderPath,
    required this.extension,
    this.sizeBytes,
    this.updatedAt,
  });

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

class FileSearchService {
  static FileSearchService? _instance;
  FileSearchService._internal();
  factory FileSearchService() => _instance ??= FileSearchService._internal();

  static const String _collection = 'fileFolders';

  /// Safety cap on how many folder docs a single scope query will read.
  /// Folder count grows far slower than file count (one per client/round,
  /// not one per upload), so this should never realistically bind.
  static const int _maxFolderReads = 2000;

  FirebaseFirestore get _firestore => FirebaseFirestore.instance;

  /// Search for files whose name contains [query] (case-insensitive,
  /// anywhere in the name), scoped to [folderPath] and every subfolder
  /// beneath it. Pass the Distribution root to search the whole tree.
  Future<List<FileSearchResult>> search(
    String query,
    String folderPath,
  ) async {
    final needle = query.trim().toLowerCase();
    if (needle.isEmpty) return [];

    try {
      final snap = await _firestore
          .collection(_collection)
          .where('ancestorFolders', arrayContains: folderPath)
          .limit(_maxFolderReads)
          .get();

      final results = <FileSearchResult>[];
      for (final doc in snap.docs) {
        final data = doc.data();
        final docFolderPath = data['folderPath'] as String? ?? '';
        final files = data['files'] as Map<String, dynamic>? ?? {};
        for (final entry in files.entries) {
          final name = entry.key;
          if (!name.toLowerCase().contains(needle)) continue;
          final meta = entry.value as Map<String, dynamic>? ?? {};
          final updated = meta['updatedAt'];
          results.add(FileSearchResult(
            name: name,
            fullPath: '$docFolderPath/$name',
            folderPath: docFolderPath,
            extension:
                name.contains('.') ? name.split('.').last.toLowerCase() : '',
            sizeBytes: (meta['sizeBytes'] as num?)?.toInt(),
            updatedAt: updated is Timestamp ? updated.toDate() : null,
          ));
        }
      }

      results.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return results;
    } catch (e) {
      debugPrint('FileSearchService.search("$query", "$folderPath") failed: $e');
      return [];
    }
  }
}
