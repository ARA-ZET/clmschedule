import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/collection_job.dart';
import '../models/driver.dart';
import '../models/dropsheet_day.dart';
import '../models/dropsheet_task.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../services/dropsheet_service.dart';
import '../services/firestore_service.dart';

/// Synthetic section id used for distributors auto-imported from the
/// schedule that haven't yet been assigned to a driver. Lives at the
/// top of every dropsheet so the user can drag stops onto drivers.
const String kUnassignedSectionId = '_unassigned';

final dropsheetServiceRiverpod =
    riverpod.Provider<DropsheetService>((ref) => DropsheetService());

final dropsheetRiverpod = riverpod.ChangeNotifierProvider<DropsheetProvider>(
  (ref) => DropsheetProvider(ref.read(dropsheetServiceRiverpod)),
);

/// Manages the currently selected day's dropsheet.
///
/// Loads / streams `/dropsheet/daily/{YYYY-MM-DD}` and exposes mutation
/// helpers (add / remove / reorder tasks, add driver section, etc.).
/// All mutations write the full day document back to Firestore.
class DropsheetProvider extends ChangeNotifier {
  final DropsheetService _service;
  StreamSubscription? _sub;

  DateTime _date = _today();
  DropsheetDay _day = DropsheetDay(date: _today());
  bool _isLoading = false;
  String? _error;

  DropsheetProvider(this._service) {
    _listen();
  }

  DateTime get date => _date;
  DropsheetDay get day => _day;
  bool get isLoading => _isLoading;
  String? get error => _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  void setDate(DateTime d) {
    final normalised = DateTime(d.year, d.month, d.day);
    if (normalised == _date) return;
    _date = normalised;
    _listen();
    notifyListeners();
  }

  void _listen() {
    _sub?.cancel();
    _isLoading = true;
    _sub = _service.streamDay(_date).listen(
      (day) {
        _day = day;
        _isLoading = false;
        _error = null;
        notifyListeners();
      },
      onError: (e) {
        _error = e.toString();
        _isLoading = false;
        notifyListeners();
      },
    );
    // First-open seeding: if the day's document doesn't exist yet, build
    // an "Unassigned" section pre-filled with one drop-off task per
    // distributor scheduled for that date.
    _maybeAutoSeed(_date);
  }

  /// If the day document doesn't yet exist in Firestore, build a fresh
  /// dropsheet seeded from `/schedule/daily/{date}`: one drop-off task
  /// per distributor scheduled, parked under a synthetic "Unassigned"
  /// section that the user drags onto driver sections.
  Future<void> _maybeAutoSeed(DateTime date) async {
    try {
      final exists = await _service.dayExists(date);
      if (exists) return;
      // Race-guard: don't seed for an old date if the user has moved on.
      if (date != _date) return;
      final fs = FirestoreService();
      final jobs = await fs.fetchJobsForDate(date);
      if (jobs.isEmpty) return;
      final distributors = await fs.fetchDistributorsOnce();
      final byId = {for (final d in distributors) d.id: d};
      final tasks = _buildDropOffTasks(jobs, byId);
      if (tasks.isEmpty) return;
      final unassigned = DropsheetDriverSection(
        id: kUnassignedSectionId,
        driverId: kUnassignedSectionId,
        driverName: 'Unassigned stops',
        tasks: tasks,
      );
      // Race-guard: another listener may have written meanwhile.
      if (date != _date) return;
      await _save(_day.copyWith(sections: [unassigned, ..._day.sections]));
    } catch (_) {
      // Auto-seed failures are non-fatal — the user can still build the
      // dropsheet manually.
    }
  }

  /// Manually re-sync from the schedule: any distributor scheduled for
  /// today that isn't already represented anywhere on the dropsheet (in
  /// any section, identified by `typeData.distributorJobId`) is added
  /// to the Unassigned section.
  Future<void> syncFromSchedule() async {
    final fs = FirestoreService();
    final jobs = await fs.fetchJobsForDate(_date);
    final distributors = await fs.fetchDistributorsOnce();
    final byId = {for (final d in distributors) d.id: d};

    final knownJobIds = <String>{};
    for (final s in _day.sections) {
      for (final t in s.tasks) {
        final id = t.typeData['distributorJobId'] as String?;
        if (id != null) knownJobIds.add(id);
      }
    }
    final newJobs = jobs.where((j) => !knownJobIds.contains(j.id)).toList();
    if (newJobs.isEmpty) return;
    final newTasks = _buildDropOffTasks(newJobs, byId);

    final sections = [..._day.sections];
    final idx =
        sections.indexWhere((s) => s.id == kUnassignedSectionId);
    if (idx == -1) {
      sections.insert(
        0,
        DropsheetDriverSection(
          id: kUnassignedSectionId,
          driverId: kUnassignedSectionId,
          driverName: 'Unassigned stops',
          tasks: newTasks,
        ),
      );
    } else {
      sections[idx] = sections[idx]
          .copyWith(tasks: [...sections[idx].tasks, ...newTasks]);
    }
    await _save(_day.copyWith(sections: sections));
  }

