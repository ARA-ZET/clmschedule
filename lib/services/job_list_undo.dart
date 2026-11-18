// services/job_list_undo.dart
//
// Undo / Redo for Job List edits (UndoKey.jobList). Only edits are steps —
// adding a job also allocates it on the schedule, links maps and syncs Happy
// Sun, and invoice actions change Zoho/Xero, so neither is undoable.
//
// A step remembers just the fields the user changed. Undo checks those
// fields still hold what the edit left (otherwise someone changed the job
// since, and the step is skipped) and copies back only those fields, so
// anything else changed meanwhile — an invoice linked, a status set by a
// colleague — is kept.
//
// When the edit cascaded onto the Schedule (a date shift, a client rename
// the user confirmed), the step records exactly what was done there and
// undo reverses that too, without asking again.
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/job.dart';
import '../models/job_list_item.dart';
import '../providers/job_list_provider.dart';
import '../providers/schedule_provider.dart';
import '../undo/undo_history.dart';
import 'schedule_mutation_types.dart' show deepEquals;

typedef _Copy = JobListItem Function(JobListItem target, JobListItem source);

/// The fields an undo may put back, by their `toMap` key. Links the system
/// owns (folder, map, collection job, regular client) and every invoice /
/// accounting field are deliberately absent.
final Map<String, (String, _Copy)> _fields = {
  'invoice': ('invoice', (t, s) => t.copyWith(invoice: s.invoice)),
  'amount': ('amount', (t, s) => t.copyWith(amount: s.amount)),
  'amountExclVat': (
    'amount',
    (t, s) => t.copyWith(amountExclVat: s.amountExclVat)
  ),
  'amountInclVat': (
    'amount',
    (t, s) => t.copyWith(amountInclVat: s.amountInclVat)
  ),
  'priceIsInclVat': (
    'amount',
    (t, s) => t.copyWith(priceIsInclVat: s.priceIsInclVat)
  ),
  'client': ('client', (t, s) => t.copyWith(client: s.client)),
  'contactPerson': (
    'contact person',
    (t, s) => t.copyWith(contactPerson: s.contactPerson)
  ),
  'contactPhone': (
    'contact phone',
    (t, s) => t.copyWith(contactPhone: s.contactPhone)
  ),
  'jobStatusId': ('status', (t, s) => t.copyWith(jobStatusId: s.jobStatusId)),
  'invoiceStatusId': (
    'invoice status',
    (t, s) => t.copyWith(invoiceStatusId: s.invoiceStatusId)
  ),
  'jobType': ('job type', (t, s) => t.copyWith(jobTypeId: s.jobTypeId)),
  'area': ('area', (t, s) => t.copyWith(area: s.area)),
  'quantity': ('quantity', (t, s) => t.copyWith(quantity: s.quantity)),
  'manDays': ('man-days', (t, s) => t.copyWith(manDays: s.manDays)),
  'date': ('date', (t, s) => t.copyWith(date: s.date)),
  'collectionAddress': (
    'collection address',
    (t, s) => t.copyWith(collectionAddress: s.collectionAddress)
  ),
  'collectionDate': (
    'collection date',
    (t, s) => t.copyWith(collectionDate: s.collectionDate)
  ),
  'needsFlyerCollection': (
    'flyer collection',
    (t, s) => t.copyWith(needsFlyerCollection: s.needsFlyerCollection)
  ),
  'specialInstructions': (
    'instructions',
    (t, s) => t.copyWith(specialInstructions: s.specialInstructions)
  ),
  'quantityDistributed': (
    'quantity distributed',
    (t, s) => t.copyWith(quantityDistributed: s.quantityDistributed)
  ),
  'invoiceDetails': (
    'invoice details',
    (t, s) => t.copyWith(invoiceDetails: s.invoiceDetails)
  ),
  'reportAddresses': (
    'report addresses',
    (t, s) => t.copyWith(reportAddresses: s.reportAddresses)
  ),
  'whoToInvoice': (
    'who to invoice',
    (t, s) => t.copyWith(whoToInvoice: s.whoToInvoice)
  ),
  'reminders': ('reminders', (t, s) => t.copyWith(reminders: s.reminders)),
  'vehicleTrailerCombo': (
    'vehicle',
    (t, s) => t.copyWith(vehicleTrailerCombo: s.vehicleTrailerCombo)
  ),
  'offloadingAddress': (
    'offloading address',
    (t, s) => t.copyWith(offloadingAddress: s.offloadingAddress)
  ),
  'toolsNeeded': ('tools', (t, s) => t.copyWith(toolsNeeded: s.toolsNeeded)),
  'timeSlot': ('time slot', (t, s) => t.copyWith(timeSlot: s.timeSlot)),
  'timeSlots': ('time slots', (t, s) => t.copyWith(timeSlots: s.timeSlots)),
  'assignedStaff': (
    'staff',
    (t, s) => t.copyWith(assignedStaff: s.assignedStaff)
  ),
  'staffCount': ('staff', (t, s) => t.copyWith(staffCount: s.staffCount)),
  'customPolygons': (
    'areas',
    (t, s) => t.copyWith(customPolygons: s.customPolygons)
  ),
};

/// The undoable fields that differ between [a] and [b].
List<String> changedJobListFields(JobListItem a, JobListItem b) {
  final ma = a.toMap();
  final mb = b.toMap();
  return [
    for (final key in _fields.keys)
      if (!deepEquals(ma[key], mb[key])) key,
  ];
}

