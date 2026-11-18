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

  /// typeData key listing the fields the user reworded in the editor —
  /// `job`, `details`, `location`, `contact`, `tel`, `address`,
  /// `loadingAddress`, `offloadAddress` — written beside [kUserEditedKey].
  /// Only those fields keep the user's text; the rest still follow the Job
  /// List job / schedule. Builds that predate the list keep the flag but drop
  /// the list when they rebuild a task, which reads as "every field".
  static const String kUserEditedFieldsKey = '_userEditedFields';

  /// Text fields the editor tracks in [kUserEditedFieldsKey].
  static const List<String> userEditableFields = [
    'job',
    'details',
    'location',
    'contact',
    'tel',
    'address',
    'loadingAddress',
    'offloadAddress',
  ];

  /// Whether the user reworded [field], so a sync keeps their text. A task
  /// flagged before fields were tracked one by one counts every field.
  bool userEditedField(String field) {
    if (!hasUserEdits) return false;
    final fields = typeData[kUserEditedFieldsKey];
    if (fields is! List) return true;
    return fields.contains(field);
  }

  /// typeData marking that the user reworded [touched], on top of whatever
  /// they reworded before. Null when nothing was touched (the task stays as
  /// it was — opening and closing the editor must not detach it from sync).
  static Map<String, dynamic>? markUserEdited(
      Map<String, dynamic> typeData, Set<String> touched,
      {required bool wasEdited}) {
    if (touched.isEmpty) return null;
    final out = Map<String, dynamic>.from(typeData);
    out[kUserEditedKey] = true;
    final before = typeData[kUserEditedFieldsKey];
    if (wasEdited && before is! List) {
      // Flagged by an older build: which fields were the user's is unknown,
      // so they all stay the user's.
      out.remove(kUserEditedFieldsKey);
      return out;
    }
    out[kUserEditedFieldsKey] = <String>{
      if (before is List) ...before.whereType<String>(),
      ...touched,
    }.toList()
      ..sort();
    return out;
  }

  /// typeData: who the schedule sends to this Junk & Stuff / Happy Sun job's
  /// client on the day — the names of the distributors whose schedule job
  /// lists the client. Written by the dropsheet's syncs; shown as
  /// "Team: …" in Details ([withLine]).
  static const String kWithKey = 'withNames';

  /// The distributors working this job with the driver ([kWithKey]).
  List<String> get withNames => [
        for (final n in (typeData[kWithKey] as List?) ?? const [])
          if (n is String && n.trim().isNotEmpty) n.trim(),
      ];

  /// "Team: Sipho, Thabo", or '' when nobody is allocated.
  String get withLine =>
      withNames.isEmpty ? '' : 'Team: ${withNames.join(', ')}';

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

  /// Work areas shown before the rest are cut to "...".
  static const int kMaxShownAreas = 3;

  /// [areas] (the comma-joined `workArea` text) cut to its first
  /// [kMaxShownAreas] names plus "..." — a job with many linked client-map
  /// areas otherwise fills the row and the printed sheet. Display only: the
  /// stored `workArea` stays whole, since the sync matches on it.
  static String shortAreaList(String areas) {
    final parts = areas
        .split(',')
        .map((a) => a.trim())
        .where((a) => a.isNotEmpty)
        .toList();
    if (parts.length <= kMaxShownAreas) return areas.trim();
    return '${parts.take(kMaxShownAreas).join(', ')} ...';
  }

  /// This task's `workArea`, shortened by [shortAreaList].
  String get shortWorkArea =>
      shortAreaList((typeData['workArea'] as String?) ?? '');

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
  static final RegExp _bookedAtPattern = RegExp(r'\s*@\s*\d{1,2}:\d{2}');

  /// [label] as an appointment reads: "Collection @10:00: Mrs Smith,
  /// 12 Main Rd" — booked time after the type, then client and address — so
  /// the driver sees when and where at a glance. Built for display, so it
  /// holds for labels the user reworded too; a stale "@time" is replaced
  /// and an address already in the label isn't repeated.
  static String withBookedTime(String label, String appointment,
      {String address = ''}) {
    final plain = label.replaceAll(_bookedAtPattern, '').trim();
    final colon = plain.indexOf(':');
    final head = (colon == -1 ? plain : plain.substring(0, colon)).trim();
    var tail = colon == -1 ? '' : plain.substring(colon + 1).trim();
    final where = address.trim();
    if (where.isNotEmpty &&
        !tail.toLowerCase().contains(where.toLowerCase())) {
      tail = tail.isEmpty ? where : '$tail, $where';
    }
    final at = '$head @${appointment.trim()}';
    return tail.isEmpty ? at : '$at: $tail';
  }

  /// Where an appointment happens, for its label: a move's loading address,
  /// else the job-list address, else the Location.
  String get _bookedAddress {
    String text(String key) => (typeData[key] as String?)?.trim() ?? '';
    if (type == DropsheetTaskType.furnitureMove) return text('loadingAddress');
    final address = text('address');
    return address.isNotEmpty ? address : location.trim();
  }

  String get displayJob {
    final label = _baseDisplayJob;
    final booked = appointmentTime;
    if (booked.isEmpty) return label;
    return withBookedTime(label, booked, address: _bookedAddress);
  }

  /// A two-address job (furniture move, transport of goods, trailer
  /// towing…). The dropsheet and PDF show it as two lines — "Furniture
  /// Move: Loading" then "Furniture Move: Offloading" — each with its own time and
  /// address, in the order the route does them.
  bool get isTwoStop => type == DropsheetTaskType.furnitureMove;

  /// The job type part of the label ("Transport of Goods" from
  /// "Transport of Goods: Mrs Smith"), for the two-stop lines.
  String get twoStopTypeLabel {
    final plain = job.replaceAll(_bookedAtPattern, '').trim();
    final colon = plain.indexOf(':');
    final head = (colon == -1 ? plain : plain.substring(0, colon)).trim();
    if (head.isNotEmpty) return head;
    final label = (typeData['jobTypeLabel'] as String?)?.trim() ?? '';
    return label.isNotEmpty ? label : type.displayName;
  }

  /// "Furniture Move @10:00: Loading" — a booked move starts with loading.
  String get loadingLineLabel {
    final booked = appointmentTime;
    return booked.isEmpty
        ? '$twoStopTypeLabel: Loading'
        : '$twoStopTypeLabel @$booked: Loading';
  }

  String get offloadingLineLabel => '$twoStopTypeLabel: Offloading';

  String get loadingAddress =>
      (typeData['loadingAddress'] as String?)?.trim() ?? '';

  String get offloadAddress =>
      (typeData['offloadAddress'] as String?)?.trim() ?? '';

  /// When the offloading starts — the route's offload arrival. The loading
  /// time is [startTime].
  String get offloadTime => (typeData['offloadEta'] as String?)?.trim() ?? '';

  /// The map pin numbers of the two lines, given the task's first stop
  /// number: the map numbers each address that has a point, loading first
  /// (see taskStopCount), so the Offloading line is usually [first] + 1.
  ({int? loading, int? offload}) twoStopNumbers(int? first) {
    if (first == null) return (loading: null, offload: null);
    final hasLoad =
        typeData['loadingLat'] != null && typeData['loadingLng'] != null;
    final hasOff =
        typeData['offloadLat'] != null && typeData['offloadLng'] != null;
    return (
      loading: hasLoad ? first : null,
      offload: hasOff ? first + (hasLoad ? 1 : 0) : null,
    );
  }

  String get _baseDisplayJob {
    if (job.isEmpty) return type.displayName;
    var label = job;
    if (type == DropsheetTaskType.distribute) {
      final prefix = RegExp(r'^drop[-\s]*off', caseSensitive: false);
      if (prefix.hasMatch(label)) {
        label = label.replaceFirst(prefix, 'Distribute');
      }
    }
    // "Drop off: A, B, C, D, E" → "Drop off: A, B, C ...".
    if (isDistributorTask) {
      final area = (typeData['workArea'] as String?)?.trim() ?? '';
      if (area.isNotEmpty && label.contains(area)) {
        label = label.replaceFirst(area, shortAreaList(area));
      }
    }
    return label;
  }

  /// The notes shown in Details. A furniture move built in the editor before
  /// its Notes box wrote [details] kept them only in `typeData['notes']`,
  /// where nothing showed them.
  String get _shownNotes {
    final n = notes.trim();
    if (n.isNotEmpty || type != DropsheetTaskType.furnitureMove) return n;
    return (typeData['notes'] as String?)?.trim() ?? '';
  }

  /// Text for the Details column (dropsheet rows + PDF). Drop-offs and
  /// pick-ups lead with the distributor's name — always the current one from
  /// `typeData`, never stored in [details] — followed by the user's notes.
  /// Junk & Stuff / Happy Sun jobs lead with who works them ("Team: Sipho,
  /// Thabo · notes").
  String get detailsText {
    if (type == DropsheetTaskType.arrive) {
      // Start shows the target (17:30 unless changed); the route's
      // calculated return goes here when it differs.
      final eta = (typeData['eta'] as String?)?.trim() ?? '';
      final back = eta.isNotEmpty && eta != startTime.trim()
          ? 'Back ~$eta'
          : '';
      final n = notes.trim();
      return [back, n].where((p) => p.isNotEmpty).join(' · ');
    }
    if (type != DropsheetTaskType.dropOff && type != DropsheetTaskType.pickUp) {
      return [withLine, _shownNotes].where((p) => p.isNotEmpty).join(' · ');
    }
    final name = (typeData['distributorName'] as String?)?.trim() ?? '';
    final n = notes.trim();
    if (name.isEmpty) return n;
    return n.isEmpty ? name : '$name · $n';
  }

  /// typeData: the booked appointment time ("10:00") of a time-slot job-list
  /// job (collections, window cleaning…). Kept apart from [startTime], which
  /// route calculation overwrites with the arrival estimate — the booking
  /// used to be lost the first time the route was calculated.
  static const String kAppointmentTimeKey = 'appointmentTime';

  /// The booked appointment time, or '' — shown in the label
  /// ([displayJob]: "Collection @10:00: Mrs Smith, 12 Main Rd").
  String get appointmentTime =>
      (typeData[kAppointmentTimeKey] as String?)?.trim() ?? '';

  /// typeData: minutes the driver waits at this stop for its booked time
  /// (route timing — see services/appointment_timing.dart).
  static const String kAppointmentWaitKey = 'apptWaitMin';

  /// typeData: minutes the driver reaches this stop after its booked time.
  static const String kAppointmentLateKey = 'apptLateMin';

  int get appointmentWaitMinutes =>
      (typeData[kAppointmentWaitKey] as num?)?.toInt() ?? 0;

  int get appointmentLateMinutes =>
      (typeData[kAppointmentLateKey] as num?)?.toInt() ?? 0;

  /// "18 min early for the 10:00 booking — wait" / "12 min late for the
  /// 10:00 booking", or null when on time or not booked. Same words on the
  /// dropsheet, planner panel, map card and PDF.
  String? get bookingTimingNote {
    final late = appointmentLateMinutes;
    if (late > 0) return '$late min late for the $appointmentTime booking';
    final early = appointmentWaitMinutes;
    if (early > 0) {
      return '$early min early for the $appointmentTime booking — wait';
    }
    return null;
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
