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

  /// Drop off flyers/material at a distributor's work area.
  /// One task = one distributor. Pulls from `/schedule/daily/{date}` and
  /// uses the distributor's `Job.dropOffPoint` for the Maps link.
  dropOff,

  /// Same as drop off (re-uses the distributor drop-off point).
  pickUp,

  /// Pick up product/material from a client. Picks a JobListItem dated
  /// for the dropsheet day and uses its `collectionAddress` (URL-encoded
  /// with `, Western Cape, South Africa`) for the Maps link.
  collection,

  /// Furniture move: separate loading + offload addresses.
  furnitureMove,

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
      case DropsheetTaskType.dropOff:
        return 'Drop off';
      case DropsheetTaskType.pickUp:
        return 'Pick up';
      case DropsheetTaskType.collection:
        return 'Collection';
      case DropsheetTaskType.furnitureMove:
        return 'Furniture move';
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
  /// Mandatory tasks cannot be deleted but every field is editable
  /// and they may still be reordered (per requirements).
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
      } else {
        inferredType = DropsheetTaskType.custom;
      }
    }

    return DropsheetTask(
      id: data['id'] as String,
      type: inferredType,
      job: data['job'] as String? ?? '',
      details: data['details'] as String? ?? '',
      startTime: data['startTime'] as String? ?? '',
      location: data['location'] as String? ?? '',
      contact: data['contact'] as String? ?? '',
      tel: data['tel'] as String? ?? '',
      isMandatory: data['isMandatory'] as bool? ?? false,
      typeData: (data['typeData'] as Map<String, dynamic>?) ?? const {},
      sourceJobListItemId: data['sourceJobListItemId'] as String?,
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'type': type.storageKey,
        'job': job,
        'details': details,
        'startTime': startTime,
        'location': location,
        'contact': contact,
        'tel': tel,
        'isMandatory': isMandatory,
        if (typeData.isNotEmpty) 'typeData': typeData,
        if (sourceJobListItemId != null)
          'sourceJobListItemId': sourceJobListItemId,
      };

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
      );

  /// The 3 mandatory templates that lead every driver's dropsheet.
  ///
  /// [vehicleLabel] / [vehicleKey] — if provided, auto-fill the Inspect
  /// task's `details` and store the raw vehicle name in
  /// `typeData['vehicle']`. Per spec, this is set once on creation and
  /// stays editable thereafter (i.e. we do NOT keep it bound after).
  static List<DropsheetTask> mandatoryTemplate({
    required String idPrefix,
    String? vehicleLabel,
    String? vehicleKey,
  }) =>
      [
        DropsheetTask(
          id: '${idPrefix}_m1',
          type: DropsheetTaskType.inspect,
          job: 'Inspect',
          details: vehicleLabel ?? '',
          startTime: '07:00',
          isMandatory: true,
          typeData:
              vehicleKey != null ? {'vehicle': vehicleKey} : const {},
        ),
        DropsheetTask(
          id: '${idPrefix}_m2',
          type: DropsheetTaskType.pack,
          job: 'Pack',
          details: 'Raincoats; bank card',
          startTime: '07:15',
          isMandatory: true,
        ),
        DropsheetTask(
          id: '${idPrefix}_m3',
          type: DropsheetTaskType.leave,
          job: 'Leave',
          startTime: '07:30',
          isMandatory: true,
        ),
      ];
}
