import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/track_upload.dart';

/// Reads the clmgpx track-upload pings. Write-side lives in clmgpx; the
/// clmworking roster reads the same docs via getWorkingRoster.
class TrackUploadService {
  TrackUploadService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  /// Every ping dated `from`..`to` (yyyy-MM-dd, inclusive), live. One
  /// collection-group query rather than a listener per day; needs the
  /// `uploads.date` COLLECTION_GROUP index in firestore.indexes.json.
  Stream<List<TrackUpload>> watchRange(String from, String to) {
    return _firestore
        .collectionGroup('uploads')
        .where('date', isGreaterThanOrEqualTo: from)
        .where('date', isLessThanOrEqualTo: to)
        .snapshots()
        .map((snap) => snap.docs
            // Only trackUploads/{day}/uploads — ignore any other `uploads`
            // subcollection that might appear later.
            .where((d) => d.reference.parent.parent?.parent.id == 'trackUploads')
            .map((d) => TrackUpload.fromMap(d.data()))
            .toList());
  }
}
