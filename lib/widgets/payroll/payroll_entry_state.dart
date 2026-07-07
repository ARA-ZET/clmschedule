import 'package:flutter/material.dart';

import '../../models/payroll_daily_entry.dart';

enum DayMode { off, special, normal }

/// Mutable editing state for one distributor's one day, seeded from a
/// [PayrollDailyEntry]. Shared between [DailyEntryEditor] (one distributor,
/// 7 days) and the Ops Stats bulk day editor (all distributors, one day).
class DayEntryState {
  final DateTime date;
  DayMode mode;
  String? specialCode;
  final TextEditingController flyerSets;
  final TextEditingController kmWalked;
  final TextEditingController waypointsReached;
  final TextEditingController auditScore;
  final TextEditingController notes;
  bool estimateReached;

  DayEntryState(PayrollDailyEntry entry)
      : date = entry.date,
        mode = !entry.worked
            ? DayMode.off
            : (entry.specialCode != null ? DayMode.special : DayMode.normal),
        specialCode = entry.specialCode,
        estimateReached = entry.estimateReached,
        flyerSets = TextEditingController(
            text: entry.flyerSets?.toString() ?? ''),
        kmWalked =
            TextEditingController(text: entry.kmWalked?.toString() ?? ''),
        waypointsReached = TextEditingController(
            text: entry.waypointsReached?.toString() ?? ''),
        auditScore =
            TextEditingController(text: entry.auditScore?.toString() ?? ''),
        notes = TextEditingController(text: entry.notes);

  PayrollDailyEntry get entry => PayrollDailyEntry(
        date: date,
        worked: mode != DayMode.off,
        specialCode: mode == DayMode.special ? specialCode : null,
        flyerSets: mode == DayMode.normal ? int.tryParse(flyerSets.text) : null,
        kmWalked:
            mode == DayMode.normal ? double.tryParse(kmWalked.text) : null,
        waypointsReached: mode == DayMode.normal
            ? int.tryParse(waypointsReached.text)
            : null,
        estimateReached: mode == DayMode.normal ? estimateReached : false,
        auditScore: int.tryParse(auditScore.text),
        notes: notes.text,
      );

  void dispose() {
    flyerSets.dispose();
    kmWalked.dispose();
    waypointsReached.dispose();
    auditScore.dispose();
    notes.dispose();
  }
}
