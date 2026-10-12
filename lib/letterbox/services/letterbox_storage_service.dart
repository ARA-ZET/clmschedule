import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../../services/storage_upload.dart';

/// Reads and writes the per-suburb letterbox payloads in Cloud Storage.
///
/// One gzipped object per suburb at `letterboxes/{suburbId}.json.gz`. Per
/// suburb, not per city, because curation is per suburb: a save rewrites one
/// small object rather than contending on a single global file.
class LetterboxStorageService {
  static const String folder = 'letterboxes';

  /// Generous explicit cap. The default `getData()` limit is 10 MB, and a
  /// silent null on overflow is exactly how the compiled-GPX fast path fails
  /// today — a whole-metro payload would trip it. Suburb files are ~8 KB, so
  /// this ceiling should never be reached; if it is, something is wrong and we
  /// want the error, not a silent zero.
  static const int _maxDownloadBytes = 64 * 1024 * 1024;

  final FirebaseStorage? _injectedStorage;

  /// Resolved lazily rather than in the initializer list so that subclasses
  /// which override every method — test fakes, chiefly — never touch
  /// `FirebaseStorage.instance` and so do not require an initialised app.
  FirebaseStorage get _storage => _injectedStorage ?? FirebaseStorage.instance;

  LetterboxStorageService({FirebaseStorage? storage})
      : _injectedStorage = storage;

  static String pathFor(String suburbId) => '$folder/$suburbId.json.gz';

  /// Upload [bytes] for [suburbId]. Returns the byte count for the metadata
  /// document.
  Future<int> save(String suburbId, Uint8List bytes) async {
    final ref = _storage.ref(pathFor(suburbId));
    // Content type ONLY, deliberately — matching ErfAreaStorageService.
    //
    // Two reasons, both learned the hard way:
    //  * Any extra metadata field switches StorageUpload off the plain `media`
    //    upload onto the multipart path, which is the fragile one on WASM.
    //  * A `cacheControl` of `max-age` is actively wrong here. This file is
    //    edited and re-read in the same session, so a cached copy means you
    //    save a correction, reload the suburb, and are shown the version from
    //    before the edit. Re-fetching a ~4 KB object costs nothing; showing a
    //    curator stale letterboxes costs them their work.
    await StorageUpload.safePutData(
      ref,
      bytes,
      metadata: SettableMetadata(contentType: 'application/gzip'),
    );
    return bytes.length;
  }

  /// Download the payload for [suburbId], or null when no file exists yet.
  ///
  /// Only a genuinely missing object returns null. Every other failure is
  /// rethrown: a network error must not be mistaken for "this suburb has no
  /// letterboxes", which would quietly understate a quote.
  Future<Uint8List?> load(String suburbId) async {
    try {
      return await _storage.ref(pathFor(suburbId)).getData(_maxDownloadBytes);
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return null;
      debugPrint(
          '[LetterboxStorage] load($suburbId) failed: ${e.code} ${e.message}');
      rethrow;
    }
  }

  Future<void> delete(String suburbId) async {
    try {
      await _storage.ref(pathFor(suburbId)).delete();
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return;
      rethrow;
    }
  }
}
