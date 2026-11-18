// services/cloud_archive_service.dart
//
// Client side of the Cloud Files month/year archive (server:
// functions/lib/cloud_archive.js) and of server-side ZIP downloads
// (functions/lib/storage_zip.js).
//
// Archiving a month builds a ZIP of its raw files (GPX, photos, KML …) in
// the cloud. The user downloads it and extracts it into whichever Google
// Drive folder they like — the app never connects to Drive. Once they
// confirm, the originals are removed from Storage; `_compiled_*.json` stays
// so maps, reports and letterbox counts keep loading, and `_archive.json` in
// each folder lists the files that went into the ZIP.
//
// A year is archived as one ZIP per month, all sharing the year's batchId.
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// Name of the manifest the server writes into an archived folder.
const String kArchiveManifestFile = '_archive.json';

/// One file that was moved out of Storage into an archive ZIP, from a
/// folder's `_archive.json`.
class ArchivedFileEntry {
  final String name;
  final String folderPath;
  final int? sizeBytes;
  final String? contentType;
  final DateTime? originalUpdated;
  final DateTime? archivedAt;
  final String? archiveId;
  final String? zipName;

  const ArchivedFileEntry({
    required this.name,
    required this.folderPath,
    this.sizeBytes,
    this.contentType,
    this.originalUpdated,
    this.archivedAt,
    this.archiveId,
    this.zipName,
  });

  String get fullPath => '$folderPath/$name';
}

class ArchiveManifest {
  final String folderPath;
  final List<ArchivedFileEntry> files;

  const ArchiveManifest({required this.folderPath, required this.files});

  static ArchiveManifest parse(String folderPath, Map<String, dynamic> json) {
    final raw = json['files'];
    final files = <ArchivedFileEntry>[];
    if (raw is Map) {
      raw.forEach((name, v) {
        if (v is! Map) return;
        files.add(ArchivedFileEntry(
          name: '$name',
          folderPath: folderPath,
          sizeBytes: (v['sizeBytes'] as num?)?.toInt(),
          contentType: v['contentType'] as String?,
          originalUpdated: DateTime.tryParse('${v['originalUpdated']}'),
          archivedAt: DateTime.tryParse('${v['archivedAt']}'),
          archiveId: v['archiveId'] as String?,
          zipName: v['zipName'] as String?,
        ));
      });
    }
    return ArchiveManifest(folderPath: folderPath, files: files);
  }
}

/// A `cloudArchives` doc: one month's ZIP, or a year that was split into
/// month docs sharing its [batchId].
class CloudArchive {
  final String id;
  final String batchId;
  final String folderPath;
  final String? level; // 'year' | 'month'

  /// queued | building | split | ready | removing | archived | empty |
  /// discarded | expired | error
  final String status;
  final String? stage; // compiling | zipping while building
  final int totalFiles;
  final int zippedFiles;
  final int fileCount;
  final int sourceBytes;
  final int zipBytes;
  final String? zipName;
  final String? zipUrl;
  final bool zipDeleted;
  final String? error;
  final int removedFiles;
  final int keptFiles;
  final int removedBytes;

  /// Photos in the ZIP. Copied, never removed: they stay in Cloud Files.
  final int photoFiles;

  /// Photos copied into the ZIP and left in Cloud Files on removal.
  final int photosKept;
  final List<String> months;
  final DateTime? createdAt;
  final DateTime? archivedAt;
  final DateTime? expiresAt;

  const CloudArchive({
    required this.id,
    required this.batchId,
    required this.folderPath,
    required this.status,
    this.level,
    this.stage,
    this.totalFiles = 0,
    this.zippedFiles = 0,
    this.fileCount = 0,
    this.sourceBytes = 0,
    this.zipBytes = 0,
    this.zipName,
    this.zipUrl,
    this.zipDeleted = false,
    this.error,
    this.removedFiles = 0,
    this.keptFiles = 0,
    this.removedBytes = 0,
    this.photoFiles = 0,
    this.photosKept = 0,
    this.months = const [],
    this.createdAt,
    this.archivedAt,
    this.expiresAt,
  });

