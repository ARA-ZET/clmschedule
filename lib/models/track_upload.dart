import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../utils/schedule_time.dart';
import 'distributor.dart';

/// A clmgpx "I've uploaded my track" ping, stored at
/// `trackUploads/{yyyy-MM-dd}/uploads/{id}`. [date] is the SAST day the track
/// was recorded, not the day it reached Drive.
class TrackUpload {
  final String? distributorId;
  final String distributorName;
  final String date;
  final DateTime? uploadedAt;

  const TrackUpload({
    this.distributorId,
    required this.distributorName,
    required this.date,
    this.uploadedAt,
  });

  factory TrackUpload.fromMap(Map<String, dynamic> data) {
    final at = data['uploadedAt'];
    return TrackUpload(
      distributorId: data['distributorId'] as String?,
      distributorName: (data['distributorName'] as String? ?? '').trim(),
      date: data['date'] as String? ?? '',
      uploadedAt: at is Timestamp ? toScheduleCivil(at.toDate()) : null,
    );
  }
}

/// The `trackUploads` doc id for a SAST civil date.
String trackUploadDayId(DateTime civilDate) =>
    DateFormat('yyyy-MM-dd').format(civilDate);

/// Case/spacing/punctuation-insensitive key for matching typed names. Must
/// stay identical to `normalizePersonName` in functions/index.js so the
/// schedule and the clmworking roster agree on what matches.
String normalizePersonName(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .trim();

/// Uploads resolved against the schedule's distributor rows: matched by
/// distributorId first, then by name; anything else is "no match".
class TrackUploadIndex {
  TrackUploadIndex._(this._uploaded, this._unmatched);

  /// dayId -> distributorId -> latest upload time.
  final Map<String, Map<String, DateTime?>> _uploaded;

  /// dayId -> unmatched display names, sorted.
  final Map<String, List<String>> _unmatched;

  static final TrackUploadIndex empty = TrackUploadIndex._(const {}, const {});

  factory TrackUploadIndex.build(
    Iterable<TrackUpload> uploads,
    Iterable<Distributor> distributors,
  ) {
    final ids = {for (final d in distributors) d.id};
    final byName = {
      for (final d in distributors) normalizePersonName(d.name): d.id,
    };

    final uploaded = <String, Map<String, DateTime?>>{};
    final unmatched = <String, Map<String, String>>{};
    for (final u in uploads) {
      final key = normalizePersonName(u.distributorName);
      final id = ids.contains(u.distributorId) ? u.distributorId : byName[key];
      if (id != null) {
        final day = uploaded.putIfAbsent(u.date, () => {});
        final prev = day[id];
        if (!day.containsKey(id) ||
            (u.uploadedAt != null &&
                (prev == null || u.uploadedAt!.isAfter(prev)))) {
          day[id] = u.uploadedAt;
        }
      } else if (key.isNotEmpty) {
        unmatched.putIfAbsent(u.date, () => {}).putIfAbsent(
              key,
              () => u.distributorName,
            );
      }
    }

    return TrackUploadIndex._(uploaded, {
      for (final e in unmatched.entries)
        e.key: e.value.values.toList()..sort(),
    });
  }

  bool isUploaded(String distributorId, DateTime civilDate) =>
      _uploaded[trackUploadDayId(civilDate)]?.containsKey(distributorId) ??
      false;

  /// distributorId -> upload time for every matched upload on the day.
  Map<String, DateTime?> uploadedOn(DateTime civilDate) =>
      _uploaded[trackUploadDayId(civilDate)] ?? const {};

  List<String> unmatchedOn(DateTime civilDate) =>
      _unmatched[trackUploadDayId(civilDate)] ?? const [];
}
