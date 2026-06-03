// services/gpx_storage_service.dart
//
// Manages GPX track/waypoint files in Firebase Cloud Storage.
// Folder structure: Distribution/{year}/{MMM YYYY}/{clientName}/Round {N}/
import 'dart:convert';
import 'dart:math' as math;

import 'package:archive/archive.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';

import '../shareable_maps/services/shareable_maps_firestore_service.dart';
import 'storage_upload.dart';

class GpxStorageService {
  static GpxStorageService? _instance;
  GpxStorageService._internal();
  factory GpxStorageService() => _instance ??= GpxStorageService._internal();

  FirebaseStorage get _storage => FirebaseStorage.instance;

  /// Root prefix for all distribution files.
  static const String _root = 'Distribution';

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
    // Sanitize the file name so callers can't accidentally smuggle path
    // separators (e.g. a client/work-area name containing '/') which
    // Firebase Storage would interpret as nested folders, producing the
    // bug where "Trim & Save" creates folders instead of .gpx files.
    final safeName = _sanitizeFileName(fileName);
    final cleanFolder = folderPath.replaceAll(RegExp(r'/+$'), '');
    final ref = _storage.ref('$cleanFolder/$safeName');
    final bytes = Uint8List.fromList(utf8.encode(gpxContent));
    await _safePutData(
      ref,
      bytes,
      metadata: SettableMetadata(contentType: 'application/gpx+xml'),
    );
    return ref.getDownloadURL();
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
    await _safePutData(
      dstRef,
      bytes,
      metadata: SettableMetadata(contentType: contentType),
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

  /// Rename a folder by recursively copying every file under [oldFolderPath]
  /// to the equivalent path under the new folder (same parent, last segment
  /// replaced with [newName]), then deleting the original folder tree.
  ///
  /// Returns the new folder path on success. Throws on failure.
  Future<String> renameFolder(String oldFolderPath, String newName) async {
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

    // Copy all files in parallel.
    await Future.wait(entries.map((e) => copyFile(e.oldPath, e.newPath)));

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
            results[idx] = await entries[idx].ref.getData();
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
          final xml = String.fromCharCodes(bytes);
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