  bool get isYearParent => status == 'split';
  bool get isBuilding => status == 'queued' || status == 'building';
  bool get isReady => status == 'ready';
  bool get isRemoving => status == 'removing';
  bool get isArchived => status == 'archived';
  bool get isError => status == 'error';
  bool get canDownload =>
      zipUrl != null && !zipDeleted && (isReady || isArchived || isRemoving);

  /// 0..1 while building, null while the server is still counting.
  double? get buildProgress {
    if (!isBuilding) return null;
    if (totalFiles == 0 || stage != 'zipping') return null;
    return (zippedFiles / totalFiles).clamp(0.0, 1.0);
  }

  String get name {
    final slash = folderPath.lastIndexOf('/');
    return slash >= 0 ? folderPath.substring(slash + 1) : folderPath;
  }

  factory CloudArchive.fromDoc(DocumentSnapshot<Map<String, dynamic>> d) {
    final m = d.data() ?? const {};
    DateTime? ts(Object? v) => v is Timestamp ? v.toDate() : null;
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    return CloudArchive(
      id: d.id,
      batchId: (m['batchId'] as String?) ?? d.id,
      folderPath: (m['folderPath'] as String?) ?? '',
      level: m['level'] as String?,
      status: (m['status'] as String?) ?? 'queued',
      stage: m['stage'] as String?,
      totalFiles: n(m['totalFiles']),
      zippedFiles: n(m['zippedFiles']),
      fileCount: n(m['fileCount']),
      sourceBytes: n(m['sourceBytes']),
      zipBytes: n(m['zipBytes']),
      zipName: m['zipName'] as String?,
      zipUrl: m['zipUrl'] as String?,
      zipDeleted: m['zipDeleted'] == true,
      error: m['error'] as String?,
      removedFiles: n(m['removedFiles']),
      keptFiles: n(m['keptFiles']),
      removedBytes: n(m['removedBytes']),
      photoFiles: n(m['photoFiles']),
      photosKept: n(m['photosKept']),
      months: ((m['months'] as List?) ?? const []).map((e) => '$e').toList(),
      createdAt: ts(m['createdAt']),
      archivedAt: ts(m['archivedAt']),
      expiresAt: ts(m['expiresAt']),
    );
  }
}

/// Outcome of confirming one archive.
class ArchiveRemoval {
  final String id;
  final int removed;
  final int kept;

  /// Photos copied into the ZIP and left in Cloud Files.
  final int photosKept;
  final int removedBytes;
  final String? error;
  final bool skipped;

  const ArchiveRemoval({
    required this.id,
    this.removed = 0,
    this.kept = 0,
    this.photosKept = 0,
    this.removedBytes = 0,
    this.error,
    this.skipped = false,
  });
}

/// A ZIP the server built; [url] downloads it directly (no auth header).
class ZipDownload {
  final String url;
  final String fileName;
  final int fileCount;
  final int zipBytes;

  const ZipDownload({
    required this.url,
    required this.fileName,
    required this.fileCount,
    required this.zipBytes,
  });
}

class CloudArchiveService {
  static CloudArchiveService? _instance;
  CloudArchiveService._internal();
  factory CloudArchiveService() =>
      _instance ??= CloudArchiveService._internal();

  static const String _collection = 'cloudArchives';
  static const _openStatuses = ['queued', 'building', 'ready', 'removing'];

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  FirebaseFunctions get _fn =>
      FirebaseFunctions.instanceFor(region: 'us-central1');

  /// `Distribution/2026` → year, `Distribution/2026/Oct 2026` → month.
  static bool isArchivableFolder(String path) =>
      RegExp(r'^Distribution/\d{4}(/[^/]+)?$').hasMatch(path);

  // ── Archives ────────────────────────────────────────────────────────────

