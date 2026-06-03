/// Configurable job type. All per-type behaviour (form fields, schedule
/// participation, sync targets) is driven by flags on this model so new
/// services can be added entirely from Settings without an app update.
class CustomJobType {
  final String id;
  final String label;
  final bool isDefault;
  final int order;

  // ─── Behaviour flags ─────────────────────────────────────────────────
  /// When true, this job type shows the tools-selection panel in the
  /// add/edit dialog and is synced to Happy Sun Firestore collections.
  final bool isHappySunService;

  /// When true, add/edit dialog and inline cells require a time (HH:mm)
  /// alongside the date; date comparisons include the time component.
  final bool needsTimeSlot;

  /// When true, the job requires a vehicle + trailer and appears on the
  /// Collection Schedule grid (filtered from the Job List).
  final bool appearsOnCollectionSchedule;

  /// When true, the add/edit dialog exposes the quantity-distributed field
  /// and inventory integration is active. When false those UI elements hide.
  final bool tracksQuantity;

  /// Label rendered above the quantity field (e.g. "Flyers distributed",
  /// "30-min time slots"). Only the display text differs — the stored
  /// numeric value still lives in `quantityDistributed`.
  final String quantityLabel;

  /// When true, the `onJobListItemWritten` Cloud Function automatically
  /// creates a Cloud Storage folder for each new job-list item of this
  /// type, and keeps the folder renamed/moved when the client name or
  /// distribution date changes. Used for distribution services (flyers,
  /// magazines, calendars, etc.) where uploaded GPX tracks are filed by
  /// `Distribution/{year}/{MMM yyyy}/{client}`.
  final bool createsCloudFolder;

  // ─── Visual identity ─────────────────────────────────────────────────
  /// Optional Material icon name (e.g. `local_shipping`). Null → generic.
  final String? iconName;

  /// Optional ARGB colour as an int (matches `Color.value`).
  final int? colorValue;

  /// When true, job-list items of this type are automatically mirrored as
  /// tasks in the Dropsheet for the same date (today / next planning day
  /// window). The dropsheet task type is given by [dropsheetTaskTypeKey].
  final bool appearsOnDropsheet;

  /// The [DropsheetTaskType.storageKey] used when auto-creating a Dropsheet
  /// task from a job-list item of this type. Null → `custom`.
  final String? dropsheetTaskTypeKey;

  // ─── Future extensibility ────────────────────────────────────────────
  /// Optional default tools pre-selected when this Happy Sun service is
  /// created. Used only when `isHappySunService` is true.
  final List<String> defaultTools;

  const CustomJobType({
    required this.id,
    required this.label,
    this.isDefault = false,
    this.order = 0,
    this.isHappySunService = false,
    this.needsTimeSlot = false,
    this.appearsOnCollectionSchedule = false,
    this.tracksQuantity = true,
    this.quantityLabel = 'Quantity',
    this.createsCloudFolder = false,
    this.iconName,
    this.colorValue,
    this.appearsOnDropsheet = false,
    this.dropsheetTaskTypeKey,
    this.defaultTools = const [],
  });

  factory CustomJobType.fromMap(Map<String, dynamic> data) {
    return CustomJobType(
      id: data['id'] as String,
      label: data['label'] as String,
      isDefault: data['isDefault'] as bool? ?? false,
      order: (data['order'] as num?)?.toInt() ?? 0,
      isHappySunService: data['isHappySunService'] as bool? ?? false,
      needsTimeSlot: data['needsTimeSlot'] as bool? ?? false,
      appearsOnCollectionSchedule:
          data['appearsOnCollectionSchedule'] as bool? ?? false,
      tracksQuantity: data['tracksQuantity'] as bool? ?? true,
      quantityLabel: data['quantityLabel'] as String? ?? 'Quantity',
      createsCloudFolder: data['createsCloudFolder'] as bool? ?? false,
      iconName: data['iconName'] as String?,
      colorValue: (data['colorValue'] as num?)?.toInt(),
      appearsOnDropsheet: data['appearsOnDropsheet'] as bool? ?? false,
      dropsheetTaskTypeKey: data['dropsheetTaskTypeKey'] as String?,
      defaultTools:
          (data['defaultTools'] as List?)?.map((e) => e.toString()).toList() ??
              const [],
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'label': label,
      'isDefault': isDefault,
      'order': order,
      'isHappySunService': isHappySunService,
      'needsTimeSlot': needsTimeSlot,
      'appearsOnCollectionSchedule': appearsOnCollectionSchedule,
      'tracksQuantity': tracksQuantity,
      'quantityLabel': quantityLabel,
      'createsCloudFolder': createsCloudFolder,
      'iconName': iconName,
      'colorValue': colorValue,
      'appearsOnDropsheet': appearsOnDropsheet,
      if (dropsheetTaskTypeKey != null) 'dropsheetTaskTypeKey': dropsheetTaskTypeKey,
      'defaultTools': defaultTools,
    };
  }

