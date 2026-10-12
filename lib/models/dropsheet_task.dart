import 'job.dart';

/// Types of tasks that can appear on a driver's dropsheet.
///
/// Each type drives both UI (which fields the editor shows) and behaviour
/// (where the location/Maps link comes from).
enum DropsheetTaskType {
  /// Mandatory: inspect the vehicle. Details auto-fills with the section
  /// vehicle on creation, then becomes free-text.
  inspect,

  /// Mandatory: free-text packing notes.
  pack,

  /// Mandatory: leave time. Free-text details.
  leave,

  /// Mandatory: arrive back at the office at the end of the day.
  /// Pinned at the bottom of every driver section. Uses the configured
  /// depot/office address (see [DepotConfig]) for its Maps link.
  arrive,

  /// Drop off flyers/material at a distributor's work area.
  /// One task = one distributor. Pulls from `/schedule/daily/{date}` and
  /// uses the distributor's `Job.dropOffPoint` for the Maps link.
  dropOff,

  /// Same as drop off (re-uses the distributor drop-off point).
  pickUp,

  /// The driver distributes a schedule job's work area themselves — used
  /// when the job's distributor has the Driver role, since a driver cannot
  /// be dropped off. Same typeData / drop-off point as [dropOff], but never
  /// gets a pick-up.
  distribute,

  /// Pick up product/material from a client. Picks a JobListItem dated
  /// for the dropsheet day and uses its `collectionAddress` (URL-encoded
  /// with `, Western Cape, South Africa`) for the Maps link.
  collection,

  /// Furniture move: separate loading + offload addresses.
  furnitureMove,

  /// Return items to a client. Picks a JobListItem and uses its address.
  jobReturn,

  /// Collect flyers from a client. Picks a JobListItem and uses its address.
  pickFlyers,

  /// Anything else — totally free-form (existing behaviour).
  custom;

  String get storageKey => name;

  String get displayName {
    switch (this) {
      case DropsheetTaskType.inspect:
        return 'Inspect';
      case DropsheetTaskType.pack:
        return 'Pack';
      case DropsheetTaskType.leave:
        return 'Leave';
      case DropsheetTaskType.arrive:
        return 'Arrive';
      case DropsheetTaskType.dropOff:
        return 'Drop off';
      case DropsheetTaskType.pickUp:
        return 'Pick up';
      case DropsheetTaskType.distribute:
        return 'Distribute';
      case DropsheetTaskType.collection:
        return 'Collection';
      case DropsheetTaskType.furnitureMove:
        return 'Furniture move';
      case DropsheetTaskType.jobReturn:
        return 'Return';
      case DropsheetTaskType.pickFlyers:
        return 'Pick flyers';
      case DropsheetTaskType.custom:
        return 'Custom';
    }
  }

  static DropsheetTaskType fromKey(String? key) {
    if (key == null) return DropsheetTaskType.custom;
    for (final t in DropsheetTaskType.values) {
      if (t.storageKey == key) return t;
    }
    return DropsheetTaskType.custom;
  }
}

/// A single task row on a driver's dropsheet for a given day.
///
/// The flat fields (job/details/startTime/location/contact/tel) are kept
/// for backwards compatibility and free-form `custom` tasks. Typed tasks
/// derive their location/links from [typeData] — see
/// `lib/utils/dropsheet_maps.dart` for helpers that read [typeData].
class DropsheetTask {
  final String id;
  final DropsheetTaskType type;
  final String job;
  final String details;
  final String startTime; // "HH:mm"
  final String location;
  final String contact;
  final String tel;

  /// True for the 3 mandatory leading tasks (Inspect / Pack / Leave).
  /// Mandatory tasks cannot be deleted. They are always pinned to the top
  /// of each driver section in Inspect / Pack / Leave order.
  final bool isMandatory;

  /// Type-specific structured data. Schema varies by [type]:
  /// - inspect:        `{ vehicle: 'hyundai' }`
  /// - pack / leave:   `{}`
  /// - dropOff/pickUp: `{ distributorJobId, distributorName, workArea, lat?, lng? }`
  /// - collection:     `{ jobListItemId, client, address, jobType? }`
  /// - furnitureMove:  `{ loadingAddress, offloadAddress, notes }`
  final Map<String, dynamic> typeData;

