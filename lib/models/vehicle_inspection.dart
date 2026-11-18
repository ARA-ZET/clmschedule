import 'package:cloud_firestore/cloud_firestore.dart';

// Daily vehicle inspections, done by drivers in the clmgpx field app at the
// start and the end of every shift and reviewed by management in
// Apps → Fleet.
//
// CONTRACT shared with the clmgpx repo
// (lib/features/inspection/models/inspection_checklist.dart): the checklist
// ids, photo slot keys, Firestore shape and Storage paths below must match on
// both sides — change them together. The phone writes:
//
//   vehicleInspections/{date}_{vehicleKey}_{kind}      (create-only)
//   vehicleInspections/{date}/{inspectionId}/{slot}_{token}.jpg   (Storage)
//
// `vehicleKey` is the dropsheet vehicle enum name ('hyundai', 'mahindra',
// 'nissan'); plates and other fleet details live in fleetVehicles/{vehicleKey}.

/// When in the shift the inspection was done.
enum InspectionKind {
  start,
  end;

  String get label => this == start ? 'Start of day' : 'End of day';

  static InspectionKind fromKey(String? key) =>
      key == 'end' ? InspectionKind.end : InspectionKind.start;

  /// Only the morning check is required (user's call, 2026-11-03). `end` is
  /// kept so any end-of-day records already submitted still read and show.
  bool get isRequired => this == start;
}

enum InspectionItemStatus {
  ok,
  defect,
  na;

  static InspectionItemStatus fromKey(String? key) => switch (key) {
        'defect' => InspectionItemStatus.defect,
        'na' => InspectionItemStatus.na,
        _ => InspectionItemStatus.ok,
      };
}

enum DefectSeverity {
  minor,
  major,
  unsafe;

  String get label => switch (this) {
        minor => 'Minor',
        major => 'Major',
        unsafe => 'Unsafe — do not drive',
      };

  static DefectSeverity fromKey(String? key) => switch (key) {
        'major' => DefectSeverity.major,
        'unsafe' => DefectSeverity.unsafe,
        _ => DefectSeverity.minor,
      };
}

enum InspectionReviewStatus {
  pending,
  approved,
  rejected;

  static InspectionReviewStatus fromKey(String? key) => switch (key) {
        'approved' => InspectionReviewStatus.approved,
        'rejected' => InspectionReviewStatus.rejected,
        _ => InspectionReviewStatus.pending,
      };
}

// ── Checklist (version 1, the basic daily check) ───────────────────────────

class InspectionChecklistItem {
  final String id;
  final String label;

  /// Photo slots this item requires (keys into [VehicleInspection.photos]).
  final List<String> photoSlots;

  const InspectionChecklistItem(this.id, this.label, this.photoSlots);
}

class InspectionChecklistSection {
  final String id;
  final String title;
  final List<InspectionChecklistItem> items;

  const InspectionChecklistSection(this.id, this.title, this.items);
}

const int kInspectionChecklistVersion = 1;

const List<InspectionChecklistSection> kInspectionChecklist = [
  InspectionChecklistSection('walkaround', 'Walk-around (exterior)', [
    InspectionChecklistItem(
        'leaks',
        'Look under the vehicle for leaks or drips (oil, coolant, fuel, fluid)',
        ['under']),
    InspectionChecklistItem(
        'body',
        'Body: check for new dents, scratches or damage',
        ['front', 'back', 'left', 'right']),
    InspectionChecklistItem(
        'tyres',
        'Tyres: correct pressure by sight, no cuts, bulges or uneven wear',
        ['tyre_lf', 'tyre_rf', 'tyre_lr', 'tyre_rr']),
    InspectionChecklistItem(
        'spare', 'Spare tyre present and inflated', ['spare']),
    InspectionChecklistItem(
        'plates',
        'Number plates: clean, secure and legible',
        ['plate_front', 'plate_rear']),
  ]),
  InspectionChecklistSection('bonnet', 'Under the bonnet', [
    InspectionChecklistItem('oil',
        'Engine oil level between MIN and MAX on the dipstick', ['dipstick']),
    InspectionChecklistItem(
        'radiator', 'Radiator water level full', ['radiator']),
  ]),
];

/// Photos every inspection needs besides the checklist items.
const List<String> kInspectionFixedSlots = ['odometer', 'fuel_gauge'];