  CustomJobType copyWith({
    String? id,
    String? label,
    bool? isDefault,
    int? order,
    bool? isHappySunService,
    bool? needsTimeSlot,
    bool? appearsOnCollectionSchedule,
    bool? tracksQuantity,
    String? quantityLabel,
    bool? createsCloudFolder,
    String? iconName,
    int? colorValue,
    List<String>? defaultTools,
    bool? appearsOnDropsheet,
    String? dropsheetTaskTypeKey,
    bool clearDropsheetTaskTypeKey = false,
    bool clearIcon = false,
    bool clearColor = false,
  }) {
    return CustomJobType(
      id: id ?? this.id,
      label: label ?? this.label,
      isDefault: isDefault ?? this.isDefault,
      order: order ?? this.order,
      isHappySunService: isHappySunService ?? this.isHappySunService,
      needsTimeSlot: needsTimeSlot ?? this.needsTimeSlot,
      appearsOnCollectionSchedule:
          appearsOnCollectionSchedule ?? this.appearsOnCollectionSchedule,
      tracksQuantity: tracksQuantity ?? this.tracksQuantity,
      quantityLabel: quantityLabel ?? this.quantityLabel,
      createsCloudFolder: createsCloudFolder ?? this.createsCloudFolder,
      iconName: clearIcon ? null : (iconName ?? this.iconName),
      colorValue: clearColor ? null : (colorValue ?? this.colorValue),
      appearsOnDropsheet: appearsOnDropsheet ?? this.appearsOnDropsheet,
      dropsheetTaskTypeKey: clearDropsheetTaskTypeKey
          ? null
          : (dropsheetTaskTypeKey ?? this.dropsheetTaskTypeKey),
      defaultTools: defaultTools ?? this.defaultTools,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CustomJobType &&
        other.id == id &&
        other.label == label &&
        other.isDefault == isDefault &&
        other.order == order &&
        other.isHappySunService == isHappySunService &&
        other.needsTimeSlot == needsTimeSlot &&
        other.appearsOnCollectionSchedule == appearsOnCollectionSchedule &&
        other.tracksQuantity == tracksQuantity &&
        other.quantityLabel == quantityLabel &&
        other.createsCloudFolder == createsCloudFolder &&
        other.iconName == iconName &&
        other.colorValue == colorValue;
  }

  @override
  int get hashCode => Object.hash(
        id,
        label,
        isDefault,
        order,
        isHappySunService,
        needsTimeSlot,
        appearsOnCollectionSchedule,
        tracksQuantity,
        quantityLabel,
        createsCloudFolder,
        iconName,
        colorValue,
      );

  @override
  String toString() =>
      'CustomJobType(id: $id, label: $label, flags: [happySun=$isHappySunService, time=$needsTimeSlot, collection=$appearsOnCollectionSchedule, qty=$tracksQuantity])';

  /// Default job types, seeded with sensible flag defaults for the 11
  /// legacy services. New user-created types inherit the constructor
  /// defaults (no behaviour flags, tracksQuantity=true, label "Quantity").
  static List<CustomJobType> getDefaults() {
    return const [
      CustomJobType(
        id: 'flyersPrintingOnly',
        label: 'Flyers - Printing only',
        isDefault: true,
        order: 0,
        quantityLabel: 'Flyers printed',
      ),
      CustomJobType(
        id: 'junkCollection',
        label: 'Junk Collection',
        isDefault: true,
        order: 1,
        needsTimeSlot: true,
        appearsOnCollectionSchedule: true,
        appearsOnDropsheet: true,
        dropsheetTaskTypeKey: 'collection',
        quantityLabel: '30-min time slots',
      ),
      CustomJobType(
        id: 'flyersAndPosters',
        label: 'Flyers and Posters',
        isDefault: true,
        order: 2,
        quantityLabel: 'Flyers & posters',
      ),
      CustomJobType(
        id: 'furnitureMove',
        label: 'Furniture Move',
        isDefault: true,
        order: 3,
        needsTimeSlot: true,
        appearsOnCollectionSchedule: true,
        appearsOnDropsheet: true,
        dropsheetTaskTypeKey: 'furnitureMove',
        quantityLabel: '30-min time slots',
      ),
      CustomJobType(
        id: 'flyerDistribution',
        label: 'Flyer Distribution',
        isDefault: true,
        order: 4,
        quantityLabel: 'Flyers distributed',
      ),
      CustomJobType(
        id: 'flyerPrintingAndDistribution',
        label: 'Flyer Printing and Distribution',
        isDefault: true,
        order: 5,
        quantityLabel: 'Flyers distributed',
      ),
      CustomJobType(
        id: 'windowCleaning',
        label: 'Window Cleaning',
        isDefault: true,
        order: 6,
        isHappySunService: true,
        needsTimeSlot: true,
        tracksQuantity: false,
      ),
      CustomJobType(
        id: 'solarPanelCleaning',
        label: 'Solar Panel Cleaning',
        isDefault: true,
        order: 7,
        isHappySunService: true,
        needsTimeSlot: true,
        tracksQuantity: false,
      ),
      CustomJobType(
        id: 'calendersDistribution',
        label: 'Calenders Distribution',
        isDefault: true,
        order: 8,
        quantityLabel: 'Calenders distributed',
      ),
      CustomJobType(
        id: 'trailerTowing',
        label: 'Trailer Towing',
        isDefault: true,
        order: 9,
        needsTimeSlot: true,
        appearsOnCollectionSchedule: true,
        appearsOnDropsheet: true,
        quantityLabel: '30-min time slots',
      ),
      CustomJobType(
        id: 'postering',
        label: 'Postering',
        isDefault: true,
        order: 10,
        quantityLabel: 'Posters',
      ),
    ];
  }
}