  /// Optional link back to a JobListItem.id when auto-populated.
  final String? sourceJobListItemId;

  /// Per-task override for the minutes spent at this stop (used by route
  /// optimisation). When null, the type-level default from
  /// `DropsheetTaskTypeConfig` / `DynamicTaskTypeDef` is used.
  final int? serviceTimeMinutes;

  const DropsheetTask({
    required this.id,
    this.type = DropsheetTaskType.custom,
    this.job = '',
    this.details = '',
    this.startTime = '',
    this.location = '',
    this.contact = '',
    this.tel = '',
    this.isMandatory = false,
    this.typeData = const {},
    this.sourceJobListItemId,
    this.serviceTimeMinutes,
  });

  factory DropsheetTask.fromMap(Map<String, dynamic> data) {
    // Migration: old documents have no `type`. Infer from the id suffix
    // for legacy mandatory tasks (`_m1`/`_m2`/`_m3`); otherwise `custom`.
    DropsheetTaskType inferredType;
    final raw = data['type'] as String?;
    if (raw != null) {
      inferredType = DropsheetTaskType.fromKey(raw);
    } else {
      final id = data['id'] as String? ?? '';
      if (id.endsWith('_m1')) {
        inferredType = DropsheetTaskType.inspect;
      } else if (id.endsWith('_m2')) {
        inferredType = DropsheetTaskType.pack;
      } else if (id.endsWith('_m3')) {
        inferredType = DropsheetTaskType.leave;
      } else if (id.endsWith('_m4')) {
        inferredType = DropsheetTaskType.arrive;
      } else {
        inferredType = DropsheetTaskType.custom;
      }
    }

    // Parse typeData early so isLeadingType can check the pickup-divider
    // marker — that leave task is intentionally non-mandatory.
    var typeData = (data['typeData'] == null
            ? null
            : Map<String, dynamic>.from(data['typeData'] as Map)) ??
        const <String, dynamic>{};

    // Distribute is stored as a flagged dropOff (see [toMap]).
    if (typeData.containsKey(kDistributeKey)) {
      if (inferredType == DropsheetTaskType.dropOff &&
          typeData[kDistributeKey] == true) {
        inferredType = DropsheetTaskType.distribute;
      }
      typeData = Map<String, dynamic>.from(typeData)..remove(kDistributeKey);
    }
    // Repair: builds without the distribute type read it as `custom` and
    // saved it back that way, still linked to its schedule job. Restore it so
    // the schedule sync recognises (and de-duplicates) it again. Hand-built
    // custom tasks never carry a distributorJobId unless they belong to a
    // user-defined type, which has a dynamicTypeId.
    if (inferredType == DropsheetTaskType.custom &&
        (typeData['distributorJobId'] as String?)?.isNotEmpty == true &&
        typeData['dynamicTypeId'] == null) {
      final label = (data['job'] as String? ?? '').trimLeft().toLowerCase();
      inferredType = label.startsWith('distribute')
          ? DropsheetTaskType.distribute
          : DropsheetTaskType.dropOff;
    }

    final isLeadingType = inferredType == DropsheetTaskType.inspect ||
        inferredType == DropsheetTaskType.pack ||
        // Leave tasks that are the pickup-divider separator are NOT mandatory.
        (inferredType == DropsheetTaskType.leave &&
            typeData['isPickupDivider'] != true) ||
        inferredType == DropsheetTaskType.arrive;

    return DropsheetTask(
      id: data['id'] as String,
      type: inferredType,
      job: data['job'] as String? ?? '',
      details: data['details'] as String? ?? '',
      startTime: data['startTime'] as String? ?? '',
      location: data['location'] as String? ?? '',
      contact: data['contact'] as String? ?? '',
      tel: data['tel'] as String? ?? '',
      isMandatory: (data['isMandatory'] as bool?) == true || isLeadingType,
      typeData: typeData,
      sourceJobListItemId: data['sourceJobListItemId'] as String?,
      serviceTimeMinutes: (data['serviceTimeMinutes'] as num?)?.toInt(),
    );
  }

