import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/app_version.dart';

class AppVersionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collectionName = 'appConfig';
  static const String _versionDocId = 'version';

  // Get the version document reference
  DocumentReference<Map<String, dynamic>> get _versionDoc =>
      _firestore.collection(_collectionName).doc(_versionDocId);

  // Stream the current app version from Firestore.
  //
  // Offline persistence is enabled app-wide, so this document is first served
  // from the local cache — a *stale* value from the previous session. Emitting
  // it would make the client think it had just seen a deploy the moment the
  // real server value arrived. Cache-only snapshots are therefore dropped: an
  // update prompt must be based on what the server actually says.
  Stream<AppVersion> streamAppVersion() {
    return _versionDoc
        .snapshots(includeMetadataChanges: true)
        .where((snapshot) => !snapshot.metadata.isFromCache)
        .map((snapshot) {
      if (!snapshot.exists || snapshot.data() == null) {
        // Return default version if document doesn't exist
        return AppVersion(
          version: '1.0.0',
          lastUpdated: DateTime.now(),
          forceUpdate: false,
        );
      }
      return AppVersion.fromMap(snapshot.data()!);
    });
  }

  // Get current version once (not streaming). Forced to the server so a
  // cached copy from the last session cannot masquerade as the live version.
  Future<AppVersion> getCurrentVersion() async {
    final snapshot =
        await _versionDoc.get(const GetOptions(source: Source.server));
    if (!snapshot.exists || snapshot.data() == null) {
      return AppVersion(
        version: '1.0.0',
        lastUpdated: DateTime.now(),
        forceUpdate: false,
      );
    }
    return AppVersion.fromMap(snapshot.data()!);
  }

  // Update the version (admin only - typically done manually in Firestore console)
  Future<void> updateVersion(AppVersion version) async {
    await _versionDoc.set(version.toMap());
  }
}
