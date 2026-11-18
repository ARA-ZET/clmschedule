import 'dart:math' as math;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';

import '../models/dropsheet_task_type_config.dart';
import '../models/vehicle_inspection.dart';

/// Reads the inspections clmgpx submits and records management's review.
///
/// The phone creates each inspection doc once; the office only ever writes
/// the `review` field (or deletes a rejected inspection so the driver can
/// redo it).
class VehicleInspectionService {
  VehicleInspectionService({
    FirebaseFirestore? firestore,
    FirebaseStorage? storage,
  })  : _db = firestore ?? FirebaseFirestore.instance,
        _storage = storage ?? FirebaseStorage.instance;

  final FirebaseFirestore _db;
  final FirebaseStorage _storage;

  CollectionReference<Map<String, dynamic>> get _inspections =>
      _db.collection('vehicleInspections');
  CollectionReference<Map<String, dynamic>> get _fleet =>
      _db.collection('fleetVehicles');

  static String dateKey(DateTime civil) =>
      '${civil.year.toString().padLeft(4, '0')}-'
      '${civil.month.toString().padLeft(2, '0')}-'
      '${civil.day.toString().padLeft(2, '0')}';

  Stream<List<VehicleInspection>> streamForDate(DateTime civilDate) =>
      _inspections
          .where('date', isEqualTo: dateKey(civilDate))
          .snapshots()
          .map((s) => s.docs.map(VehicleInspection.fromFirestore).toList());

  /// Live inspections from [fromCivil] to [toCivil] inclusive — the Fleet
  /// dashboard's window (today, the review queue, the trend and the flags).
  Stream<List<VehicleInspection>> streamRange(
          DateTime fromCivil, DateTime toCivil) =>
      _inspections
          .where('date', isGreaterThanOrEqualTo: dateKey(fromCivil))
          .where('date', isLessThanOrEqualTo: dateKey(toCivil))
          .snapshots()
          .map((s) => s.docs.map(VehicleInspection.fromFirestore).toList());

  /// Live inspections dated [fromCivil] or later — the admin alerts' window
  /// (open-ended, so a session left running past midnight still hears
  /// tomorrow's).
  Stream<List<VehicleInspection>> streamSince(DateTime fromCivil) =>
      _inspections
          .where('date', isGreaterThanOrEqualTo: dateKey(fromCivil))
          .snapshots()
          .map((s) => s.docs.map(VehicleInspection.fromFirestore).toList());

  /// Every inspection from [days] days before [civilDate] up to and
  /// including it — the history the review flags compare against.
  Future<List<VehicleInspection>> fetchRecent(DateTime civilDate,
      {int days = 30}) async {
    final from = civilDate.subtract(Duration(days: days));
    final snap = await _inspections
        .where('date', isGreaterThanOrEqualTo: dateKey(from))
        .where('date', isLessThanOrEqualTo: dateKey(civilDate))
        .get();
    return snap.docs.map(VehicleInspection.fromFirestore).toList();
  }

  Future<void> setReview(
    String inspectionId, {
    required InspectionReviewStatus status,
    String comment = '',
  }) {
    return _inspections.doc(inspectionId).update({
      'review': {
        'status': status.name,
        'by': _reviewerName(),
        'at': FieldValue.serverTimestamp(),
        'comment': comment.trim(),
      },
    });
  }

  /// Removes the record and its photos so the driver can submit it again
  /// (the phone may only create, never overwrite).
  Future<void> deleteForRedo(VehicleInspection inspection) async {
    for (final photo in inspection.photos.values) {
      if (photo.path.isEmpty) continue;
      try {
        await _storage.ref(photo.path).delete();
      } on FirebaseException catch (e) {
        // Already gone (e.g. expired by the 90-day lifecycle rule).
        if (e.code != 'object-not-found') rethrow;
      }
    }
    await _inspections.doc(inspection.id).delete();
  }

  /// Every inspection ever submitted — the photo-storage view's usage
  /// count (a few per day, so a single read stays small).
  Future<List<VehicleInspection>> fetchAll() async {
    final snap = await _inspections.get();
    return snap.docs.map(VehicleInspection.fromFirestore).toList();
  }

  /// Deletes [inspection]'s photo files to free storage, keeping the record
  /// (answers, defects, readings and photo fingerprints) and noting who
  /// cleared it and when. Safe to run again after a partial failure.
  Future<void> clearPhotos(VehicleInspection inspection) async {
    final paths = [
      for (final p in inspection.photos.values)
        if (p.path.isNotEmpty) p.path,
    ];
    // A few at a time: fast, without hundreds of requests in flight.
    for (var i = 0; i < paths.length; i += 6) {
      await Future.wait(paths.skip(i).take(6).map((path) async {
        try {
          await _storage.ref(path).delete();
        } on FirebaseException catch (e) {
          if (e.code != 'object-not-found') rethrow;
        }
        _urlCache.remove(path);
      }));
    }
    await _inspections.doc(inspection.id).update({
      'photosClearedAt': FieldValue.serverTimestamp(),
      'photosClearedBy': _reviewerName(),
    });
  }

  static String _reviewerName() {
    final user = FirebaseAuth.instance.currentUser;
    return user?.displayName?.isNotEmpty == true
        ? user!.displayName!
        : (user?.email ?? '');
  }

  final Map<String, Future<String?>> _urlCache = {};

