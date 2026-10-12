import '../models/distributor.dart';
import '../models/dropsheet_day.dart';
import '../models/payroll_daily_entry.dart';
import '../providers/dropsheet_provider.dart' show kUnassignedSectionId;

/// The bonus code paid to a distributor who drove a vehicle that day.
const String kDrivingCode = 'DR';

String _normalisedName(String name) =>
    name.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

/// Whether [day]'s dropsheet has [distributor] driving a vehicle.
///
/// Dropsheet drivers live in their own `/drivers` collection. New ones are
/// stored under the distributor's id; older ones have their own id, so a
/// section is also matched by name (case/spacing-insensitive).
bool drivesVehicleOn(DropsheetDay day, Distributor distributor) {
  final name = _normalisedName(distributor.name);
  for (final s in day.sections) {
    if (s.vehicle == null || s.driverId == kUnassignedSectionId) continue;
    if (s.driverId == distributor.id) return true;
    if (name.isNotEmpty && _normalisedName(s.driverName) == name) return true;
  }
  return false;
}

/// What a worked day's sets/code should start as: the driving code when the
/// dropsheet allocated them a vehicle (defaulting drivers to "1" set
/// underpays them), otherwise one set.
String defaultSetsOrCode({
  required bool drivingThatDay,
  required List<String> knownCodes,
}) =>
    drivingThatDay && knownCodes.contains(kDrivingCode) ? kDrivingCode : '1';

/// What [saved] should become so payroll matches the schedule, or null when
/// it already does. The schedule allocation decides whether someone worked
/// (a day off is the same as no allocation):
///  - no allocation → "didn't work", whatever was saved (notes kept);
///  - allocated but nothing saved → the default ([defaultSetsOrCode]),
///    flagged [PayrollDailyEntry.autoDefault];
///  - allocated with an automatic value that's now out of date (the
///    dropsheet driver changed) → the new default, other stats kept.
/// A sets/code the admin chose is never changed while they're allocated.
PayrollDailyEntry? reconcileWithSchedule({
  required DateTime date,
  required PayrollDailyEntry? saved,
  required bool allocated,
  required bool driving,
  required List<String> knownCodes,
}) {
  final worked = saved?.worked ?? false;
  if (!allocated) {
    return worked ? PayrollDailyEntry(date: date, notes: saved!.notes) : null;
  }

  final desired =
      defaultSetsOrCode(drivingThatDay: driving, knownCodes: knownCodes);
  final isCode = knownCodes.contains(desired);
  if (!worked) {
    return PayrollDailyEntry(
      date: date,
      worked: true,
      autoDefault: true,
      specialCode: isCode ? desired : null,
      flyerSets: isCode ? null : int.parse(desired),
      notes: saved?.notes ?? '',
    );
  }

  if (!saved!.autoDefault) return null;
  final current = saved.specialCode ?? saved.flyerSets?.toString() ?? '';
  if (current == desired) return null;
  return PayrollDailyEntry(
    date: date,
    worked: true,
    autoDefault: true,
    specialCode: isCode ? desired : null,
    flyerSets: isCode ? null : int.parse(desired),
    kmWalked: saved.kmWalked,
    waypointsReached: saved.waypointsReached,
    estimateReached: saved.estimateReached,
    auditScore: saved.auditScore,
    notes: saved.notes,
  );
}