  /// Start building the ZIP(s) for a year or month folder. Returns the batch
  /// id to watch.
  Future<String> start(String folderPath) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Not signed in');
    final ref = _db.collection(_collection).doc();
    await ref.set({
      'folderPath': folderPath,
      'requestedBy': user.uid,
      'requestedByName': user.displayName ?? user.email,
      'batchId': ref.id,
      'status': 'queued',
      'createdAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  /// Every doc of a batch: a month archive, or a year and its months.
  Stream<List<CloudArchive>> watchBatch(String batchId) => _db
      .collection(_collection)
      .where('batchId', isEqualTo: batchId)
      .snapshots()
      .map((s) => s.docs.map(CloudArchive.fromDoc).toList()
        ..sort((a, b) => a.folderPath.compareTo(b.folderPath)));

  /// Archives still being built or waiting for the user to confirm.
  Stream<List<CloudArchive>> watchOpen() => _db
      .collection(_collection)
      .where('status', whereIn: _openStatuses)
      .snapshots()
      .map((s) => s.docs.map(CloudArchive.fromDoc).toList());

  /// Months whose originals have been removed.
  Stream<List<CloudArchive>> watchArchived() => _db
      .collection(_collection)
      .where('status', isEqualTo: 'archived')
      .snapshots()
      .map((s) => s.docs.map(CloudArchive.fromDoc).toList());

  Future<CloudArchive?> get(String id) async {
    final d = await _db.collection(_collection).doc(id).get();
    return d.exists ? CloudArchive.fromDoc(d) : null;
  }

  /// Remove the originals of each ready archive from Cloud Files.
  Future<List<ArchiveRemoval>> confirm(List<String> archiveIds) async {
    final res = await _fn
        .httpsCallable('cloudArchive',
            options: HttpsCallableOptions(timeout: const Duration(minutes: 9)))
        .call({'action': 'confirm', 'archiveIds': archiveIds});
    final results = (res.data as Map)['results'] as List? ?? const [];
    return [
      for (final r in results)
        if (r is Map)
          ArchiveRemoval(
            id: '${r['id']}',
            removed: (r['removed'] as num?)?.toInt() ?? 0,
            kept: (r['kept'] as num?)?.toInt() ?? 0,
            photosKept: (r['photosKept'] as num?)?.toInt() ?? 0,
            removedBytes: (r['removedBytes'] as num?)?.toInt() ?? 0,
            error: r['error'] as String?,
            skipped: r['skipped'] == true,
          ),
    ];
  }

  /// Throw away ready ZIPs without touching any files.
  Future<void> discard(List<String> archiveIds) async {
    await _fn
        .httpsCallable('cloudArchive')
        .call({'action': 'discard', 'archiveIds': archiveIds});
  }

  // ── Manifest ────────────────────────────────────────────────────────────

  Future<ArchiveManifest?> readManifest(String folderPath) async {
    try {
      final bytes = await FirebaseStorage.instance
          .ref('$folderPath/$kArchiveManifestFile')
          .getData(10 * 1024 * 1024);
      if (bytes == null) return null;
      final json = jsonDecode(utf8.decode(bytes));
      if (json is! Map<String, dynamic>) return null;
      return ArchiveManifest.parse(folderPath, json);
    } on FirebaseException catch (e) {
      if (e.code != 'object-not-found') {
        debugPrint('readManifest($folderPath): $e');
      }
      return null;
    } catch (e) {
      debugPrint('readManifest($folderPath): $e');
      return null;
    }
  }

  // ── ZIP download ────────────────────────────────────────────────────────

  Future<ZipDownload> zip({
    List<String> files = const [],
    List<String> folders = const [],
    required String name,
  }) async {
    final res = await _fn
        .httpsCallable(
      'cloudFilesZip',
      options: HttpsCallableOptions(timeout: const Duration(minutes: 9)),
    )
        .call({'files': files, 'folders': folders, 'name': name});
    final m = Map<String, dynamic>.from(res.data as Map);
    return ZipDownload(
      url: m['url'] as String,
      fileName: m['fileName'] as String? ?? '$name.zip',
      fileCount: (m['fileCount'] as num?)?.toInt() ?? 0,
      zipBytes: (m['zipBytes'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Friendly text for a failed cloudArchive / cloudFilesZip call.
String describeCloudError(Object e) {
  if (e is FirebaseFunctionsException) {
    if (e.code == 'not-found' || e.code == 'unimplemented') {
      return 'This needs the cloudArchive / cloudFilesZip Cloud Functions, '
          'which are not deployed yet.';
    }
    return e.message ?? e.code;
  }
  return '$e';
}

/// "1.2 MB", "340 KB" …
String formatBytes(int? s) {
  if (s == null) return '—';
  if (s < 1024) return '$s B';
  if (s < 1024 * 1024) return '${(s / 1024).toStringAsFixed(0)} KB';
  if (s < 1024 * 1024 * 1024) {
    return '${(s / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(s / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
