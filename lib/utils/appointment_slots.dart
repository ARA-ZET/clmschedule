/// Appointment time slots: the Collection Schedule's half-hour rows.
///
/// A booking is a start time ("10:00") and a length in half-hour slots, as a
/// Job List job stores them (`JobListItem.timeSlot` / `timeSlots`). Junk &
/// Stuff bookings show on the Collection Schedule from these; Happy Sun ones
/// keep them on the job.
library;

/// Length of one slot, in minutes.
const int kSlotMinutes = 30;

/// First bookable start, 07:30.
const int kFirstSlotStartMinutes = 7 * 60 + 30;

/// Last bookable start, 20:00 — so a booking runs to 20:30 at the latest.
const int kLastSlotStartMinutes = 20 * 60;

/// "10:00" → 600; null when blank or malformed.
int? slotMinutes(String? hhmm) {
  final parts = (hhmm ?? '').trim().split(':');
  if (parts.length != 2) return null;
  final h = int.tryParse(parts[0]);
  final m = int.tryParse(parts[1]);
  if (h == null || m == null || h < 0 || h > 23 || m < 0 || m > 59) {
    return null;
  }
  return h * 60 + m;
}

/// 600 → "10:00".
String slotTime(int minutes) =>
    '${(minutes ~/ 60).toString().padLeft(2, '0')}:'
    '${(minutes % 60).toString().padLeft(2, '0')}';

/// The bookable start times, 07:30 to 20:00 — the Collection Schedule's rows.
List<String> appointmentStartTimes() => [
      for (var m = kFirstSlotStartMinutes;
          m <= kLastSlotStartMinutes;
          m += kSlotMinutes)
        slotTime(m),
    ];

/// When a booking of [slots] half-hours from [start] ends ("11:30"); null
/// when [start] is not a time.
String? slotEnd(String start, int slots) {
  final s = slotMinutes(start);
  if (s == null) return null;
  return slotTime(s + slots * kSlotMinutes);
}

/// "10:00–11:30"; just [start] when it is not a time.
String slotRange(String start, int slots) {
  final end = slotEnd(start, slots);
  return end == null ? start : '$start–$end';
}

/// "30 min", "1 h", "1 h 30".
String slotLength(int slots) {
  final minutes = slots * kSlotMinutes;
  final h = minutes ~/ 60;
  final m = minutes % 60;
  if (h == 0) return '$m min';
  return m == 0 ? '$h h' : '$h h $m';
}

/// The lengths, in slots, a booking from [start] can have: up to the end of
/// the last row (20:30), and always at least one.
List<int> slotLengthOptions(String start) {
  final s = slotMinutes(start) ?? kFirstSlotStartMinutes;
  final most = (kLastSlotStartMinutes + kSlotMinutes - s) ~/ kSlotMinutes;
  return [for (var n = 1; n <= (most < 1 ? 1 : most); n++) n];
}

/// Whether two bookings share any time. Unreadable starts never overlap.
bool slotsOverlap(String aStart, int aSlots, String bStart, int bSlots) {
  final a = slotMinutes(aStart);
  final b = slotMinutes(bStart);
  if (a == null || b == null) return false;
  final aEnd = a + (aSlots < 1 ? 1 : aSlots) * kSlotMinutes;
  final bEnd = b + (bSlots < 1 ? 1 : bSlots) * kSlotMinutes;
  return a < bEnd && b < aEnd;
}