  /// typeData flag that marks a stored `dropOff` as a Distribute task.
  ///
  /// Distribute is persisted as `type: dropOff` + this flag rather than
  /// `type: distribute` so builds that predate it still see a drop-off linked
  /// to the schedule job. A bare `distribute` type made those builds read it
  /// as `custom`, consider the job unhandled, and add another row on every
  /// sync — the task multiplied while old and new clients were both open.
  static const String kDistributeKey = '_distribute';

  Map<String, dynamic> toMap() {
    final isDistribute = type == DropsheetTaskType.distribute;
    final storedTypeData =
        isDistribute ? {...typeData, kDistributeKey: true} : typeData;
    return {
      'id': id,
      'type':
          isDistribute ? DropsheetTaskType.dropOff.storageKey : type.storageKey,
      'job': job,
      'details': details,
      'startTime': startTime,
      'location': location,
      'contact': contact,
      'tel': tel,
      'isMandatory': isMandatory,
      if (storedTypeData.isNotEmpty) 'typeData': storedTypeData,
      if (sourceJobListItemId != null)
        'sourceJobListItemId': sourceJobListItemId,
      if (serviceTimeMinutes != null) 'serviceTimeMinutes': serviceTimeMinutes,
    };
  }

  DropsheetTask copyWith({
    DropsheetTaskType? type,
    String? job,
    String? details,
    String? startTime,
    String? location,
    String? contact,
    String? tel,
    bool? isMandatory,
    Map<String, dynamic>? typeData,
    String? sourceJobListItemId,
    int? serviceTimeMinutes,
    bool clearServiceTimeMinutes = false,
  }) =>
      DropsheetTask(
        id: id,
        type: type ?? this.type,
        job: job ?? this.job,
        details: details ?? this.details,
        startTime: startTime ?? this.startTime,
        location: location ?? this.location,
        contact: contact ?? this.contact,
        tel: tel ?? this.tel,
        isMandatory: isMandatory ?? this.isMandatory,
        typeData: typeData ?? this.typeData,
        sourceJobListItemId: sourceJobListItemId ?? this.sourceJobListItemId,
        serviceTimeMinutes: clearServiceTimeMinutes
            ? null
            : (serviceTimeMinutes ?? this.serviceTimeMinutes),
      );

  // ── Job-list ownership ──────────────────────────────────────────────────
  //
  // A task carrying a [sourceJobListItemId] is either GENERATED by the
  // dropsheet's job-list sync or HAND-BUILT in the task editor. The sync
  // treats the two very differently, so the distinction is recorded in
  // typeData under these reserved keys:
  //
  //   _jlFp       — fingerprint of the source item. Written ONLY by
  //                 `DropsheetProvider._buildJobListTask`, so its presence
  //                 identifies a sync-generated task (including ones created
  //                 before this ownership model existed).
  //   _jlManual   — written by the editor when the user links a job-list item
  //                 to a task they built themselves. Survives later refreshes,
  //                 so a hand-built task stays hand-built.
  //   _userEdited — written by the editor when the user rewords a synced task.

  /// typeData key holding the source item's fingerprint (sync-generated).
  static const String kJobListFingerprintKey = '_jlFp';

  /// typeData key marking a task the user built and linked by hand.
  static const String kJobListManualKey = '_jlManual';

  /// typeData key marking a synced task whose text the user has reworded.
  static const String kUserEditedKey = '_userEdited';

  /// True when this task was hand-built in the editor rather than generated
  /// by the job-list sync.
  ///
  /// Only meaningful for tasks with a [sourceJobListItemId]. Such tasks are
  /// never auto-deleted: the sync only ever sees the job-list items for one
  /// date whose type appears on the dropsheet, so "missing from that list"
  /// does not mean "deleted from the job list" — it usually just means the
  /// user linked something the sync does not manage.
  bool get isUserCreatedJobListTask =>
      typeData[kJobListManualKey] == true ||
      !typeData.containsKey(kJobListFingerprintKey);

