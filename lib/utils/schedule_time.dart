/// Timezone anchoring for schedule / job-list / collection calendar dates.
///
/// The business operates in South African Standard Time (SAST = UTC+2, which
/// has no daylight saving). A schedule "date" is a *calendar day* in that zone,
/// not an instant in the reader's own timezone. Historically these dates were
/// serialized with the client's local time, so a client in another timezone
/// (e.g. Ireland at UTC+1) would resolve a job stored at SAST-midnight
/// (22:00Z the previous day) back to the *previous* calendar day — shifting the
/// whole grid by one day.
///
/// To fix this without migrating data, every calendar date crosses the
/// Firestore boundary through exactly two functions, both anchored to +2:
///
///   * [toScheduleCivil]      — stored instant  -> SAST calendar date
///   * [scheduleCivilToInstant] — SAST calendar date -> stored instant
///
/// Because the offset is a fixed constant, existing SAST-created records map to
/// the same calendar day they always did (no change for SAST users), while
/// clients in any other timezone now resolve the identical day. New writes
/// produce the identical on-disk instant regardless of the writer's timezone,
/// so old and new data stay consistent.
library;

/// The fixed business-timezone offset (SAST, UTC+2, no DST).
const Duration kScheduleZoneOffset = Duration(hours: 2);

/// Convert an absolute instant read from Firestore into a SAST *civil* date:
/// a plain [DateTime] whose `year`/`month`/`day`/`hour`… fields are the
/// SAST wall-clock values. Any time-of-day component is preserved (so
/// time-slotted jobs are not flattened to midnight).
DateTime toScheduleCivil(DateTime instant) {
  final u = instant.toUtc().add(kScheduleZoneOffset);
  // Rebuild as a local-flagged DateTime carrying the SAST field values, so the
  // rest of the app can compare/format it exactly like any other civil date.
  return DateTime(
    u.year,
    u.month,
    u.day,
    u.hour,
    u.minute,
    u.second,
    u.millisecond,
    u.microsecond,
  );
}

/// Convert a SAST *civil* date into the absolute instant to persist. The result
/// is timezone-independent: the same calendar day yields the same instant on
/// every machine, matching how SAST-created records were already stored.
DateTime scheduleCivilToInstant(DateTime civil) {
  return DateTime.utc(
    civil.year,
    civil.month,
    civil.day,
    civil.hour,
    civil.minute,
    civil.second,
    civil.millisecond,
    civil.microsecond,
  ).subtract(kScheduleZoneOffset);
}

/// Null-safe [toScheduleCivil]: reads a stored instant (e.g. a Firestore
/// `Timestamp.toDate()` result) as a SAST civil date, passing null through.
DateTime? scheduleCivilOrNull(DateTime? instant) =>
    instant == null ? null : toScheduleCivil(instant);

/// "Now" expressed as a SAST civil date (fields are SAST wall-clock).
DateTime scheduleNow() => toScheduleCivil(DateTime.now());

/// SAST "today" at midnight — the civil day the schedule should default to,
/// independent of the client's own timezone.
DateTime scheduleToday() {
  final n = scheduleNow();
  return DateTime(n.year, n.month, n.day);
}
