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
//      names matching the query, since the search term is often in the
//      middle of a file name (e.g. client/suburb name), not a prefix of it.
//      Step 1 runs once per search session (cached); each keystroke only
//      re-runs step 2 in memory.
import 'package:clmschedule/utils/text_search.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class FileSearchResult {
  final String name;
  final String fullPath;
  final String folderPath;
  final String extension;
  final int? sizeBytes;
  final DateTime? updatedAt;

  /// Moved out of Storage into a month archive ZIP ([zipName]).
  final bool archived;
  final String? archiveId;
  final String? zipName;

  const FileSearchResult({
    required this.name,
    required this.fullPath,
    required this.folderPath,
    required this.extension,
    this.sizeBytes,
    this.updatedAt,
    this.archived = false,
    this.archiveId,
    this.zipName,
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

  /// How long a scope's file list is reused. Covers one search session; the
  /// provider also clears it when the search bar closes, so the next search
  /// sees fresh uploads.
  static const Duration _ttl = Duration(minutes: 2);

  final Map<String, ({DateTime at, List<FileSearchResult> files})> _scopes =
      {};
  final Map<String, Future<List<FileSearchResult>?>> _inFlight = {};

  /// Start fetching [folderPath]'s file list so the first keystroke doesn't
  /// wait on the network.
  void prefetch(String folderPath) => _scope(folderPath);

  /// Drop cached file lists (call when the search closes).
  void clearCache() => _scopes.clear();

  /// Search for files whose name matches [query] (every word, any order,
  /// close spellings allowed — see [TextSearch]), scoped to [folderPath] and
  /// every subfolder beneath it. Pass the Distribution root to search the
  /// whole tree. Best matches first, then alphabetical.
  ///
  /// The scope's names are fetched once and then filtered in memory, so
  /// typing more letters doesn't go back to Firestore.
  Future<List<FileSearchResult>> search(
    String query,
    String folderPath,
  ) async {
    final needle = TextSearch(query);
    if (needle.isEmpty) return [];
    final files = await _scope(folderPath);
    if (files == null) return [];
    return needle.rank(files, (r) => [r.name]);
  }

  /// Every file under [folderPath], alphabetical. Null on failure (not
  /// cached, so the next keystroke retries).
  Future<List<FileSearchResult>?> _scope(String folderPath) {
    final hit = _scopes[folderPath];
    if (hit != null && DateTime.now().difference(hit.at) < _ttl) {
      return Future.value(hit.files);
    }
    return _inFlight[folderPath] ??=
        _load(folderPath).whenComplete(() => _inFlight.remove(folderPath));
  }

  Future<List<FileSearchResult>?> _load(String folderPath) async {
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
        // Files a month archive moved out of Storage (cloud_archive.js).
        final archived = data['archivedFiles'] as Map<String, dynamic>? ?? {};
        for (final entry in archived.entries) {
          final name = entry.key;
          if (files.containsKey(name)) continue;
          final meta = entry.value as Map<String, dynamic>? ?? {};
          final at = meta['archivedAt'];
          results.add(FileSearchResult(
            name: name,
            fullPath: '$docFolderPath/$name',
            folderPath: docFolderPath,
            extension:
                name.contains('.') ? name.split('.').last.toLowerCase() : '',
            sizeBytes: (meta['sizeBytes'] as num?)?.toInt(),
            updatedAt: at is Timestamp ? at.toDate() : null,
            archived: true,
            archiveId: meta['archiveId'] as String?,
            zipName: meta['zipName'] as String?,
          ));
        }
      }

      results.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      _scopes[folderPath] = (at: DateTime.now(), files: results);
      return results;
    } catch (e) {
      debugPrint('FileSearchService: loading "$folderPath" failed: $e');
      return null;
    }
  }
}
