import 'package:cloud_firestore/cloud_firestore.dart';

class AppVersion {
  final String version;
  final DateTime lastUpdated;
  final String? updateMessage;
  final bool forceUpdate;

  /// The `lastUpdated` value actually stored in Firestore, or null when the
  /// document carries none. Unlike [lastUpdated] this is never substituted
  /// with "now", so it can be compared across snapshots to detect a redeploy
  /// that reused the same version string (two deploys on the same day, which
  /// the date-based version scheme cannot tell apart).
  final DateTime? serverTimestamp;

  AppVersion({
    required this.version,
    required this.lastUpdated,
    this.updateMessage,
    this.forceUpdate = true,
    this.serverTimestamp,
  });

  factory AppVersion.fromMap(Map<String, dynamic> data) {
    final ts = (data['lastUpdated'] as Timestamp?)?.toDate();
    return AppVersion(
      version: data['version'] as String? ?? '1.0.0',
      lastUpdated: ts ?? DateTime.now(),
      updateMessage: data['updateMessage'] as String?,
      forceUpdate: data['forceUpdate'] as bool? ?? true,
      serverTimestamp: ts,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'version': version,
      'lastUpdated': Timestamp.fromDate(lastUpdated),
      'updateMessage': updateMessage,
      'forceUpdate': forceUpdate,
    };
  }

  @override
  String toString() {
    return 'AppVersion(version: $version, lastUpdated: $lastUpdated, '
        'forceUpdate: $forceUpdate)';
  }
}