  List<DropsheetTask> _buildDropOffTasks(
      List<Job> jobs, Map<String, Distributor> byId) {
    final out = <DropsheetTask>[];
    for (final j in jobs) {
      final dist = byId[j.distributorId];
      final name = dist?.name ?? j.distributorId;
      final phone = dist?.phone1 ?? '';
      final wa = j.workingAreas.join(', ');
      out.add(
        DropsheetTask(
          id: 't_dropoff_${j.id}_${DateTime.now().microsecondsSinceEpoch}_${out.length}',
          type: DropsheetTaskType.dropOff,
          job: wa.isEmpty ? 'Drop off' : 'Drop off: $wa',
          details: name,
          location: wa,
          contact: name,
          tel: phone,
          typeData: {
            'distributorJobId': j.id,
            'distributorId': j.distributorId,
            'distributorName': name,
            'workArea': wa,
            if (j.dropOffPoint != null) 'lat': j.dropOffPoint!.latitude,
            if (j.dropOffPoint != null) 'lng': j.dropOffPoint!.longitude,
          },
        ),
      );
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  Future<void> _save(DropsheetDay updated) async {
    _day = updated;
    notifyListeners();
    await _service.saveDay(updated);
  }

  /// Add a driver section seeded with the 3 mandatory tasks.
  Future<void> addDriverSection(
    Driver driver, {
    VehicleType? vehicle,
    TrailerType? trailer,
  }) async {
    if (_day.sections.any((s) => s.driverId == driver.id)) return;
    final section = DropsheetDriverSection.create(
      driverId: driver.id,
      driverName: driver.name,
      vehicle: vehicle ?? driver.defaultVehicle,
      trailer: trailer ?? driver.defaultTrailer,
    );
    await _save(_day.copyWith(sections: [..._day.sections, section]));
  }

  Future<void> removeDriverSection(String sectionId) async {
    final next = _day.sections.where((s) => s.id != sectionId).toList();
    await _save(_day.copyWith(sections: next));
  }

  Future<void> updateDriverSection(DropsheetDriverSection updated) async {
    final next = _day.sections
        .map((s) => s.id == updated.id ? updated : s)
        .toList();
    await _save(_day.copyWith(sections: next));
  }

  // --- task mutations ---

  Future<void> addTask(String sectionId, {DropsheetTask? task}) async {
    final newTask = task ??
        DropsheetTask(
          id: 't_${DateTime.now().microsecondsSinceEpoch}',
        );
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      return s.copyWith(tasks: [...s.tasks, newTask]);
    }).toList();
    await _save(_day.copyWith(sections: next));
  }

  Future<void> updateTask(String sectionId, DropsheetTask task) async {
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      return s.copyWith(
        tasks: s.tasks.map((t) => t.id == task.id ? task : t).toList(),
      );
    }).toList();
    await _save(_day.copyWith(sections: next));
  }

  Future<void> removeTask(String sectionId, String taskId) async {
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      // Mandatory tasks cannot be deleted.
      final remaining =
          s.tasks.where((t) => t.id != taskId || t.isMandatory).toList();
      return s.copyWith(tasks: remaining);
    }).toList();
    await _save(_day.copyWith(sections: next));
  }

  /// Reorder a task within the same section OR move it across sections.
  Future<void> moveTask({
    required String fromSectionId,
    required int fromIndex,
    required String toSectionId,
    required int toIndex,
  }) async {
    final sections = [..._day.sections];
    final fromIdx = sections.indexWhere((s) => s.id == fromSectionId);
    final toIdx = sections.indexWhere((s) => s.id == toSectionId);
    if (fromIdx == -1 || toIdx == -1) return;

    final fromTasks = [...sections[fromIdx].tasks];
    if (fromIndex < 0 || fromIndex >= fromTasks.length) return;
    final task = fromTasks.removeAt(fromIndex);

    if (fromSectionId == toSectionId) {
      final clamped = toIndex.clamp(0, fromTasks.length);
      fromTasks.insert(clamped, task);
      sections[fromIdx] = sections[fromIdx].copyWith(tasks: fromTasks);
    } else {
      sections[fromIdx] = sections[fromIdx].copyWith(tasks: fromTasks);
      final toTasks = [...sections[toIdx].tasks];
      final clamped = toIndex.clamp(0, toTasks.length);
      toTasks.insert(clamped, task);
      sections[toIdx] = sections[toIdx].copyWith(tasks: toTasks);
    }

    await _save(_day.copyWith(sections: sections));
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }
}
