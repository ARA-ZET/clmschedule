import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

import '../../services/storage_upload.dart';
import '../models/erf_property.dart';
import 'erf_area_codec.dart';

/// Stores each downloaded area's parcels as a single Cloud Storage object.
///
/// One area = one file, read or written once. This replaces a document per
/// parcel in Firestore, which made a suburb download tens of thousands of
/// writes and every open the same number of reads. Firestore now holds only
/// the small `erfAreas` metadata document, which points here.
class ErfAreaStorageService {
  ErfAreaStorageService({FirebaseStorage? storage})
      : _storage = storage ?? FirebaseStorage.instance;

  final FirebaseStorage _storage;

  /// Folder holding one gzipped payload per area.
  static const String folder = 'erfAreas';

  /// Storage path for an area's payload.
  static String pathFor(String areaId) => '$folder/$areaId.json.gz';

  /// Upload an area's parcels, replacing any previous payload.
  ///
  /// Returns the number of bytes stored, for the metadata document.
  Future<int> save({
    required String areaId,
    required String name,
    required List<ErfProperty> properties,
  }) async {
    final bytes = ErfAreaCodec.encode(
      areaId: areaId,
      name: name,
      properties: properties,
    );

    // Only a content type, deliberately. Object metadata would be pure
    // duplication here: the payload itself opens with the format version,
    // area id, name and count, and the `erfAreas` document carries the rest.
    // Staying header-free also keeps this on the plain `media` upload rather
    // than the multipart path (see StorageUpload).
    await StorageUpload.safePutData(
      _storage.ref(pathFor(areaId)),
      bytes,
      metadata: SettableMetadata(contentType: 'application/gzip'),
    );

    debugPrint('☁️ Stored ${properties.length} parcels for $areaId '
        '(${(bytes.length / 1024).toStringAsFixed(0)} KB)');
    return bytes.length;
  }

  /// Download and decode an area's parcels.
  ///
  /// Returns null when the area has no payload stored (an older area whose
  /// parcels still live in Firestore, or one whose file was removed).
  Future<List<ErfProperty>?> load(String areaId) async {
    try {
      // Areas can be large; the cap is generous but stops a runaway read.
      final bytes = await _storage
          .ref(pathFor(areaId))
          .getData(96 * 1024 * 1024);
      if (bytes == null) return null;

      return ErfAreaCodec.decode(bytes, areaId: areaId);
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return null;
      debugPrint('❌ Error loading area payload $areaId: $e');
      rethrow;
    }
  }

  /// Remove an area's payload. Missing files are not an error.
  Future<void> delete(String areaId) async {
    try {
      await _storage.ref(pathFor(areaId)).delete();
    } on FirebaseException catch (e) {
      if (e.code == 'object-not-found') return;
      debugPrint('❌ Error deleting area payload $areaId: $e');
      rethrow;
    }
  }
}
