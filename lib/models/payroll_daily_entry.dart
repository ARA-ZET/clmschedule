/// One day's raw production stats for one distributor, keyed by
/// `dayKeyFor(date)` inside `PayrollPayslip.dailyEntries`.
///
/// Either [specialCode] is set (a flat-bonus day: driving, scooter, etc.)
/// or a normal distribution day's numbers are filled in ([flyerSets] etc.) —
/// never both. [worked] distinguishes an explicit day-off from a day that
/// simply hasn't been filled in yet.
class PayrollDailyEntry {
  final DateTime date;
  final bool worked;
  final String? specialCode;
  final int? flyerSets;
  final double? kmWalked;
  final int? waypointsReached;
  final bool estimateReached;
  final int? auditScore;
  final String notes;

  /// True when the sets/code was filled in automatically (1 for a scheduled
  /// day, DR for a dropsheet driver) and saved without the admin changing
  /// it — so it can be re-derived if the schedule or dropsheet changes,
  /// unlike a value the admin chose.
  final bool autoDefault;

  const PayrollDailyEntry({
    required this.date,
    this.worked = false,
    this.specialCode,
    this.flyerSets,
    this.kmWalked,
    this.waypointsReached,
    this.estimateReached = false,
    this.auditScore,
    this.notes = '',
    this.autoDefault = false,
  });

  factory PayrollDailyEntry.empty(DateTime date) =>
      PayrollDailyEntry(date: date);

  factory PayrollDailyEntry.fromMap(DateTime date, Map<String, dynamic> data) {
    return PayrollDailyEntry(
      date: date,
      worked: data['worked'] as bool? ?? false,
      specialCode: data['specialCode'] as String?,
      flyerSets: (data['flyerSets'] as num?)?.toInt(),
      kmWalked: (data['kmWalked'] as num?)?.toDouble(),
      waypointsReached: (data['waypointsReached'] as num?)?.toInt(),
      estimateReached: data['estimateReached'] as bool? ?? false,
      auditScore: (data['auditScore'] as num?)?.toInt(),
      notes: data['notes'] as String? ?? '',
      autoDefault: data['autoDefault'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() => {
        'worked': worked,
        'specialCode': specialCode,
        'flyerSets': flyerSets,
        'kmWalked': kmWalked,
        'waypointsReached': waypointsReached,
        'estimateReached': estimateReached,
        'auditScore': auditScore,
        'notes': notes,
        if (autoDefault) 'autoDefault': true,
      };

  PayrollDailyEntry copyWith({
    bool? worked,
    String? specialCode,
    bool clearSpecialCode = false,
    int? flyerSets,
    bool clearFlyerSets = false,
    double? kmWalked,
    bool clearKmWalked = false,
    int? waypointsReached,
    bool clearWaypointsReached = false,
    bool? estimateReached,
    int? auditScore,
    bool clearAuditScore = false,
    String? notes,
    // Not carried over: a copy is an edit, so no longer the untouched
    // automatic value.
    bool autoDefault = false,
  }) {
    return PayrollDailyEntry(
      date: date,
      worked: worked ?? this.worked,
      specialCode:
          clearSpecialCode ? null : (specialCode ?? this.specialCode),
      flyerSets: clearFlyerSets ? null : (flyerSets ?? this.flyerSets),
      kmWalked: clearKmWalked ? null : (kmWalked ?? this.kmWalked),
      waypointsReached: clearWaypointsReached
          ? null
          : (waypointsReached ?? this.waypointsReached),
      estimateReached: estimateReached ?? this.estimateReached,
      auditScore: clearAuditScore ? null : (auditScore ?? this.auditScore),
      notes: notes ?? this.notes,
      autoDefault: autoDefault,
    );
  }
}
