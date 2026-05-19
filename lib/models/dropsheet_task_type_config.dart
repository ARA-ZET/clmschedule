import 'dropsheet_task.dart';

/// Which section a user-defined (dynamic) task type belongs to.
/// This determines what kind of data-entry fields appear when the task is
/// added / edited on a dropsheet.
enum DynamicTaskSection {
  /// Office-related task — free-form fields only (like inspect / pack / leave).
  mandatory,

  /// Distributor task — the user picks a distributor from the daily schedule.
  distributor,

  /// Job-list task — the user picks a job from the job list.
  additional,

  /// Fully free-form — all fields typed manually (default / legacy behaviour).
  custom;

  String get storageKey => name;

  String get displayName {
    switch (this) {
      case DynamicTaskSection.mandatory:
        return 'Mandatory';
      case DynamicTaskSection.distributor:
        return 'Distributor';
      case DynamicTaskSection.additional:
        return 'Additional';
      case DynamicTaskSection.custom:
        return 'Custom';
    }
  }

  String get description {
    switch (this) {
      case DynamicTaskSection.mandatory:
        return 'Office activity — free-text fields, no job/distributor link';
      case DynamicTaskSection.distributor:
        return 'Pick a distributor from the daily schedule';
      case DynamicTaskSection.additional:
        return 'Pick a job from the job list (filter by job type below)';
      case DynamicTaskSection.custom:
        return 'Fully free-form — all fields entered manually';
    }
  }

  static DynamicTaskSection fromKey(String? key) {
    if (key == null) return DynamicTaskSection.custom;
    for (final s in DynamicTaskSection.values) {
      if (s.storageKey == key) return s;
    }
    return DynamicTaskSection.custom;
  }
}

/// Which data field is shown as the primary or secondary label on the
/// map marker bitmap for a given task type.
enum MarkerLabelField {
  /// Show nothing in this slot.
  none,

  /// The task's `job` text field (the title/label of the task).
  taskLabel,

  /// The task's `details` / notes field.
  details,

  /// The contact name field.
  contact,

  /// The telephone field.
  tel,

  /// The task's `startTime` field (HH:mm).
  startTime,

  /// The task's `location` field.
  location,

  /// `typeData['distributorName']` — only meaningful for distributor tasks.
  distributorName,

  /// `typeData['workArea']` — only meaningful for distributor tasks.
  workArea,

  /// `typeData['client']` — only meaningful for job-list tasks.
  client,

  /// `typeData['address']` — only meaningful for job-list tasks.
  address,

  /// `typeData['jobTypeLabel']` — job type label from the job list.
  jobTypeLabel;

  String get storageKey => name;

  String get displayName {
    switch (this) {
      case MarkerLabelField.none:
        return 'None';
      case MarkerLabelField.taskLabel:
        return 'Label';
      case MarkerLabelField.details:
        return 'Notes';
      case MarkerLabelField.contact:
        return 'Contact';
      case MarkerLabelField.tel:
        return 'Tel';
      case MarkerLabelField.startTime:
        return 'Start time';
      case MarkerLabelField.location:
        return 'Location';
      case MarkerLabelField.distributorName:
        return 'Distributor';
      case MarkerLabelField.workArea:
        return 'Work area';
      case MarkerLabelField.client:
        return 'Client';
      case MarkerLabelField.address:
        return 'Collection address';
      case MarkerLabelField.jobTypeLabel:
        return 'Job type';
    }
  }

  static MarkerLabelField fromKey(String? key) {
    if (key == null) return MarkerLabelField.none;
    for (final f in MarkerLabelField.values) {
      if (f.storageKey == key) return f;
    }
    return MarkerLabelField.none;
  }
}

/// Returns the sensible default marker label fields for a built-in task type.
({MarkerLabelField primary, MarkerLabelField secondary})
    defaultMarkerFieldsFor(DropsheetTaskType type) {
  switch (type) {
    case DropsheetTaskType.dropOff:
    case DropsheetTaskType.pickUp:
      return (
        primary: MarkerLabelField.distributorName,
        secondary: MarkerLabelField.workArea,
      );
    case DropsheetTaskType.collection:
    case DropsheetTaskType.jobReturn:
    case DropsheetTaskType.pickFlyers:
      return (
        primary: MarkerLabelField.client,
        secondary: MarkerLabelField.address,
      );
    case DropsheetTaskType.furnitureMove:
      return (
        primary: MarkerLabelField.client,
        secondary: MarkerLabelField.none,
      );
    default:
      return (
        primary: MarkerLabelField.taskLabel,
        secondary: MarkerLabelField.none,
      );
  }
}

