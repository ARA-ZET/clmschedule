// services/gpx_storage_service.dart
//
// Manages GPX track/waypoint files in Firebase Cloud Storage.
// Folder structure: Distribution/{year}/{MMM YYYY}/{clientName}/
import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';

import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import 'storage_upload.dart';
import '../recycle_bin/recycle_bin_entry.dart';
import '../recycle_bin/recycle_bin_writer.dart';
import '../utils/text_encoding.dart';

class GpxStorageService {
  static GpxStorageService? _instance;
  GpxStorageService._internal();
  factory GpxStorageService() => _instance ??= GpxStorageService._internal();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  /// Root prefix for all distribution files.
  static const String _root = 'Distribution';

  /// `getData()` defaults to a 10 MB cap and fails on anything larger —
  /// photos and long tracks routinely are.
  static const int _maxDownloadBytes = 512 * 1024 * 1024;

  /// Upload bytes to [ref] using a WASM-safe code path on web.
  /// Delegates to [StorageUpload.safePutData].
  Future<void> _safePutData(
    Reference ref,
    Uint8List bytes, {
    SettableMetadata? metadata,
  }) =>
      StorageUpload.safePutData(ref, bytes, metadata: metadata);

  // ── Path building ─────────────────────────────────────────────────────────

  /// Build the base client folder path for a given date and client name.
  /// Example: Distribution/2026/Apr 2026/Seeff
  String clientFolderPath(DateTime date, String clientName) {
    final year = date.year.toString();
    final monthLabel = DateFormat('MMM yyyy').format(date); // "Apr 2026"
    final safeName = _sanitize(clientName);
    return '$_root/$year/$monthLabel/$safeName';
  }

  /// Returns `true` if a client folder already exists under the month folder
  /// for [date] with a case-insensitive name match on [clientName]. Used to
  /// decide whether to default save operations into the existing client
  /// folder or to force the user to pick a folder instead.
  Future<bool> clientFolderExists(DateTime date, String clientName) async {
    final needle = _sanitize(clientName).toLowerCase();
    if (needle.isEmpty) return false;
    final folders = await _clientFoldersIn(date);
    return folders.contains(needle);
  }

  /// Lower-cased client folder names in [date]'s month folder.
  ///
  /// Listing a month folder is a Storage round trip, and a tab asks about
  /// every client it has — so one listing per month is shared by all of them
  /// (including callers asking at the same moment) for [_folderCacheTtl].
  /// Any write through this service drops the cache, so a folder created here
  /// is seen straight away.
  Future<Set<String>> _clientFoldersIn(DateTime date) {
    final monthPath =
        '$_root/${date.year}/${DateFormat('MMM yyyy').format(date)}';
    final cached = _folderCache[monthPath];
    if (cached != null &&
        DateTime.now().difference(cached.at) < _folderCacheTtl) {
      return cached.names;
    }
    // Bounded: a hung listing would otherwise sit in the cache, stalling every
    // caller (and every retry) for the cache's lifetime.
    final names = _storage
        .ref(monthPath)
        .listAll()
        .timeout(const Duration(seconds: 10))
        .then(
      (r) => {for (final p in r.prefixes) p.name.toLowerCase()},
      onError: (Object e) {
        debugPrint('clientFoldersIn($monthPath): $e');
        _folderCache.remove(monthPath);
        return <String>{};
      },
    );
    _folderCache[monthPath] = (at: DateTime.now(), names: names);
    return names;
  }

  static const _folderCacheTtl = Duration(minutes: 2);
  final Map<String, ({DateTime at, Future<Set<String>> names})> _folderCache =
      {};

  void _dropFolderCache() => _folderCache.clear();

  // ── Upload ────────────────────────────────────────────────────────────────

  /// Upload a GPX file (as string) to the given storage folder path,
  /// replacing any file of the same name.
  ///
  /// Completes when the file is stored. It does not fetch a download URL
  /// afterwards — no caller used it, and on a slow connection that extra
  /// round trip was a noticeable part of every save.
  Future<void> uploadGpxFile(
      String folderPath, String fileName, String gpxContent) async {
    _dropFolderCache();
    // Sanitize the file name so callers can't accidentally smuggle path
    // separators (e.g. a client/work-area name containing '/') which
    // Firebase Storage would interpret as nested folders, producing the
    // bug where "Trim & Save" creates folders instead of .gpx files.
    final safeName = _sanitizeFileName(fileName);
    final cleanFolder = folderPath.replaceAll(RegExp(r'/+$'), '');
    final ref = _storage.ref('$cleanFolder/$safeName');
    await _safePutData(
      ref,
      utf8.encode(gpxContent),
      metadata: SettableMetadata(contentType: 'application/gpx+xml'),
    );
  }

