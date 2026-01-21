import 'package:cloud_firestore/cloud_firestore.dart';

class AppVersion {
  final String version;
  final DateTime lastUpdated;
  final String? updateMessage;
  final bool forceUpdate;

  AppVersion({
    required this.version,
    required this.lastUpdated,
    this.updateMessage,
    this.forceUpdate = true,
  });

  factory AppVersion.fromMap(Map<String, dynamic> data) {
    return AppVersion(
      version: data['version'] as String? ?? '1.0.0',
      lastUpdated:
          (data['lastUpdated'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updateMessage: data['updateMessage'] as String?,
      forceUpdate: data['forceUpdate'] as bool? ?? true,
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
    return 'AppVersion(version: $version, lastUpdated: $lastUpdated, forceUpdate: $forceUpdate)';
  }
}
