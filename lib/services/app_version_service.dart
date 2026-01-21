import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/app_version.dart';

class AppVersionService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _versionDocId = 'current_version';

  // Get the version document reference
  DocumentReference<Map<String, dynamic>> get _versionDoc =>
      _firestore.collection('app_config').doc(_versionDocId);

  // Stream the current app version from Firestore
  Stream<AppVersion> streamAppVersion() {
    return _versionDoc.snapshots().map((snapshot) {
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

  // Get current version once (not streaming)
  Future<AppVersion> getCurrentVersion() async {
    final snapshot = await _versionDoc.get();
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
