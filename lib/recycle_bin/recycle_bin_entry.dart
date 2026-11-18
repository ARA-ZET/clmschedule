// recycle_bin/recycle_bin_entry.dart
//
// A deleted item waiting in the Recycle Bin (`recycleBin/{id}`).
//
// Deleting moves a copy here in the same batch/transaction as the delete, so
// a delete can never succeed while its copy is lost. Items stay for
// [kRecycleBinRetention], then the daily `sweepRecycleBin` function purges
// them. Anyone signed in can restore; only admins can purge early.
//
// The bin is a separate collection rather than an `isDeleted` flag on the
// original: a flag would leak deleted items into month summaries,
// collection-group queries, the AI assistant and folder reconciliation.
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

const String kRecycleBinCollection = 'recycleBin';

/// Storage prefix for deleted Cloud Files and oversized payloads.
const String kRecycleBinStoragePrefix = 'recycleBin/';

const Duration kRecycleBinRetention = Duration(days: 30);

/// The bin screen's tabs — one per app area.
enum RecycleBinTab {
  jobList('Job List', Icons.list_alt),
  schedule('Schedule', Icons.calendar_month),
  maps('Maps', Icons.map_outlined),
  cloudFiles('Cloud Files', Icons.cloud_outlined),
  clients('Clients & Distributors', Icons.people_outline),
  settings('Settings', Icons.tune);

  const RecycleBinTab(this.label, this.icon);
  final String label;
  final IconData icon;
}

/// What kind of thing was deleted; decides which restore handler runs.
enum RecycleBinType {
  jobListItem(RecycleBinTab.jobList, Icons.work_outline),
  scheduleJob(RecycleBinTab.schedule, Icons.event_note),
  shareableMap(RecycleBinTab.maps, Icons.map),
  clientArea(RecycleBinTab.maps, Icons.pentagon_outlined),
  workArea(RecycleBinTab.maps, Icons.crop_square),
  cloudFile(RecycleBinTab.cloudFiles, Icons.insert_drive_file_outlined),
  cloudFolder(RecycleBinTab.cloudFiles, Icons.folder_outlined),
  regularClient(RecycleBinTab.clients, Icons.repeat),
  distributor(RecycleBinTab.clients, Icons.person_outline),
  driver(RecycleBinTab.clients, Icons.local_shipping_outlined),
  unfinishedWorkArea(RecycleBinTab.schedule, Icons.pending_actions),
  jobType(RecycleBinTab.settings, Icons.category_outlined),
  jobStatus(RecycleBinTab.settings, Icons.flag_outlined),
  jobListStatus(RecycleBinTab.settings, Icons.flag_outlined),
  invoiceStatus(RecycleBinTab.settings, Icons.receipt_long_outlined),
  mapInstruction(RecycleBinTab.settings, Icons.description_outlined);

  const RecycleBinType(this.tab, this.icon);
  final RecycleBinTab tab;
  final IconData icon;

  static RecycleBinType? byName(String? name) {
    for (final t in values) {
      if (t.name == name) return t;
    }
    return null;
  }
}

/// A side document deleted together with the item (an invoice index, a
/// Happy Sun project, a share link), put back on restore when its id is
/// still free.
class RecycleBinRelated {
  final String path;
  final Map<String, dynamic> data;
  const RecycleBinRelated(this.path, this.data);

  Map<String, dynamic> toMap() => {'path': path, 'data': data};

  static RecycleBinRelated fromMap(Map<String, dynamic> m) => RecycleBinRelated(
        m['path'] as String,
        Map<String, dynamic>.from(m['data'] as Map? ?? const {}),
      );
}

/// Thrown by a restore handler when the original id or path has been taken
/// again since the delete. Restoring never overwrites.
class RestoreConflict implements Exception {
  final String message;
  const RestoreConflict(this.message);

  @override
  String toString() => message;
}

class RecycleBinEntry {
  final String id;
  final RecycleBinType type;
  final String label;

  /// Firestore path of the deleted document (for a schedule job, the day doc;
  /// the job id is in [payload]). For Cloud Files, the original folder path.
  final String originalPath;

  /// The deleted document's raw data (`doc.data()`, never a model's toMap,
  /// so fields the app doesn't model survive the round trip).
  final Map<String, dynamic> payload;

  /// Storage path of a gzipped payload, used instead of [payload] when the
  /// document would be too big to copy into one Firestore doc.
  final String? payloadRef;

  final List<RecycleBinRelated> related;

  /// Cloud Files: original object path → where it sits in the bin.
  final Map<String, String> storagePaths;

  /// Storage objects that belong to the deleted item and stay where they are
  /// while it is in the bin (a map's thumbnail), deleted when it is purged.
  final List<String> ownedStorage;

  final DateTime? deletedAt;
  final String deletedByUid;
  final String deletedByName;
  final DateTime? expiresAt;
  final DateTime? restoredAt;

  const RecycleBinEntry({
    required this.id,
    required this.type,
    required this.label,
    required this.originalPath,
    required this.payload,
    this.payloadRef,
    this.related = const [],
    this.storagePaths = const {},
    this.ownedStorage = const [],
    this.deletedAt,
    this.deletedByUid = '',
    this.deletedByName = '',
    this.expiresAt,
    this.restoredAt,
  });

  RecycleBinTab get tab => type.tab;

  /// Whole days until the daily sweep removes it (0 = goes tonight).
  int? get daysLeft {
    final e = expiresAt;
    if (e == null) return null;
    final d = e.difference(DateTime.now()).inHours / 24;
    return d <= 0 ? 0 : d.ceil();
  }

  static RecycleBinEntry? fromDoc(DocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    if (d == null) return null;
    final type = RecycleBinType.byName(d['type'] as String?);
    if (type == null) return null;
    final by = Map<String, dynamic>.from(d['deletedBy'] as Map? ?? const {});
    return RecycleBinEntry(
      id: doc.id,
      type: type,
      label: d['label'] as String? ?? '(untitled)',
      originalPath: d['originalPath'] as String? ?? '',
      payload: Map<String, dynamic>.from(d['payload'] as Map? ?? const {}),
      payloadRef: d['payloadRef'] as String?,
      related: [
        for (final r in (d['related'] as List? ?? const []))
          RecycleBinRelated.fromMap(Map<String, dynamic>.from(r as Map)),
      ],
      storagePaths: Map<String, String>.from(d['storagePaths'] as Map? ?? {}),
      ownedStorage: List<String>.from(d['ownedStorage'] as List? ?? const []),
      deletedAt: (d['deletedAt'] as Timestamp?)?.toDate(),
      deletedByUid: by['uid'] as String? ?? '',
      deletedByName:
          by['name'] as String? ?? by['email'] as String? ?? 'Someone',
      expiresAt: (d['expiresAt'] as Timestamp?)?.toDate(),
      restoredAt: (d['restoredAt'] as Timestamp?)?.toDate(),
    );
  }
}