/// Global depot / start-of-day configuration. Stored at
/// `dropsheetSettings/taskTypeConfig` under the `depot` key so route
/// optimisation knows where every driver leaves from and at what time.
class DepotConfig {
  final String address;
  final double? lat;
  final double? lng;
  final String startTime; // "HH:mm"

  const DepotConfig({
    this.address = '27 7th Ave, Kensington, Cape Town',
    this.lat,
    this.lng,
    this.startTime = '07:30',
  });

  bool get hasCoordinates => lat != null && lng != null;

  DepotConfig copyWith({
    String? address,
    double? lat,
    double? lng,
    String? startTime,
    bool clearCoordinates = false,
  }) =>
      DepotConfig(
        address: address ?? this.address,
        lat: clearCoordinates ? null : (lat ?? this.lat),
        lng: clearCoordinates ? null : (lng ?? this.lng),
        startTime: startTime ?? this.startTime,
      );

  Map<String, dynamic> toMap() => {
        'address': address,
        if (lat != null) 'lat': lat,
        if (lng != null) 'lng': lng,
        'startTime': startTime,
      };

  factory DepotConfig.fromMap(Map<String, dynamic> data) => DepotConfig(
        address:
            (data['address'] as String?) ?? '27 7th Ave, Kensington, Cape Town',
        lat: (data['lat'] as num?)?.toDouble(),
        lng: (data['lng'] as num?)?.toDouble(),
        startTime: (data['startTime'] as String?) ?? '07:30',
      );
}

/// A user-defined task type created in the Task Manager.
/// Stored as `customTypes` in `dropsheetSettings/taskTypeConfig`.
/// These tasks are created with [DropsheetTaskType.custom] and carry
/// a `dynamicTypeId` field in their `typeData`.
class DynamicTaskTypeDef {
  final String id;
  final String label;
  final List<String> allowedJobTypeIds;

  /// Default minutes spent at the stop (used by route optimisation).
  /// 0 means “no default — do not add any service time”.
  final int serviceTimeMinutes;

  /// Which section this task type belongs to. Controls which fields appear
  /// in the editor (distributor picker, job-list picker, or free-form).
  final DynamicTaskSection section;

  const DynamicTaskTypeDef({
    required this.id,
    required this.label,
    this.allowedJobTypeIds = const [],
    this.serviceTimeMinutes = 0,
    this.section = DynamicTaskSection.custom,
    this.markerPrimaryField = MarkerLabelField.taskLabel,
    this.markerSecondaryField = MarkerLabelField.none,
  });

  DynamicTaskTypeDef copyWith({
    String? label,
    List<String>? allowedJobTypeIds,
    int? serviceTimeMinutes,
    DynamicTaskSection? section,
    MarkerLabelField? markerPrimaryField,
    MarkerLabelField? markerSecondaryField,
  }) =>
      DynamicTaskTypeDef(
        id: id,
        label: label ?? this.label,
        allowedJobTypeIds: allowedJobTypeIds ?? this.allowedJobTypeIds,
        serviceTimeMinutes: serviceTimeMinutes ?? this.serviceTimeMinutes,
        section: section ?? this.section,
        markerPrimaryField: markerPrimaryField ?? this.markerPrimaryField,
        markerSecondaryField: markerSecondaryField ?? this.markerSecondaryField,
      );

  /// Which task field to show as the large title on the map marker bitmap.
  final MarkerLabelField markerPrimaryField;