  /// True when the user has reworded this job-list-sourced task, so a
  /// re-sync must keep their text instead of regenerating it.
  bool get hasUserEdits => typeData[kUserEditedKey] == true;

  bool get isDistributorTask =>
      type == DropsheetTaskType.dropOff ||
      type == DropsheetTaskType.pickUp ||
      type == DropsheetTaskType.distribute;

  /// True when [details] is text the schedule sync / editor used to auto-fill
  /// on distributor tasks (the distributor name, or the work area) rather than
  /// a note the user typed. Those copies made every drop-off show the
  /// distributor name twice (Details + Contact) and are treated as empty.
  bool get hasAutoFilledDetails {
    if (!isDistributorTask) return false;
    final d = details.trim();
    if (d.isEmpty) return false;
    final name = (typeData['distributorName'] as String?)?.trim() ?? '';
    final area = (typeData['workArea'] as String?)?.trim() ?? '';
    return d == name ||
        d == area ||
        d == contact.trim() ||
        isPlaceholderArea(d);
  }

  /// The user's notes for this task — [details] minus any legacy auto-fill.
  String get notes => hasAutoFilledDetails ? '' : details;

  /// typeData: true when the task's schedule job is a bare drop-off point with
  /// no work-area polygons (own or linked from a client map). Only these get
  /// a street-corner name — a polygon already shows where to work.
  static const String kPointOnlyKey = 'pointOnly';

  /// The schedule's "not named yet" working-area text.
  static bool isPlaceholderArea(String area) =>
      area.trim().toLowerCase() == 'to be assigned';

  /// Whether a [Job] has no work-area polygons, i.e. it is "just a point".
  /// Point markers (a tapped or searched drop-off / address point) don't
  /// count — only real polygons do.
  static bool isPointOnlyJob(Job job) =>
      job.areaLinks.isEmpty && !job.workMaps.any((w) => w.isPolygon);

  /// True for distributor tasks whose job is just a point (see
  /// [kPointOnlyKey]) — the ones that get a street-corner Location.
  bool get wantsIntersection =>
      isDistributorTask && typeData[kPointOnlyKey] == true;

  /// typeData: the two streets crossing nearest the task's point
  /// ("Voortrekker Rd & Durban Rd"), from OpenStreetMap. '' = none nearby.
  static const String kIntersectionKey = 'intersection';

  /// typeData: the `lat,lng` (4 dp) [kIntersectionKey] was resolved for. The
  /// name only counts while it still matches the task's point, so moving a
  /// drop-off point re-resolves it instead of printing the old corner.
  static const String kIntersectionAtKey = 'intersectionAt';