/// Plain-language name of a photo slot.
String inspectionSlotLabel(String slot) => switch (slot) {
      'under' => 'Under the vehicle',
      'front' => 'Front',
      'back' => 'Back',
      'left' => 'Left side',
      'right' => 'Right side',
      'tyre_lf' => 'Front-left tyre',
      'tyre_rf' => 'Front-right tyre',
      'tyre_lr' => 'Rear-left tyre',
      'tyre_rr' => 'Rear-right tyre',
      'spare' => 'Spare tyre',
      'plate_front' => 'Front plate',
      'plate_rear' => 'Rear plate',
      'dipstick' => 'Oil dipstick',
      'radiator' => 'Radiator',
      'odometer' => 'Odometer',
      'fuel_gauge' => 'Fuel gauge',
      'spot_check' => 'Spot check',
      _ => slot,
    };

/// Short checklist item name for tags and notifications ("Tyres").
String shortItemLabel(String itemId) => switch (itemId) {
      'leaks' => 'Leaks',
      'body' => 'Body damage',
      'tyres' => 'Tyres',
      'spare' => 'Spare tyre',
      'plates' => 'Number plates',
      'oil' => 'Engine oil',
      'radiator' => 'Radiator',
      _ => itemId,
    };

String checklistItemLabel(String itemId) {
  for (final s in kInspectionChecklist) {
    for (final i in s.items) {
      if (i.id == itemId) return i.label;
    }
  }
  return itemId;
}

// ── Inspection record ──────────────────────────────────────────────────────

class InspectionItemResult {
  final InspectionItemStatus status;
  final String note;

  const InspectionItemResult({required this.status, this.note = ''});

  factory InspectionItemResult.fromMap(Map<String, dynamic> m) =>
      InspectionItemResult(
        status: InspectionItemStatus.fromKey(m['status'] as String?),
        note: (m['note'] as String?) ?? '',
      );
}

class InspectionPhoto {
  final String slot;

  /// Cloud Storage object path.
  final String path;
  final DateTime? capturedAt;
  final double? lat;
  final double? lng;

  /// sha256 of the uploaded JPEG — used to spot a photo reused from an
  /// earlier inspection.
  final String sha256;
  final int bytes;

  const InspectionPhoto({
    required this.slot,
    required this.path,
    this.capturedAt,
    this.lat,
    this.lng,
    this.sha256 = '',
    this.bytes = 0,
  });

  factory InspectionPhoto.fromMap(String slot, Map<String, dynamic> m) =>
      InspectionPhoto(
        slot: slot,
        path: (m['path'] as String?) ?? '',
        capturedAt: _date(m['capturedAt']),
        lat: (m['lat'] as num?)?.toDouble(),
        lng: (m['lng'] as num?)?.toDouble(),
        sha256: (m['sha256'] as String?) ?? '',
        bytes: (m['bytes'] as num?)?.toInt() ?? 0,
      );
}

class InspectionDefect {
  final String itemId;
  final String note;
  final DefectSeverity severity;

  const InspectionDefect({
    required this.itemId,
    required this.note,
    required this.severity,
  });

  factory InspectionDefect.fromMap(Map<String, dynamic> m) => InspectionDefect(
        itemId: (m['itemId'] as String?) ?? '',
        note: (m['note'] as String?) ?? '',
        severity: DefectSeverity.fromKey(m['severity'] as String?),
      );
}

class InspectionReview {
  final InspectionReviewStatus status;
  final String by;
  final DateTime? at;
  final String comment;

  const InspectionReview({
    this.status = InspectionReviewStatus.pending,
    this.by = '',
    this.at,
    this.comment = '',
  });

  factory InspectionReview.fromMap(Map<String, dynamic>? m) => m == null
      ? const InspectionReview()
      : InspectionReview(
          status: InspectionReviewStatus.fromKey(m['status'] as String?),
          by: (m['by'] as String?) ?? '',
          at: _date(m['at']),
          comment: (m['comment'] as String?) ?? '',
        );
}

class VehicleInspection {
  final String id;
  final String date; // 'yyyy-MM-dd' (SAST)
  final InspectionKind kind;
  final String vehicleKey;
  final String vehicleLabel;
  final String plateNumber;
  final String trailer;
  final String driverId;
  final String driverName;
  final String distributorId;
  final String dropsheetTaskId;
  final int checklistVersion;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final DateTime? submittedAt;
  final int? odometerKm;
  final String fuelLevel;
  final double? lat;
  final double? lng;
  final double? accuracyM;
  final Map<String, InspectionItemResult> items;
  final Map<String, InspectionPhoto> photos;
  final String spotCheckPrompt;
  final List<InspectionDefect> defects;

  /// 'pass' | 'passWithDefects' | 'fail' — set by the phone from [defects].
  final String result;
  final InspectionReview review;
  final String appVersion;

  /// Set when the office cleared this inspection's photos early to free
  /// storage. The answers, defects and photo fingerprints (sha256, used by
  /// the reused-photo flag) are kept; only the image files are gone.
  final DateTime? photosClearedAt;
  final String photosClearedBy;