  /// Which task field to show as the small subtitle on the map marker bitmap.
  final MarkerLabelField markerSecondaryField;

  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'allowedJobTypeIds': allowedJobTypeIds,
        'serviceTimeMinutes': serviceTimeMinutes,
        'section': section.storageKey,
        'markerPrimaryField': markerPrimaryField.storageKey,
        'markerSecondaryField': markerSecondaryField.storageKey,
      };

  factory DynamicTaskTypeDef.fromMap(Map<String, dynamic> data) =>
      DynamicTaskTypeDef(
        id: data['id'] as String,
        label: data['label'] as String? ?? '',
        allowedJobTypeIds: (data['allowedJobTypeIds'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
        serviceTimeMinutes: (data['serviceTimeMinutes'] as num?)?.toInt() ?? 0,
        section: DynamicTaskSection.fromKey(data['section'] as String?),
        markerPrimaryField:
            MarkerLabelField.fromKey(data['markerPrimaryField'] as String?),
        markerSecondaryField:
            MarkerLabelField.fromKey(data['markerSecondaryField'] as String?),
      );
}

/// Result returned by [DropsheetTaskTypePicker].
/// Either a built-in enum type or a user-defined dynamic type.
class TaskTypeSelection {
  final DropsheetTaskType type;

  /// Non-null when this is a user-defined (dynamic) task type.
  final DynamicTaskTypeDef? dynamicType;

  const TaskTypeSelection.enumType(this.type) : dynamicType = null;
  const TaskTypeSelection.dynamic(DropsheetTaskType baseType, this.dynamicType)
      : type = baseType;

  bool get isDynamic => dynamicType != null;
  String get effectiveLabel => dynamicType?.label ?? type.displayName;
}

/// Configuration for a single [DropsheetTaskType] that is stored in
/// Firestore and edited via the Task Manager dialog.
class DropsheetTaskTypeConfig {
  final DropsheetTaskType type;

  /// User-defined label. Empty = fall back to [type.displayName].
  final String customLabel;

  /// Job-type IDs from the Job List that are suggested when the user picks
  /// a job for this task. Empty list = use the built-in keyword fallback.
  final List<String> allowedJobTypeIds;

  /// Default minutes spent at the stop (used by route optimisation).
  /// 0 means “no default — do not add any service time”.
  final int serviceTimeMinutes;

  /// Which task field to show as the large title on the map marker bitmap.
  final MarkerLabelField markerPrimaryField;

  /// Which task field to show as the small subtitle on the map marker bitmap.
  final MarkerLabelField markerSecondaryField;

  DropsheetTaskTypeConfig({
    required this.type,
    this.customLabel = '',
    this.allowedJobTypeIds = const [],
    this.serviceTimeMinutes = 0,
    MarkerLabelField? markerPrimaryField,
    MarkerLabelField? markerSecondaryField,
  })  : markerPrimaryField =
            markerPrimaryField ?? defaultMarkerFieldsFor(type).primary,
        markerSecondaryField =
            markerSecondaryField ?? defaultMarkerFieldsFor(type).secondary;

  String get effectiveLabel =>
      customLabel.trim().isNotEmpty ? customLabel.trim() : type.displayName;

  DropsheetTaskTypeConfig copyWith({
    String? customLabel,
    List<String>? allowedJobTypeIds,
    int? serviceTimeMinutes,
    MarkerLabelField? markerPrimaryField,
    MarkerLabelField? markerSecondaryField,
  }) =>
      DropsheetTaskTypeConfig(
        type: type,
        customLabel: customLabel ?? this.customLabel,
        allowedJobTypeIds: allowedJobTypeIds ?? this.allowedJobTypeIds,
        serviceTimeMinutes: serviceTimeMinutes ?? this.serviceTimeMinutes,
        markerPrimaryField: markerPrimaryField ?? this.markerPrimaryField,
        markerSecondaryField: markerSecondaryField ?? this.markerSecondaryField,
      );

  Map<String, dynamic> toMap() => {
        'customLabel': customLabel,
        'allowedJobTypeIds': allowedJobTypeIds,
        'serviceTimeMinutes': serviceTimeMinutes,
        'markerPrimaryField': markerPrimaryField.storageKey,
        'markerSecondaryField': markerSecondaryField.storageKey,
      };

  factory DropsheetTaskTypeConfig.fromMap(
      DropsheetTaskType type, Map<String, dynamic> data) {
    return DropsheetTaskTypeConfig(
      type: type,
      customLabel: data['customLabel'] as String? ?? '',
      allowedJobTypeIds: (data['allowedJobTypeIds'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList() ??
          [],
      serviceTimeMinutes: (data['serviceTimeMinutes'] as num?)?.toInt() ?? 0,
      markerPrimaryField:
          MarkerLabelField.fromKey(data['markerPrimaryField'] as String?),
      markerSecondaryField:
          MarkerLabelField.fromKey(data['markerSecondaryField'] as String?),
    );
  }
}