  /// `lat,lng` key of this task's point, or null without coordinates.
  /// Same format as `tePlaceKey` in the track editor's place-name resolver.
  String? get pointKey {
    final lat = (typeData['lat'] as num?)?.toDouble();
    final lng = (typeData['lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return null;
    return '${lat.toStringAsFixed(4)},${lng.toStringAsFixed(4)}';
  }

  /// True when [intersection] has been looked up for the current point
  /// (even if no named streets were found there).
  bool get hasCurrentIntersection =>
      pointKey != null && typeData[kIntersectionAtKey] == pointKey;

  /// Nearest street intersection for the current point, or '' when unknown.
  String get intersection => wantsIntersection && hasCurrentIntersection
      ? (typeData[kIntersectionKey] as String? ?? '').trim()
      : '';

  /// Label shown for the task. A Distribute task relabelled "Drop off: …" by
  /// an older build is shown as "Distribute: …".
  String get displayJob {
    if (job.isEmpty) return type.displayName;
    if (type == DropsheetTaskType.distribute) {
      final prefix = RegExp(r'^drop[-\s]*off', caseSensitive: false);
      if (prefix.hasMatch(job)) return job.replaceFirst(prefix, 'Distribute');
    }
    return job;
  }

  /// Text for the Details column (dropsheet rows + PDF). Drop-offs and
  /// pick-ups lead with the distributor's name — always the current one from
  /// `typeData`, never stored in [details] — followed by the user's notes.
  String get detailsText {
    if (type != DropsheetTaskType.dropOff && type != DropsheetTaskType.pickUp) {
      return notes;
    }
    final name = (typeData['distributorName'] as String?)?.trim() ?? '';
    final n = notes.trim();
    if (name.isEmpty) return n;
    return n.isEmpty ? name : '$name · $n';
  }

  /// Details text for the Inspect task: the vehicle, plus the trailer when
  /// the driver is taking one — they must inspect both.
  static String inspectDetails({String? vehicleLabel, String? trailerLabel}) =>
      [
        if (vehicleLabel != null && vehicleLabel.isNotEmpty) vehicleLabel,
        if (trailerLabel != null && trailerLabel.isNotEmpty) trailerLabel,
      ].join(' + ');

  /// typeData for the Inspect task recording what has to be inspected.
  static Map<String, dynamic> inspectTypeData({
    String? vehicleKey,
    String? trailerKey,
  }) =>
      {
        if (vehicleKey != null && vehicleKey.isNotEmpty) 'vehicle': vehicleKey,
        if (trailerKey != null && trailerKey.isNotEmpty) 'trailer': trailerKey,
      };

  /// The 3 mandatory templates that lead every driver's dropsheet.
  ///
  /// [vehicleLabel] / [vehicleKey] and [trailerLabel] / [trailerKey] — if
  /// provided, auto-fill the Inspect task's `details` (e.g.
  /// `Hyundai + Big Trailer`) and store the raw names in
  /// `typeData['vehicle']` / `typeData['trailer']`. Per spec, this is set
  /// once on creation and stays editable thereafter (i.e. we do NOT keep it
  /// bound after) — but see `DropsheetDriverSection.withVehicleTrailer`,
  /// which refreshes rows the user has not reworded.
  static List<DropsheetTask> mandatoryTemplate({
    required String idPrefix,
    String? vehicleLabel,
    String? vehicleKey,
    String? trailerLabel,
    String? trailerKey,
    // Office/depot details — when supplied, both Leave and Arrive tasks are
    // pre-filled with the office address so drivers always see where they're
    // departing from and returning to.
    String? depotAddress,
    double? depotLat,
    double? depotLng,
    String? depotStartTime,
    // Per-type defaults from DropsheetTaskTypeConfig (Task Manager settings).
    String? packDetails,
  }) {
    final depotTypeData = <String, dynamic>{
      if (depotLat != null) 'lat': depotLat,
      if (depotLng != null) 'lng': depotLng,
    };
    return [
      DropsheetTask(
        id: '${idPrefix}_m1',
        type: DropsheetTaskType.inspect,
        job: 'Inspect',
        details: inspectDetails(
          vehicleLabel: vehicleLabel,
          trailerLabel: trailerLabel,
        ),
        startTime: '07:00',
        isMandatory: true,
        typeData: inspectTypeData(
          vehicleKey: vehicleKey,
          trailerKey: trailerKey,
        ),
      ),
      DropsheetTask(
        id: '${idPrefix}_m2',
        type: DropsheetTaskType.pack,
        job: 'Pack',
        details: packDetails ?? '',
        startTime: '07:15',
        isMandatory: true,
      ),
      DropsheetTask(
        id: '${idPrefix}_m3',
        type: DropsheetTaskType.leave,
        job: 'Leave',
        startTime: depotStartTime ?? '07:30',
        location: depotAddress ?? '',
        isMandatory: true,
        typeData: depotTypeData,
      ),
      DropsheetTask(
        id: '${idPrefix}_m4',
        type: DropsheetTaskType.arrive,
        job: 'Arrive',
        // Default target arrival time at the office. Afternoon pick-up ETAs
        // are computed backwards from this value (see DropsheetRoutePlanner).
        startTime: '17:30',
        location: depotAddress ?? '',
        isMandatory: true,
        typeData: depotTypeData,
      ),
    ];
  }

  /// Returns true if [task] is the trailing mandatory "Arrive at office"
  /// task. Used by reorder / add-task logic to keep it pinned to the
  /// bottom of every driver section.
  static bool isTrailing(DropsheetTask task) =>
      task.type == DropsheetTaskType.arrive;
}
