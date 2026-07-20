/// Shared types for transactional schedule mutations.
///
/// Every schedule write funnels through
/// `FirestoreService._runScheduleMutation`, which reads the affected day
/// documents inside a Firestore transaction, hands their state to a pure
/// mutator via [ScheduleTxContext], then writes the day docs plus audit-log
/// docs atomically.
library;

/// Thrown when a mutation targets a job that no longer exists in its day
/// document (e.g. it was deleted or moved by another user). Aborts the
/// transaction so the provider can roll back its optimistic state.
class JobNotFoundException implements Exception {
  final String jobId;
  final String? dateKey;

  JobNotFoundException(this.jobId, [this.dateKey]);

  @override
  String toString() =>
      'JobNotFoundException: job $jobId not found${dateKey != null ? ' on $dateKey' : ''}';
}

/// Thrown when a schedule mutation would violate a structural invariant of
/// the schedule (e.g. the same job id would end up in two different day
/// documents). Aborts the transaction so nothing is written — the guard
/// exists to guarantee "no duplication, no data loss" across every schedule
/// method rather than silently persisting a corrupt state.
class ScheduleIntegrityException implements Exception {
  final String message;

  ScheduleIntegrityException(this.message);

  @override
  String toString() => 'ScheduleIntegrityException: $message';
}

/// Thrown when a schedule mutation is attempted with no signed-in user.
/// Every schedule change must be attributable in the audit log, so
/// unauthenticated writes are rejected before the transaction starts.
class ScheduleAuthRequiredException implements Exception {
  @override
  String toString() =>
      'ScheduleAuthRequiredException: you must be signed in to modify the schedule';
}

/// Identity attached to every audit-log entry.
class ScheduleLogUser {
  final String? uid;
  final String? email;
  final String? name;

  const ScheduleLogUser({this.uid, this.email, this.name});
}

/// Per-transaction working state handed to a mutator.
///
/// Mutators edit [jobsByDateKey] (and optionally [dayFieldUpdates]) in place.
/// The context is rebuilt from fresh transaction reads on every retry, so
/// mutators must be pure functions of it — no side effects outside the maps.
class ScheduleTxContext {
  /// dateKey ('yyyy-MM-dd') -> mutable jobs array for that day.
  final Map<String, List<Map<String, dynamic>>> jobsByDateKey;

  /// dateKey -> full pre-mutation day-doc data (null when the doc is absent).
  /// Deep-copied; safe to read, never mutate.
  final Map<String, Map<String, dynamic>?> beforeByDateKey;

  /// dateKey -> day-level field changes outside the jobs array
  /// (e.g. confirmationStatus). A null value removes the key from the doc.
  final Map<String, Map<String, dynamic>> dayFieldUpdates = {};

  final String Function(DateTime) _dateKeyFor;

  ScheduleTxContext({
    required this.jobsByDateKey,
    required this.beforeByDateKey,
    required String Function(DateTime) dateKeyFor,
  }) : _dateKeyFor = dateKeyFor;

  String dateKeyFor(DateTime date) => _dateKeyFor(date);
}

/// Recursively copies maps and lists; leaves scalar/Firestore leaf values
/// (String, num, Timestamp, GeoPoint, ...) shared, which is safe because
/// they are immutable.
Map<String, dynamic> deepCopyMap(Map map) {
  return map.map((key, value) => MapEntry(key.toString(), _deepCopyValue(value)));
}

dynamic _deepCopyValue(dynamic value) {
  if (value is Map) return deepCopyMap(value);
  if (value is List) return value.map(_deepCopyValue).toList();
  return value;
}

/// Structural equality over nested maps/lists with `==` at the leaves
/// (covers Timestamp/GeoPoint, which implement value equality).
bool deepEquals(dynamic a, dynamic b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !deepEquals(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!deepEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