  const VehicleInspection({
    required this.id,
    required this.date,
    required this.kind,
    required this.vehicleKey,
    this.vehicleLabel = '',
    this.plateNumber = '',
    this.trailer = '',
    this.driverId = '',
    this.driverName = '',
    this.distributorId = '',
    this.dropsheetTaskId = '',
    this.checklistVersion = kInspectionChecklistVersion,
    this.startedAt,
    this.completedAt,
    this.submittedAt,
    this.odometerKm,
    this.fuelLevel = '',
    this.lat,
    this.lng,
    this.accuracyM,
    this.items = const {},
    this.photos = const {},
    this.spotCheckPrompt = '',
    this.defects = const [],
    this.result = 'pass',
    this.review = const InspectionReview(),
    this.appVersion = '',
    this.photosClearedAt,
    this.photosClearedBy = '',
  });

  bool get photosCleared => photosClearedAt != null;

  /// Bytes the photo files take up (as recorded by the phone).
  int get photoBytes => photos.values.fold(0, (total, p) => total + p.bytes);

  static String idFor(String date, String vehicleKey, InspectionKind kind) =>
      '${date}_${vehicleKey}_${kind.name}';

  /// Seconds between opening the checklist and finishing it on the phone.
  int? get durationSec => startedAt == null || completedAt == null
      ? null
      : completedAt!.difference(startedAt!).inSeconds;

  bool get hasDefects => defects.isNotEmpty;

  bool get isUnsafe => defects.any((d) => d.severity == DefectSeverity.unsafe);

  String get vehicleDisplay => [
        if (vehicleLabel.isNotEmpty) vehicleLabel else vehicleKey,
        if (plateNumber.isNotEmpty) plateNumber,
      ].join(' · ');

  factory VehicleInspection.fromFirestore(DocumentSnapshot doc) =>
      VehicleInspection.fromMap(
          doc.id, Map<String, dynamic>.from(doc.data() as Map? ?? const {}));

  factory VehicleInspection.fromMap(String id, Map<String, dynamic> m) {
    Map<String, dynamic> asMap(Object? v) =>
        v is Map ? Map<String, dynamic>.from(v) : <String, dynamic>{};
    final location = asMap(m['location']);
    final spot = asMap(m['spotCheck']);
    return VehicleInspection(
      id: id,
      date: (m['date'] as String?) ?? '',
      kind: InspectionKind.fromKey(m['kind'] as String?),
      vehicleKey: (m['vehicleKey'] as String?) ?? '',
      vehicleLabel: (m['vehicleLabel'] as String?) ?? '',
      plateNumber: (m['plateNumber'] as String?) ?? '',
      trailer: (m['trailer'] as String?) ?? '',
      driverId: (m['driverId'] as String?) ?? '',
      driverName: (m['driverName'] as String?) ?? '',
      distributorId: (m['distributorId'] as String?) ?? '',
      dropsheetTaskId: (m['dropsheetTaskId'] as String?) ?? '',
      checklistVersion: (m['checklistVersion'] as num?)?.toInt() ??
          kInspectionChecklistVersion,
      startedAt: _date(m['startedAt']),
      completedAt: _date(m['completedAt']),
      submittedAt: _date(m['submittedAt']),
      odometerKm: (m['odometerKm'] as num?)?.toInt(),
      fuelLevel: (m['fuelLevel'] as String?) ?? '',
      lat: (location['lat'] as num?)?.toDouble(),
      lng: (location['lng'] as num?)?.toDouble(),
      accuracyM: (location['accuracyM'] as num?)?.toDouble(),
      items: asMap(m['items'])
          .map((k, v) => MapEntry(k, InspectionItemResult.fromMap(asMap(v)))),
      photos: asMap(m['photos'])
          .map((k, v) => MapEntry(k, InspectionPhoto.fromMap(k, asMap(v)))),
      spotCheckPrompt: (spot['prompt'] as String?) ?? '',
      defects: (m['defects'] is List ? m['defects'] as List : const [])
          .whereType<Map>()
          .map((d) => InspectionDefect.fromMap(Map<String, dynamic>.from(d)))
          .toList(),
      result: (m['result'] as String?) ?? 'pass',
      review: InspectionReview.fromMap(
          m['review'] is Map ? asMap(m['review']) : null),
      appVersion: (m['appVersion'] as String?) ?? '',
      photosClearedAt: _date(m['photosClearedAt']),
      photosClearedBy: (m['photosClearedBy'] as String?) ?? '',
    );
  }
}

DateTime? _date(Object? v) {
  if (v is Timestamp) return v.toDate();
  if (v is String) return DateTime.tryParse(v);
  return null;
}

// ── Fleet vehicle ──────────────────────────────────────────────────────────