  /// Uploads the GPX that [build] makes as [fileName] in [folderPath] —
  /// unless a file of that name is already there, in which case nothing is
  /// uploaded and this returns false.
  ///
  /// The folder is listed by name only (one request — not a metadata request
  /// per file it holds), and that request is already on its way while the
  /// GPX is being built, so the two overlap. If the listing fails the file
  /// is uploaded anyway: the worst case is replacing an identical copy.
  Future<bool> uploadGpxUnlessPresent(
    String folderPath,
    String fileName,
    Future<String> Function() build,
  ) async {
    final safeName = _sanitizeFileName(fileName);
    final present = listAllFiles(folderPath)
        .then((files) => files.any((f) => f.name == safeName));
    // Building a long track's GPX runs without a break; one event-loop turn
    // first lets the listing request actually leave.
    await Future<void>.delayed(Duration.zero);
    final content = await build();
    if (await present) return false;
    await uploadGpxFile(folderPath, safeName, content);
    return true;
  }

  /// Replace characters that Firebase Storage (or common OSes) treat as
  /// path/illegal characters in a leaf file name. Leaves spaces, dashes,
  /// dots and unicode letters intact.
  static String sanitizeFileName(String name) => _sanitizeFileName(name);

  static String _sanitizeFileName(String name) {
    var n = name.trim();
    // Replace path separators and control chars with a single space, then
    // collapse runs of whitespace.
    n = n.replaceAll(RegExp(r'[\\/]+'), ' ');
    n = n.replaceAll(RegExp(r'[\u0000-\u001f\u007f]'), '');
    // Strip characters that are illegal on Windows/macOS but legal on
    // Storage so the round-trip download is well-behaved.
    n = n.replaceAll(RegExp(r'[<>:"|?*]'), '');
    n = n.replaceAll(RegExp(r' {2,}'), '   ');
    return n.trim();
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

  /// Size + updated time per file name from the folder's `fileFolders` index
  /// doc (kept current by the indexFileOnUpload/Delete triggers). One read
  /// instead of one metadata request per file; empty on any failure.
  Future<Map<String, ({int? size, DateTime? updated})>> _indexedMetadata(
      String folderPath) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('fileFolders')
          .where('folderPath', isEqualTo: folderPath)
          .limit(1)
          .get();
      if (snap.docs.isEmpty) return const {};
      final files = snap.docs.first.data()['files'];
      if (files is! Map) return const {};
      final out = <String, ({int? size, DateTime? updated})>{};
      files.forEach((name, v) {
        if (v is! Map) return;
        final size = (v['sizeBytes'] as num?)?.toInt();
        final ts = v['updatedAt'];
        final updated = ts is Timestamp ? ts.toDate() : null;
        if (size != null && updated != null) {
          out['$name'] = (size: size, updated: updated);
        }
      });
      return out;
    } catch (e) {
      debugPrint('indexedMetadata($folderPath): $e');
      return const {};
    }
  }

  /// List both subfolders and files in a storage folder.
  Future<({List<StorageFolderItem> folders, List<StorageFileItem> files})>
      listFolderContents(String folderPath) async {
    try {
      final listed = await Future.wait([
        _storage.ref(folderPath).listAll(),
        _indexedMetadata(folderPath),
      ]);
      final result = listed[0] as ListResult;
      final indexed =
          listed[1] as Map<String, ({int? size, DateTime? updated})>;
      final folders = result.prefixes
          .map((p) => StorageFolderItem(name: p.name, fullPath: p.fullPath))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final fileItems = await Future.wait(
        result.items.map((item) async {
          final known = indexed[item.name];
          if (known != null) {
            return StorageFileItem(
              name: item.name,
              fullPath: item.fullPath,
              lastModified: known.updated,
              sizeBytes: known.size,
            );
          }
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

  /// Folder and file names only — one listing call, no per-file metadata and
  /// no file contents. Sizes/dates come later from [fileDetails]. Throws on
  /// failure so a browser can show an error rather than an empty folder.
  Future<({List<StorageFolderItem> folders, List<StorageFileItem> files})>
      listFolderEntries(String folderPath) async {
    final result = await _storage.ref(folderPath).listAll();
    final folders = result.prefixes
        .map((p) => StorageFolderItem(name: p.name, fullPath: p.fullPath))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    final files = result.items
        .map((i) => StorageFileItem(name: i.name, fullPath: i.fullPath))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return (folders: folders, files: files);
  }

  /// Size and modified date for [files] in [folderPath]: one `fileFolders`
  /// index read, then a metadata request only for files the index lacks
  /// (a few at a time). Files whose details can't be read are left out.
  Future<Map<String, ({int? size, DateTime? updated})>> fileDetails(
      String folderPath, List<StorageFileItem> files) async {
    final out = Map<String, ({int? size, DateTime? updated})>.of(
        await _indexedMetadata(folderPath));
    final missing = files.where((f) => !out.containsKey(f.name)).toList();
    const batch = 6;
    for (var i = 0; i < missing.length; i += batch) {
      final chunk = missing.skip(i).take(batch);
      await Future.wait(chunk.map((f) async {
        try {
          final meta = await _storage.ref(f.fullPath).getMetadata();
          out[f.name] = (size: meta.size, updated: meta.updated ?? meta.timeCreated);
        } catch (_) {}
      }));
    }
    return out;
  }

  /// Subfolder names and a GPX count for one folder — no per-file metadata
  /// requests, so it costs one listing call however many files are inside.
  /// For pickers that only need to walk down to a folder.
  Future<({List<StorageFolderItem> folders, int gpxCount})> listFolderNames(
      String folderPath) async {
    try {
      final result = await _storage.ref(folderPath).listAll();
      final folders = result.prefixes
          .map((p) => StorageFolderItem(name: p.name, fullPath: p.fullPath))
          .toList()
        ..sort((a, b) => a.name.compareTo(b.name));
      final gpx = result.items
          .where((i) => i.name.toLowerCase().endsWith('.gpx'))
          .length;
      return (folders: folders, gpxCount: gpx);
    } catch (e) {
      debugPrint('listFolderNames error ($folderPath): $e');
      rethrow;
    }
  }

  /// Download any file as bytes.
  Future<Uint8List?> downloadFileBytes(String fullPath) async {
    try {
      return await _storage.ref(fullPath).getData(_maxDownloadBytes);
    } catch (e) {
      debugPrint('downloadFileBytes error ($fullPath): $e');
      return null;
    }
  }

  /// Upload any file bytes to a folder.
  Future<String> uploadFileBytes(
      String folderPath, String fileName, Uint8List bytes,
      {String? contentType}) async {
    _dropFolderCache();
    final ref = _storage.ref('$folderPath/$fileName');
    await _safePutData(
      ref,
      bytes,
      metadata: SettableMetadata(contentType: contentType),
    );
    return ref.getDownloadURL();
  }

  /// Create a folder by uploading a hidden placeholder file.
  /// Firebase Storage doesn't have real folders — a folder only exists
  /// while it contains at least one file.
  Future<void> createFolder(String folderPath) async {
    _dropFolderCache();
    final ref = _storage.ref('$folderPath/.folder');
    await _safePutData(
      ref,
      Uint8List(0),
      metadata: SettableMetadata(contentType: 'application/x-empty'),
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

  // ── Download ──────────────────────────────────────────────────────────────

  /// Download a GPX file as string content.
  Future<String?> downloadGpxFile(String fullPath) async {
    try {
      final ref = _storage.ref(fullPath);
      final data = await ref.getData(_maxDownloadBytes);
      if (data != null) return decodeTextBytes(data);
    } catch (e) {
      debugPrint('downloadGpxFile error ($fullPath): $e');
    }
    return null;
  }

  // ── Delete ────────────────────────────────────────────────────────────────

  /// Delete a single GPX file by full path.
  Future<void> deleteFile(String fullPath) async {
    _dropFolderCache();
    await _storage.ref(fullPath).delete();
  }

  // ── Recycle Bin ───────────────────────────────────────────────────────────
  //
  // Deleting moves the files to `recycleBin/files/{entryId}/<original path>`
  // and records one bin entry per deleted file or folder. Restoring copies
  // them back (metadata first, like a folder rename) and never overwrites:
  // a path taken meanwhile gets " (restored)" in its name. The copies stay
  // until the daily sweep purges the entry.

  static String _binPrefix(String entryId) =>
      '${kRecycleBinStoragePrefix}files/$entryId/';

  /// Moves one file to the Recycle Bin; returns the bin entry id.
  Future<String> moveFileToBin(String fullPath) async {
    _dropFolderCache();
    final writer = RecycleBinWriter();
    final entryRef = writer.newEntryRef();
    await copyFile(fullPath, '${_binPrefix(entryRef.id)}$fullPath');
    final slash = fullPath.lastIndexOf('/');
    await writer.add(
      RecycleBinRecord(
        type: RecycleBinType.cloudFile,
        label: slash < 0
            ? fullPath
            : '${fullPath.substring(slash + 1)} · '
                '${fullPath.substring(0, slash)}',
        originalPath: fullPath,
      ),
      ref: entryRef,
    );
    await _storage.ref(fullPath).delete();
    return entryRef.id;
  }

  /// Moves a folder and everything under it to the Recycle Bin; returns the
  /// bin entry id and how many files moved.
  Future<(String, int)> moveFolderToBin(String folderPath) async {
    _dropFolderCache();
    final files = <String>[];
    Future<void> walk(String path) async {
      final result = await _storage.ref(path).listAll();
      files.addAll(result.items.map((i) => i.fullPath));
      for (final prefix in result.prefixes) {
        await walk(prefix.fullPath);
      }
    }

    await walk(folderPath);
    final writer = RecycleBinWriter();
    final entryRef = writer.newEntryRef();
    final prefix = _binPrefix(entryRef.id);
    await Future.wait(files.map((f) => copyFile(f, '$prefix$f')));
    await writer.add(
      RecycleBinRecord(
        type: RecycleBinType.cloudFolder,
        label: '$folderPath (${files.length} '
            'file${files.length == 1 ? '' : 's'})',
        originalPath: folderPath,
      ),
      ref: entryRef,
    );
    final removed = await deleteFolderRecursive(folderPath);
    return (entryRef.id, removed);
  }

  /// Copies a bin entry's files back where they were. Returns how many were
  /// put back under another name because their path was taken.
  Future<int> restoreFromBin(String entryId) async {
    _dropFolderCache();
    final prefix = _binPrefix(entryId);
    final files = <String>[];
    Future<void> walk(String path) async {
      final result = await _storage.ref(path).listAll();
      files.addAll(result.items.map((i) => i.fullPath));
      for (final p in result.prefixes) {
        await walk(p.fullPath);
      }
    }

    await walk(prefix.substring(0, prefix.length - 1));
    if (files.isEmpty) {
      throw const RestoreConflict('its files are no longer in the bin');
    }
    var renamed = 0;
    Future<void> put(String binPath) async {
      var target = binPath.substring(prefix.length);
      if (await _exists(target)) {
        target = _restoredName(target);
        renamed++;
      }
      await copyFile(binPath, target);
    }

    // Compiled JSON and the archive manifest first, as in [renameFolder].
    bool isMeta(String p) => p.split('/').last.startsWith('_');
    await Future.wait(files.where(isMeta).map(put));
    await Future.wait(files.where((f) => !isMeta(f)).map(put));
    return renamed;
  }

  Future<bool> _exists(String fullPath) async {
    try {
      await _storage.ref(fullPath).getMetadata();
      return true;
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return false;
      rethrow;
    }
  }

  /// "a/b/track.gpx" → "a/b/track (restored).gpx".
  static String _restoredName(String fullPath) {
    final slash = fullPath.lastIndexOf('/');
    final dot = fullPath.lastIndexOf('.');
    return dot > slash + 1
        ? '${fullPath.substring(0, dot)} (restored)${fullPath.substring(dot)}'
        : '$fullPath (restored)';
  }

  // ── Rename / Copy / Move ──────────────────────────────────────────────────

  /// Copy a file to another location by streaming its bytes.
  /// Returns the full path of the new file.
  /// Preserves content type when available. If a file already exists at the
  /// destination it will be overwritten.
  Future<String> copyFile(String fromFullPath, String toFullPath) async {
    _dropFolderCache();
    final srcRef = _storage.ref(fromFullPath);
    final bytes = await srcRef.getData(_maxDownloadBytes);
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
    await _safePutData(
      dstRef,
      bytes,
      metadata: SettableMetadata(contentType: contentType),
    );
    return toFullPath;
  }

  /// Move a file by copying then deleting the source.
  Future<String> moveFile(String fromFullPath, String toFullPath) async {
    _dropFolderCache();
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

  /// Rename a folder by recursively copying every file under [oldFolderPath]
  /// to the equivalent path under the new folder (same parent, last segment
  /// replaced with [newName]), then deleting the original folder tree.
  ///
  /// Returns the new folder path on success. Throws on failure.
  Future<String> renameFolder(String oldFolderPath, String newName) async {
    _dropFolderCache();
    final slash = oldFolderPath.lastIndexOf('/');
    final parent = slash > 0 ? oldFolderPath.substring(0, slash) : '';
    final newFolderPath = parent.isEmpty ? newName : '$parent/$newName';

    if (newFolderPath == oldFolderPath) return oldFolderPath;

    // Collect every file in the source tree, preserving relative sub-paths.
    final entries = <({String oldPath, String newPath})>[];
    Future<void> walkCopy(String src, String dst) async {
      final result = await _storage.ref(src).listAll();
      for (final item in result.items) {
        entries.add((
          oldPath: item.fullPath,
          newPath: '$dst/${item.name}',
        ));
      }
      for (final prefix in result.prefixes) {
        await walkCopy(prefix.fullPath, '$dst/${prefix.name}');
      }
    }

    await walkCopy(oldFolderPath, newFolderPath);

    // Compiled JSON and the archive manifest land first: in a folder whose
    // GPX were archived to Drive, the compile each GPX copy triggers reads
    // them to keep the archived tracks.
    bool isMeta(String p) => p.split('/').last.startsWith('_');
    await Future.wait(entries
        .where((e) => isMeta(e.oldPath))
        .map((e) => copyFile(e.oldPath, e.newPath)));
    await Future.wait(entries
        .where((e) => !isMeta(e.oldPath))
        .map((e) => copyFile(e.oldPath, e.newPath)));

    // Delete the original tree.
    await deleteFolderRecursive(oldFolderPath);

    return newFolderPath;
  }

  /// Download every file in [folderPath] (recursively including subfolders)
  /// and bundle them into a ZIP archive, preserving the folder structure as
  /// relative paths from [folderPath].
  ///
  /// [onProgress] is called after each file is downloaded with
  /// (completedFiles, totalFiles).
  ///
  /// Returns the raw ZIP bytes, or `null` if the folder is empty or an error
  /// occurs.
  Future<Uint8List?> downloadFolderAsZip(
    String folderPath, {
    void Function(int done, int total)? onProgress,
  }) async {
    try {
      // Collect all file refs with their relative paths inside the folder.
      final entries = <({Reference ref, String relativePath})>[];

      Future<void> walk(String path) async {
        final result = await _storage.ref(path).listAll();
        for (final item in result.items) {
          // Strip the folderPath prefix (+ leading '/') to get relative path.
          final rel = item.fullPath.length > folderPath.length + 1
              ? item.fullPath.substring(folderPath.length + 1)
              : item.name;
          entries.add((ref: item, relativePath: rel));
        }
        for (final prefix in result.prefixes) {
          await walk(prefix.fullPath);
        }
      }

      await walk(folderPath);
      if (entries.isEmpty) return null;

      final total = entries.length;
      int done = 0;

      // Download all files in parallel (up to 6 concurrent).
      final results = List<Uint8List?>.filled(total, null);
      int next = 0;

      Future<void> worker() async {
        while (true) {
          final idx = next++;
          if (idx >= total) return;
          try {
            results[idx] = await entries[idx].ref.getData(_maxDownloadBytes);
          } catch (e) {
            debugPrint(
                'downloadFolderAsZip: failed ${entries[idx].ref.fullPath}: $e');
          } finally {
            done++;
            onProgress?.call(done, total);
          }
        }
      }

      final workers = List.generate(6, (_) => worker());
      await Future.wait(workers);

      // Build ZIP archive.
      final archive = Archive();
      for (var i = 0; i < total; i++) {
        final bytes = results[i];
        if (bytes == null) continue;
        archive.addFile(
          ArchiveFile(entries[i].relativePath, bytes.length, bytes),
        );
      }

      if (archive.isEmpty) return null;
      final zipBytes = ZipEncoder().encode(archive);
      return Uint8List.fromList(zipBytes);
    } catch (e) {
      debugPrint('downloadFolderAsZip error ($folderPath): $e');
      return null;
    }
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
    _dropFolderCache();
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
  ///
  /// NOTE: this only rebuilds the waypoints file. For combined
  /// tracks + waypoints rebuild (matching the Cloud Function schema), use
  /// [regenerateCompiledFiles].
  /// Invoke the server-side `compileGpxFolder` Cloud Function to rebuild
  /// `_compiled_tracks.json` and `_compiled_waypoints.json` for [folderPath].
  /// Prefer this over the client-side [regenerateCompiledFiles] for copy/move
  /// triggered recompilation because it runs on Google's servers and is not
  /// subject to client lifecycle or network constraints.
  Future<void> callCompileGpxFolder(String folderPath) async {
    final callable =
        FirebaseFunctions.instanceFor(region: 'us-central1').httpsCallable(
      'compileGpxFolder',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 120)),
    );
    await callable.call({'folderPath': folderPath});
  }

  Future<int?> regenerateCompiledWaypoints(String folderPath) async {
    final result = await regenerateCompiledFiles(folderPath);
    return result?.waypointCount;
  }

  /// Rebuild BOTH `_compiled_tracks.json` and `_compiled_waypoints.json` for
  /// [folderPath] by re-reading every GPX file in that folder. Mirrors the
  /// schema produced by the `compileGpxOnUpload` Cloud Function so the same
  /// client parsers work either way.
  ///
  /// All GPX files are downloaded and parsed in parallel for speed.
  /// Returns the (trackCount, waypointCount) on success or `null` on failure.
  Future<({int trackCount, int waypointCount})?> regenerateCompiledFiles(
      String folderPath) async {
    try {
      final result = await _storage.ref(folderPath).listAll();
      final gpxItems = result.items
          .where((i) =>
              i.name.toLowerCase().endsWith('.gpx') &&
              !i.name.startsWith('_compiled'))
          .toList();

      final tracksOut = <Map<String, dynamic>>[];
      final waypointsOut = <Map<String, dynamic>>[];

      // Download + parse in parallel.
      final parsed = await Future.wait(gpxItems.map((item) async {
        try {
          final bytes = await item.getData();
          if (bytes == null) return null;
          final xml = decodeTextBytes(bytes);
          final gpx = GpxReader().fromString(xml);
          return (item: item, gpx: gpx);
        } catch (e) {
          debugPrint(
              'regenerateCompiledFiles: failed to parse ${item.fullPath}: $e');
          return null;
        }
      }));

      for (final p in parsed) {
        if (p == null) continue;
        final fileName = p.item.name;
        // Waypoints
        for (final w in p.gpx.wpts) {
          if (w.lat == null || w.lon == null) continue;
          waypointsOut.add({
            'name': w.name ?? '',
            'desc': w.desc ?? '',
            'lat': w.lat,
            'lon': w.lon,
            'sourceFile': fileName,
          });
        }
        // Tracks (one entry per non-empty segment)
        for (var ti = 0; ti < p.gpx.trks.length; ti++) {
          final trk = p.gpx.trks[ti];
          final trkName = trk.name ?? '';
          final trkDesc = trk.desc ?? '';
          for (var si = 0; si < trk.trksegs.length; si++) {
            final seg = trk.trksegs[si];
            final coords = <List<double>>[];
            int? startMs;
            int? endMs;
            for (final pt in seg.trkpts) {
              if (pt.lat == null || pt.lon == null) continue;
              coords.add([pt.lat!, pt.lon!]);
              final t = pt.time;
              if (t != null) {
                final ms = t.millisecondsSinceEpoch;
                if (startMs == null || ms < startMs) startMs = ms;
                if (endMs == null || ms > endMs) endMs = ms;
              }
            }
            if (coords.length < 2) continue;
            // Haversine distance in meters.
            double distance = 0;
            for (var i = 0; i < coords.length - 1; i++) {
              distance += _haversine(coords[i][0], coords[i][1],
                  coords[i + 1][0], coords[i + 1][1]);
            }
            final segName = trkName.isEmpty ? 'Track ${ti + 1}' : trkName;
            final name =
                trk.trksegs.length > 1 ? '$segName (seg ${si + 1})' : segName;
            tracksOut.add({
              'name': name,
              'desc': trkDesc,
              'file': fileName,
              'points': coords,
              'distanceMeters': distance.round(),
              'startTime': startMs,
              'endTime': endMs,
              'durationMs':
                  (startMs != null && endMs != null) ? endMs - startMs : null,
            });
          }
        }
        // Routes
        for (var ri = 0; ri < p.gpx.rtes.length; ri++) {
          final rte = p.gpx.rtes[ri];
          final coords = <List<double>>[];
          for (final pt in rte.rtepts) {
            if (pt.lat == null || pt.lon == null) continue;
            coords.add([pt.lat!, pt.lon!]);
          }
          if (coords.length < 2) continue;
          double distance = 0;
          for (var i = 0; i < coords.length - 1; i++) {
            distance += _haversine(
                coords[i][0], coords[i][1], coords[i + 1][0], coords[i + 1][1]);
          }
          tracksOut.add({
            'name': rte.name ?? 'Route ${ri + 1}',
            'desc': rte.desc ?? '',
            'file': fileName,
            'points': coords,
            'distanceMeters': distance.round(),
            'startTime': null,
            'endTime': null,
            'durationMs': null,
          });
        }
      }

      final tracksRef = _storage.ref('$folderPath/_compiled_tracks.json');
      final waypointsRef = _storage.ref('$folderPath/_compiled_waypoints.json');

      // Write or remove tracks.
      if (tracksOut.isEmpty) {
        try {
          await tracksRef.delete();
        } catch (_) {}
      } else {
        final payload = jsonEncode({
          'version': 1,
          'compiledAt': DateTime.now().toUtc().toIso8601String(),
          'fileCount': gpxItems.length,
          'trackCount': tracksOut.length,
          'waypointCount': waypointsOut.length,
          'tracks': tracksOut,
        });
        await _safePutData(
          tracksRef,
          Uint8List.fromList(utf8.encode(payload)),
          metadata: SettableMetadata(contentType: 'application/json'),
        );
      }

      // Write or remove waypoints.
      if (waypointsOut.isEmpty) {
        try {
          await waypointsRef.delete();
        } catch (_) {}
      } else {
        final payload = jsonEncode({
          'version': 1,
          'compiledAt': DateTime.now().toUtc().toIso8601String(),
          'fileCount': gpxItems.length,
          'waypointCount': waypointsOut.length,
          'waypoints': waypointsOut,
        });
        await _safePutData(
          waypointsRef,
          Uint8List.fromList(utf8.encode(payload)),
          metadata: SettableMetadata(contentType: 'application/json'),
        );
      }

      // Sync waypoint count onto any shareable map(s) linked to this folder
      // so the gallery badge stays accurate. Errors are swallowed inside.
      await _syncShareableMapCounts(folderPath, waypointsOut.length);

      return (trackCount: tracksOut.length, waypointCount: waypointsOut.length);
    } catch (e) {
      debugPrint('regenerateCompiledFiles error ($folderPath): $e');
      return null;
    }
  }

  /// Push freshly computed waypoint count onto every shareable map
  /// document whose `storageFolderPath` matches [folderPath]. Fire-and-forget
  /// from the regen helpers; failures are swallowed.
  Future<void> _syncShareableMapCounts(
      String folderPath, int waypointCount) async {
    try {
      await ShareableMapsFirestoreService().updateCloudCountsByFolderPath(
        folderPath,
        waypointCount: waypointCount,
      );
    } catch (e) {
      debugPrint('syncShareableMapCounts error ($folderPath): $e');
    }
  }

  /// Haversine distance in meters between two (lat, lon) pairs in degrees.
  static double _haversine(double lat1, double lon1, double lat2, double lon2) {
    const r = 6371000.0;
    double toRad(double d) => d * 3.141592653589793 / 180.0;
    final dLat = toRad(lat2 - lat1);
    final dLon = toRad(lon2 - lon1);
    final a = (math.sin(dLat / 2) * math.sin(dLat / 2)) +
        math.cos(toRad(lat1)) *
            math.cos(toRad(lat2)) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    return r * 2 * math.asin(math.sqrt(a));
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