  /// Download URL for a photo, or null when it no longer exists (photos
  /// are deleted after 90 days).
  Future<String?> photoUrl(String path) => _urlCache.putIfAbsent(path, () async {
        try {
          return await _storage.ref(path).getDownloadURL();
        } on FirebaseException catch (e) {
          if (e.code == 'object-not-found') return null;
          _urlCache.remove(path);
          rethrow;
        }
      });

  // ── Fleet ──────────────────────────────────────────────────────────────

  Stream<List<FleetVehicle>> streamFleet() => _fleet.snapshots().map((s) => s
      .docs
      .map((d) => FleetVehicle.fromMap(d.id, d.data()))
      .toList());

  Future<void> saveFleetVehicle(FleetVehicle vehicle) =>
      _fleet.doc(vehicle.key).set(vehicle.toMap(), SetOptions(merge: true));

  // ── Review flags ───────────────────────────────────────────────────────

  /// Works out which [InspectionFlag]s apply to [inspection], comparing it
  /// with [history] (other inspections, any vehicle) and the [depot].
  static Set<InspectionFlag> flagsFor(
    VehicleInspection inspection, {
    required List<VehicleInspection> history,
    DepotConfig? depot,
  }) {
    final flags = <InspectionFlag>{};

    final duration = inspection.durationSec;
    if (duration != null && duration < kInspectionMinDuration.inSeconds) {
      flags.add(InspectionFlag.tooFast);
    }

    if (depot != null &&
        depot.hasCoordinates &&
        inspection.lat != null &&
        inspection.lng != null &&
        distanceM(inspection.lat!, inspection.lng!, depot.lat!, depot.lng!) >
            kInspectionDepotRadiusM + (inspection.accuracyM ?? 0)) {
      flags.add(InspectionFlag.offSite);
    }

    final required = <String>{
      for (final s in kInspectionChecklist)
        for (final i in s.items) ...i.photoSlots,
      ...kInspectionFixedSlots,
    };
    if (!required.every(inspection.photos.containsKey)) {
      flags.add(InspectionFlag.missingPhotos);
    }

    final others = history.where((h) => h.id != inspection.id);

    // Odometer: compare with the latest earlier reading of the same vehicle.
    final km = inspection.odometerKm;
    if (km != null) {
      VehicleInspection? previous;
      for (final h in others) {
        if (h.vehicleKey != inspection.vehicleKey || h.odometerKm == null) {
          continue;
        }
        if (_sortKey(h).compareTo(_sortKey(inspection)) >= 0) continue;
        if (previous == null ||
            _sortKey(h).compareTo(_sortKey(previous)) > 0) {
          previous = h;
        }
      }
      if (previous != null && km < previous.odometerKm!) {
        flags.add(InspectionFlag.odometerBackwards);
      }
    }

    final seen = <String>{
      for (final h in others)
        for (final p in h.photos.values)
          if (p.sha256.isNotEmpty) p.sha256,
    };
    final mine = inspection.photos.values
        .map((p) => p.sha256)
        .where((s) => s.isNotEmpty)
        .toList();
    if (mine.any(seen.contains) || mine.toSet().length < mine.length) {
      flags.add(InspectionFlag.duplicatePhoto);
    }

    return flags;
  }

  /// The review flags in plain words, with the detail behind each ("Done in
  /// 1 min", "2.2 km from the depot"). Empty = nothing suspicious; defects
  /// are listed separately.
  static List<String> attentionPoints(
    VehicleInspection inspection,
    Set<InspectionFlag> flags, {
    DepotConfig? depot,
  }) {
    final points = <String>[];
    for (final flag in InspectionFlag.values) {
      if (!flags.contains(flag)) continue;
      points.add(switch (flag) {
        InspectionFlag.tooFast => () {
            final s = inspection.durationSec ?? 0;
            final took = s < 60 ? '$s s' : '${(s / 60).round()} min';
            return 'Done in $took — too fast for every photo';
          }(),
        InspectionFlag.offSite => () {
            final d = depot != null &&
                    depot.hasCoordinates &&
                    inspection.lat != null &&
                    inspection.lng != null
                ? distanceM(
                    inspection.lat!, inspection.lng!, depot.lat!, depot.lng!)
                : null;
            return d == null
                ? 'Not done at the depot'
                : 'Done ${d >= 1000 ? '${(d / 1000).toStringAsFixed(1)} km' : '${d.round()} m'} from the depot';
          }(),
        InspectionFlag.odometerBackwards =>
          'Odometer lower than the last reading',
        InspectionFlag.duplicatePhoto =>
          'A photo was reused from another inspection',
        InspectionFlag.missingPhotos => 'Photos missing',
      });
    }
    return points;
  }

  /// The most recent odometer reading for [vehicleKey] in [inspections],
  /// with the inspection it came from; null when none has one.
  static VehicleInspection? latestOdometer(
      List<VehicleInspection> inspections, String vehicleKey) {
    VehicleInspection? latest;
    for (final i in inspections) {
      if (i.vehicleKey != vehicleKey || i.odometerKm == null) continue;
      if (latest == null || _sortKey(i).compareTo(_sortKey(latest)) > 0) {
        latest = i;
      }
    }
    return latest;
  }

  /// Orders a vehicle's inspections: by day, start before end.
  static String _sortKey(VehicleInspection i) => '${i.date}_${i.kind.index}';

  static double distanceM(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    double rad(double d) => d * math.pi / 180;
    final dLat = rad(lat2 - lat1);
    final dLng = rad(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(rad(lat1)) *
            math.cos(rad(lat2)) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(a));
  }
}