/// [target] with [keys] copied from [source].
JobListItem copyJobListFields(
    JobListItem target, JobListItem source, Iterable<String> keys) {
  var next = target;
  for (final key in keys) {
    next = _fields[key]!.$2(next, source);
  }
  return next;
}

/// Whether [item] holds [source]'s values for every one of [keys].
bool jobListFieldsMatch(
    JobListItem item, JobListItem source, Iterable<String> keys) {
  final mi = item.toMap();
  final ms = source.toMap();
  return keys.every((k) => deepEquals(mi[k], ms[k]));
}

/// "Smith: change date", "Smith: change status, amount".
String describeJobListEdit(JobListItem item, List<String> keys) {
  final who = item.client.trim().isEmpty ? 'Job' : item.client.trim();
  final names = {for (final k in keys) _fields[k]!.$1}.toList();
  if (names.length > 2) return '$who: edit ${names.length} fields';
  return '$who: change ${names.join(', ')}';
}

/// What a Job List edit did on the Schedule.
abstract class ScheduleCascade {
  Future<void> undo(ScheduleProvider schedule);
  Future<void> redo(ScheduleProvider schedule);
}

/// The date shift moved [removed] off the schedule and put [added] on.
class ScheduleShiftCascade implements ScheduleCascade {
  final List<Job> removed;
  final List<Job> added;
  ScheduleShiftCascade(this.removed, this.added);

  @override
  Future<void> undo(ScheduleProvider schedule) => schedule.swapScheduleJobs(
      expected: added, replacement: removed, action: 'undoJobListDateShift');

  @override
  Future<void> redo(ScheduleProvider schedule) => schedule.swapScheduleJobs(
      expected: removed, replacement: added, action: 'redoJobListDateShift');
}

/// The client was renamed from [from] to [to] on [jobs].
class ScheduleRenameCascade implements ScheduleCascade {
  final List<Job> jobs;
  final String from;
  final String to;
  ScheduleRenameCascade(this.jobs, this.from, this.to);

  @override
  Future<void> undo(ScheduleProvider schedule) =>
      schedule.renameClientOnJobs(jobs, from: to, to: from);

  @override
  Future<void> redo(ScheduleProvider schedule) =>
      schedule.renameClientOnJobs(jobs, from: from, to: to);
}

class JobListUndoStep {
  final String itemId;
  final JobListItem before;
  final JobListItem after;
  final List<String> keys;

  /// Added once the user has answered the cascade prompt.
  final List<ScheduleCascade> cascades = [];

  JobListUndoStep(this.itemId, this.before, this.after, this.keys);
}

/// Label resolvers the tracked-change history needs, captured with the step.
class JobListLabelResolvers {
  final String? Function(String statusId)? jobStatus;
  final String? Function(String statusId)? invoiceStatus;
  final String? Function(int quantity, String jobTypeId)? quantity;
  const JobListLabelResolvers(
      {this.jobStatus, this.invoiceStatus, this.quantity});
}

final jobListUndoRiverpod =
    riverpod.Provider<JobListUndo>((ref) => JobListUndo(ref));

class JobListUndo {
  final riverpod.Ref _ref;
  JobListUndo(this._ref);

  ScreenUndoHistory get _history =>
      _ref.read(undoHistoryRiverpod(UndoKey.jobList));

  /// Saves the edit (as `updateJobListItemWithTracking`) and records it as a
  /// Job List undo step. Returns the step so the caller can attach what the
  /// edit then does on the Schedule; null when nothing undoable changed.
  Future<JobListUndoStep?> edit(
    JobListItem original,
    JobListItem updated, {
    JobListLabelResolvers labels = const JobListLabelResolvers(),
  }) async {
    await _save(original, updated, labels);
    final keys = changedJobListFields(original, updated);
    if (keys.isEmpty || _history.isApplying) return null;
    final step = JobListUndoStep(original.id, original, updated, keys);
    _history.record(UndoEntry(
      label: describeJobListEdit(updated, keys),
      undo: () => _apply(step, labels, toBefore: true),
      redo: () => _apply(step, labels, toBefore: false),
    ));
    return step;
  }

  Future<void> _save(
      JobListItem original, JobListItem updated, JobListLabelResolvers l) {
    return _ref.read(jobListRiverpod).updateJobListItemWithTracking(
          original,
          updated,
          resolveJobStatusLabel: l.jobStatus,
          resolveInvoiceStatusLabel: l.invoiceStatus,
          resolveQuantityLabel: l.quantity,
        );
  }

  Future<void> _apply(JobListUndoStep step, JobListLabelResolvers labels,
      {required bool toBefore}) async {
    final expected = toBefore ? step.after : step.before;
    final target = toBefore ? step.before : step.after;
    final current = _ref.read(jobListRiverpod).getJobListItemById(step.itemId);
    if (current == null) throw const UndoConflict('the job was deleted');
    if (!jobListFieldsMatch(current, expected, step.keys)) {
      throw const UndoConflict('the job was changed since');
    }
    // Schedule first: it is the part that can refuse (a scheduled job changed
    // since), and refusing must leave the Job List item untouched too.
    final schedule = _ref.read(scheduleRiverpod);
    final cascades = toBefore ? step.cascades.reversed : step.cascades;
    for (final c in cascades) {
      toBefore ? await c.undo(schedule) : await c.redo(schedule);
    }
    await _save(current, copyJobListFields(current, target, step.keys), labels);
  }
}