/// Fleet details for one dropsheet vehicle, at fleetVehicles/{key} where
/// key is the `VehicleType` enum name. Readable by clmgpx so the plate is
/// stamped onto inspection photos.
class FleetVehicle {
  final String key;
  final String name;
  final String plateNumber;
  final bool active;

  /// Licence disc expiry, a calendar date (stored as `yyyy-MM-dd`).
  final DateTime? licenceExpiry;

  /// When the licence disc was last renewed (stored as `yyyy-MM-dd`).
  final DateTime? licenceRenewedOn;

  /// Odometer reading the next service is due at.
  final int? nextServiceKm;

  const FleetVehicle({
    required this.key,
    required this.name,
    this.plateNumber = '',
    this.active = true,
    this.licenceExpiry,
    this.licenceRenewedOn,
    this.nextServiceKm,
  });

  factory FleetVehicle.fromMap(String key, Map<String, dynamic> m) =>
      FleetVehicle(
        key: key,
        name: (m['name'] as String?) ?? key,
        plateNumber: (m['plateNumber'] as String?) ?? '',
        active: m['active'] as bool? ?? true,
        licenceExpiry: _parseDay(m['licenceExpiry']),
        licenceRenewedOn: _parseDay(m['licenceRenewedOn']),
        nextServiceKm: (m['nextServiceKm'] as num?)?.toInt(),
      );

  Map<String, dynamic> toMap() => {
        'name': name,
        'plateNumber': plateNumber,
        'active': active,
        'licenceExpiry': _dayKey(licenceExpiry),
        'licenceRenewedOn': _dayKey(licenceRenewedOn),
        'nextServiceKm': nextServiceKm,
        'updatedAt': FieldValue.serverTimestamp(),
      };

  /// Days until the disc expires (negative once expired); null when unset.
  int? daysToLicenceExpiry(DateTime today) {
    final e = licenceExpiry;
    if (e == null) return null;
    return DateTime.utc(e.year, e.month, e.day)
        .difference(DateTime.utc(today.year, today.month, today.day))
        .inDays;
  }

  /// The disc is valid through its expiry date; due soon within
  /// [kLicenceWarnDays].
  FleetDue licenceDue(DateTime today) {
    final days = daysToLicenceExpiry(today);
    if (days == null) return FleetDue.unknown;
    if (days < 0) return FleetDue.overdue;
    return days <= kLicenceWarnDays ? FleetDue.soon : FleetDue.ok;
  }

  /// Km left before the next service (negative once past it); null when
  /// either reading is missing.
  int? kmToService(int? odometerKm) =>
      nextServiceKm == null || odometerKm == null
          ? null
          : nextServiceKm! - odometerKm;

  FleetDue serviceDue(int? odometerKm) {
    final left = kmToService(odometerKm);
    if (left == null) return FleetDue.unknown;
    if (left <= 0) return FleetDue.overdue;
    return left <= kServiceWarnKm ? FleetDue.soon : FleetDue.ok;
  }

  static DateTime? _parseDay(Object? v) {
    if (v is Timestamp) {
      final d = v.toDate();
      return DateTime(d.year, d.month, d.day);
    }
    if (v is! String || v.isEmpty) return null;
    final d = DateTime.tryParse(v);
    return d == null ? null : DateTime(d.year, d.month, d.day);
  }

  static String? _dayKey(DateTime? d) => d == null
      ? null
      : '${d.year.toString().padLeft(4, '0')}-'
          '${d.month.toString().padLeft(2, '0')}-'
          '${d.day.toString().padLeft(2, '0')}';
}

/// Where a licence disc or service stands.
enum FleetDue { unknown, ok, soon, overdue }

/// A licence disc counts as "due soon" this many days before it expires.
const int kLicenceWarnDays = 30;

/// A service counts as "due soon" this many km before it is due.
const int kServiceWarnKm = 1000;

// ── Review flags ───────────────────────────────────────────────────────────

/// Signs an inspection may not have been done properly. Computed in the
/// office from the record — never trusted from the phone.
enum InspectionFlag {
  tooFast,
  offSite,
  odometerBackwards,
  duplicatePhoto,
  missingPhotos;

  String get label => switch (this) {
        tooFast => 'Done too fast',
        offSite => 'Not at the depot',
        odometerBackwards => 'Odometer lower than last reading',
        duplicatePhoto => 'Photo reused from another inspection',
        missingPhotos => 'Photos missing',
      };
}

/// Under 3 minutes for ~17 photos means the checks were not really done.
const Duration kInspectionMinDuration = Duration(minutes: 3);

/// GPS further than this from the depot counts as off-site.
const double kInspectionDepotRadiusM = 500;
