import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/collection_job.dart';
import '../models/driver.dart';
import '../models/dropsheet_day.dart';
import '../models/dropsheet_task.dart';
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/job_list_item.dart';
import '../services/dropsheet_service.dart';
import '../services/firestore_service.dart';
import '../services/geocoding_service.dart';
import '../services/job_list_service.dart';
import 'dropsheet_task_config_provider.dart';
import 'job_list_provider.dart';
import 'job_type_provider.dart';
import 'schedule_provider.dart';

/// Synthetic section id used for distributors auto-imported from the
/// schedule that haven't yet been assigned to a driver. Lives at the
/// top of every dropsheet so the user can drag stops onto drivers.
const String kUnassignedSectionId = '_unassigned';

const List<String> _distributorTaskDataKeys = [
  'distributorJobId',
  'distributorId',
  'distributorName',
  'workArea',
  'lat',
  'lng',
];

class DropsheetPickupSyncResult {
  final int dropOffs;
  final int created;
  final int skipped;
  final int reordered;

  const DropsheetPickupSyncResult({
    required this.dropOffs,
    required this.created,
    required this.skipped,
    required this.reordered,
  });
}

final dropsheetServiceRiverpod =
    riverpod.Provider<DropsheetService>((ref) => DropsheetService());

final dropsheetRiverpod = riverpod.ChangeNotifierProvider<DropsheetProvider>(
  (ref) => DropsheetProvider(ref.read(dropsheetServiceRiverpod), ref),
);

/// Manages the currently selected day's dropsheet.
///
/// Loads / streams `/dropsheet/daily/{YYYY-MM-DD}` and exposes mutation
/// helpers (add / remove / reorder tasks, add driver section, etc.).
/// All mutations write the full day document back to Firestore.
class DropsheetProvider extends ChangeNotifier {
  final DropsheetService _service;
  final riverpod.Ref? _ref;
  static const Duration _distributorCacheTtl = Duration(minutes: 10);
  static List<Distributor>? _syncDistributorsCache;
  static DateTime? _syncDistributorsCacheAt;
  StreamSubscription? _sub;
  StreamSubscription<List<Job>>? _scheduleSub;
  StreamSubscription<List<JobListItem>>? _jobListSub;
  VoidCallback? _jobListProviderListener;
  Timer? _autoSyncDebounce;
  Timer? _jobListSyncDebounce;
  bool _dayReady = false;
  List<Job> _pendingJobs = const [];
  List<JobListItem> _pendingJobListItems = const [];

  DateTime _date = _today();
  DropsheetDay _day = DropsheetDay(date: _today());
  bool _isLoading = false;
  String? _error;
  List<Distributor>? _resolvedDistributorsCache;
  DateTime? _resolvedDistributorsCacheAt;

  DropsheetProvider(this._service, [this._ref]) {
    _listen();
  }

  /// Return distributors from the already-streamed [ScheduleProvider] cache
  /// when available, falling back to a cache-first one-shot fetch only when
  /// the cache is empty (e.g. dropsheet flavor started before the schedule
  /// stream delivered its first snapshot). This avoids re-reading the
  /// `distributors` collection every time the dropsheet seeds / syncs.
  Future<List<Distributor>> _resolveDistributors(FirestoreService fs) async {
    final cached = _ref?.read(scheduleRiverpod).distributors;
    if (cached != null && cached.isNotEmpty) {
      _resolvedDistributorsCache = cached;
      _resolvedDistributorsCacheAt = DateTime.now();
      return cached;
    }

    final now = DateTime.now();
    final localCached = _resolvedDistributorsCache;
    final localCacheAt = _resolvedDistributorsCacheAt;
    if (localCached != null &&
        localCached.isNotEmpty &&
        localCacheAt != null &&
        now.difference(localCacheAt) <= _distributorCacheTtl) {
      return localCached;
    }

    final fetched = await fs.fetchDistributorsOnce();
    _resolvedDistributorsCache = fetched;
    _resolvedDistributorsCacheAt = now;
    return fetched;
  }

  DateTime get date => _date;
  DropsheetDay get day => _day;
  bool get isLoading => _isLoading;
  String? get error => _error;

  static DateTime _today() {
    final n = DateTime.now();
    return DateTime(n.year, n.month, n.day);
  }

  /// The next "planning day" after [from], skipping weekends so that
  /// Friday's planning window reaches Monday.
  ///
  ///  - Mon → Tue, Tue → Wed, Wed → Thu, Thu → Fri
  ///  - Fri → Mon (skip Sat/Sun)
  ///  - Sat → Mon, Sun → Mon
  static DateTime _nextPlanningDay(DateTime from) {
    var d = from.add(const Duration(days: 1));
    while (d.weekday == DateTime.saturday || d.weekday == DateTime.sunday) {
      d = d.add(const Duration(days: 1));
    }
    return DateTime(d.year, d.month, d.day);
  }

  /// Whether [activeDate] falls inside the auto-sync window — today or
  /// the next planning day (which on Friday/weekends is the upcoming
  /// Monday). Any other date is treated as historical / future planning
  /// and is left alone unless the user triggers a manual sync.
  static bool _isAutoSyncEligible(DateTime activeDate) {
    final today = _today();
    if (activeDate == today) return true;
    if (activeDate == _nextPlanningDay(today)) return true;
    return false;
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
    _scheduleSub?.cancel();
    _jobListSub?.cancel();
    _removeJobListProviderListener();
    _autoSyncDebounce?.cancel();
    _jobListSyncDebounce?.cancel();
    _isLoading = true;
    _dayReady = false;
    _pendingJobs = const [];
    _pendingJobListItems = const [];
    final activeDate = _date;
    _sub = _service.streamDay(activeDate).listen(
      (day) {
        if (activeDate != _date) return;
        _day = day;
        _isLoading = false;
        _error = null;
        _dayReady = true;
        notifyListeners();
        // Once we know the live day state, run any pending syncs.
        if (_pendingJobs.isNotEmpty || _day.sections.isEmpty) {
          _scheduleAutoSync();
        }
        // Open the job-list stream now if JobTypeProvider wasn't ready yet
        // when _listen() originally ran (types load asynchronously).
        if (_isAutoSyncEligible(activeDate) && _jobListSub == null) {
          _setupJobListStream(activeDate);
        }
        if (_pendingJobListItems.isNotEmpty) {
          _scheduleJobListSync();
        }
      },
      onError: (e) {
        if (activeDate != _date) return;
        _error = e.toString();
        _isLoading = false;
        notifyListeners();
      },
    );

    // Listen to the schedule's jobs for the active date and keep the
    // dropsheet in sync with it (replaces the server-side
    // `onScheduleDayChanged` trigger). Bursts of writes are debounced
    // so we don't thrash the Pass-1/Pass-2 sync loop.
    //
    // Only auto-sync for the live planning window (today + next planning
    // day, which is Monday when today is Fri/Sat/Sun). Historical and
    // far-future dates can still be synced manually but won't subscribe
    // to the schedule stream.
    if (!_isAutoSyncEligible(activeDate)) return;
    final fs = FirestoreService();
    _scheduleSub = fs.streamJobsForDate(activeDate).listen(
      (jobs) {
        if (activeDate != _date) return;
        _pendingJobs = jobs;
        _scheduleAutoSync();
      },
      onError: (e) {
        debugPrint('DropsheetProvider: schedule stream error: $e');
      },
    );

    _setupJobListStream(activeDate);
  }

  /// Opens (or re-opens) the job-list data source for [activeDate].
  ///
  /// Strategy:
  /// - Same month as [JobListProvider.currentMonth] → attach a [ChangeNotifier]
  ///   listener so we piggyback on the existing Firestore stream at no cost.
  /// - Different month (e.g. today is the last Friday of May and the next
  ///   planning day is a Monday in June) → open an independent Firestore
  ///   stream for that month so the data is available.
  void _setupJobListStream(DateTime activeDate) {
    // Tear down any previous source.
    _jobListSub?.cancel();
    _jobListSub = null;
    _removeJobListProviderListener();

    final jtp = _ref?.read(jobTypeRiverpod) ?? JobTypeProvider.instance;
    final eligibleIds = jtp?.dropsheetTypeIds ?? const <String>[];
    if (eligibleIds.isEmpty) {
      return; // types not loaded yet — day callback retries
    }

    final jlp = _ref?.read(jobListRiverpod);
    final sameMonth = jlp != null &&
        jlp.currentMonth.year == activeDate.year &&
        jlp.currentMonth.month == activeDate.month;

    if (sameMonth) {
      // Reuse the JobListProvider stream — no extra Firestore subscription.
      _jobListProviderListener = () {
        if (activeDate != _date) return;
        _pendingJobListItems = jlp.allJobListItems
            .where((item) => jtp!.appearsOnDropsheet(item.jobTypeId))
            .where((item) =>
                item.date.year == activeDate.year &&
                item.date.month == activeDate.month &&
                item.date.day == activeDate.day)
            .toList();
        _scheduleJobListSync();
      };
      jlp.addListener(_jobListProviderListener!);
      // Trigger an immediate pass in case JLP already has items loaded.
      _jobListProviderListener!();
    } else {
      // Next planning day is in a different month — open an independent stream.
      final jls = JobListService(FirebaseFirestore.instance);
      _jobListSub = jls.getJobListItems(activeDate, eligibleIds).listen(
        (items) {
          if (activeDate != _date) return;
          _pendingJobListItems = items
              .where((item) =>
                  item.date.year == activeDate.year &&
                  item.date.month == activeDate.month &&
                  item.date.day == activeDate.day)
              .toList();
          _scheduleJobListSync();
        },
        onError: (e) {
          debugPrint('DropsheetProvider: job list stream error: $e');
        },
      );
    }
  }

  void _removeJobListProviderListener() {
    final listener = _jobListProviderListener;
    if (listener == null) return;
    _ref?.read(jobListRiverpod).removeListener(listener);
    _jobListProviderListener = null;
  }

  void _scheduleAutoSync() {
    // Wait until the dropsheet day stream has delivered its first
    // snapshot — otherwise Pass 1 would run against the empty
    // placeholder day and wipe live driver assignments.
    if (!_dayReady) return;
    // Skip dates outside the live planning window (today + next
    // planning day). Manual `syncFromSchedule()` calls still work.
    if (!_isAutoSyncEligible(_date)) return;
    _autoSyncDebounce?.cancel();
    _autoSyncDebounce = Timer(const Duration(milliseconds: 400), () {
      final jobs = _pendingJobs;
      if (jobs.isEmpty && _day.sections.isEmpty) return;
      _autoSyncFromJobs(jobs);
    });
  }

  Future<void> _autoSyncFromJobs(List<Job> jobs) async {
    try {
      await syncFromSchedule(jobs: jobs);
    } catch (e) {
      debugPrint('DropsheetProvider: auto-sync failed: $e');
    }
  }

  void _scheduleJobListSync() {
    if (!_dayReady) return;
    if (!_isAutoSyncEligible(_date)) return;
    _jobListSyncDebounce?.cancel();
    _jobListSyncDebounce = Timer(const Duration(milliseconds: 400), () {
      syncJobListTasks().catchError((e) {
        debugPrint('DropsheetProvider: job list sync failed: $e');
      });
    });
  }

  /// Syncs job-list items that have [appearsOnDropsheet] with the current day.
  ///
  /// Pass A — update / remove existing jl-sourced tasks across all sections:
  ///   Tasks linked via [DropsheetTask.sourceJobListItemId] are updated when
  ///   the source item changes (using a fingerprint), or removed when the item
  ///   is deleted from the job list.
  ///
  /// Pass B — add new items to the Unassigned bucket:
  ///   Job-list items that have no matching task anywhere are geocoded and
  ///   added to the Unassigned section with their type-appropriate task data.
  ///
  /// Only operates within the auto-sync eligibility window. Can be called
  /// manually (e.g. from a "Refresh" button) to force a re-sync.
  Future<void> syncJobListTasks({List<JobListItem>? items}) async {
    final jtp = JobTypeProvider.instance;
    if (jtp == null) return;

    final jobListItems = items ?? _pendingJobListItems;
    final itemsById = <String, JobListItem>{
      for (final item in jobListItems) item.id: item,
    };

    // ── Pass A: update / remove existing jl-sourced tasks ─────────────────
    var changed = false;
    var nextSections = _day.sections.map((section) {
      final nextTasks = <DropsheetTask>[];
      for (final task in section.tasks) {
        final srcId = task.sourceJobListItemId;
        if (srcId == null) {
          nextTasks.add(task);
          continue;
        }
        final item = itemsById[srcId];
        if (item == null) {
          // Job was deleted from the job list — remove the task.
          changed = true;
          continue;
        }
        // Re-build only when the item's fingerprint changed.
        final fp = _jobListTaskFingerprint(item);
        if (task.typeData['_jlFp'] == fp) {
          nextTasks.add(task);
          continue;
        }
        changed = true;
        nextTasks.add(_buildJobListTask(item, jtp, existingTask: task));
      }
      return section.copyWith(tasks: nextTasks);
    }).toList();

    // ── Pass B: add genuinely new items to Unassigned ─────────────────────
    final existingSourceIds = <String>{
      for (final s in nextSections)
        for (final t in s.tasks)
          if (t.sourceJobListItemId != null) t.sourceJobListItemId!,
    };

    final newItems = jobListItems
        .where((item) =>
            !existingSourceIds.contains(item.id) &&
            jtp.appearsOnDropsheet(item.jobTypeId))
        .toList();

    if (newItems.isNotEmpty) {
      changed = true;
      final newTasks = <DropsheetTask>[];
      for (final item in newItems) {
        var task = _buildJobListTask(item, jtp);
        // Geocode the address before persisting so the route optimiser and
        // map view have coordinates immediately.
        final address = task.location.trim();
        if (address.isNotEmpty && !task.typeData.containsKey('lat')) {
          final query = '$address, Western Cape, South Africa';
          final coords = await GeocodingService().geocodeAddress(query);
          if (coords != null) {
            final td = Map<String, dynamic>.from(task.typeData)
              ..['lat'] = coords['lat']
              ..['lng'] = coords['lng'];
            task = task.copyWith(typeData: td);
          }
        }
        newTasks.add(task);
      }

      final idx = nextSections.indexWhere((s) => s.id == kUnassignedSectionId);
      if (idx == -1) {
        nextSections = [
          DropsheetDriverSection(
            id: kUnassignedSectionId,
            driverId: kUnassignedSectionId,
            driverName: 'Unassigned stops',
            tasks: newTasks,
          ),
          ...nextSections,
        ];
      } else {
        nextSections = [
          for (var i = 0; i < nextSections.length; i++)
            i == idx
                ? nextSections[i]
                    .copyWith(tasks: [...nextSections[i].tasks, ...newTasks])
                : nextSections[i],
        ];
      }
    }

    if (!changed) return;
    await _save(_day.copyWith(sections: nextSections), skipIfUnchanged: true);
  }

  /// Build a [DropsheetTask] from a [JobListItem] that has [appearsOnDropsheet].
  /// Uses the same logic as the manual task editor dialog:
  ///  - contact/tel split by South African phone regex
  ///  - address: `area` preferred (unless it is a map URL), then `collectionAddress`
  ///  - job title uses a clean type label + client name (phone stripped)
  ///  - furnitureMove derives loadingAddress / offloadAddress the same way
  ///    the picker does (area → loading, collectionAddress → offload if area
  ///    was used, otherwise specialInstructions as fallback)
  /// When [existingTask] is supplied, geocoded coordinates, the user's
  /// manually adjusted [DropsheetTask.startTime], and any user-edited
  /// `offloadAddress` are preserved.
  static DropsheetTask _buildJobListTask(
    JobListItem item,
    JobTypeProvider jtp, {
    DropsheetTask? existingTask,
  }) {
    final taskType =
        DropsheetTaskType.fromKey(jtp.dropsheetTaskTypeKey(item.jobTypeId));
    final label = jtp.getJobTypeLabel(item.jobTypeId);

    // Address: prefer area unless it is a map link (mirrors _addressForJobListItem).
    final address = _addressForItem(item);

    // Split contact name from phone number (mirrors _contactTelFromClient).
    final (:contact, :tel) = _splitContactTel(item.client);
    final clientName = contact.isEmpty ? item.client.trim() : contact;

    // Use a human-friendly type label that matches the dialog's task title.
    final typeLabel = switch (taskType) {
      DropsheetTaskType.collection => 'Collection',
      DropsheetTaskType.furnitureMove => 'Furniture move',
      _ => label,
    };

    // Extract time slot from date when the job type requires one.
    final autoTime = jtp.needsTimeSlot(item.jobTypeId) && item.date.hour != 0
        ? '${item.date.hour.toString().padLeft(2, '0')}:'
            '${item.date.minute.toString().padLeft(2, '0')}'
        : '';

    // Preserve geocoded coordinates so re-syncs don't erase them.
    final lat = (existingTask?.typeData['lat'] as num?)?.toDouble();
    final lng = (existingTask?.typeData['lng'] as num?)?.toDouble();

    // Build type-specific typeData (matches dialog setState block).
    final typeData = <String, dynamic>{
      'jobListItemId': item.id,
      'client': item.client,
      'address': address,
      'jobType': item.jobTypeId,
      'jobTypeLabel': label,
      if (item.area.isNotEmpty) 'area': item.area,
      if (item.quantity > 0) 'quantity': item.quantity,
      if (item.invoice.isNotEmpty) 'invoice': item.invoice,
      if (item.specialInstructions.isNotEmpty)
        'specialInstructions': item.specialInstructions,
      '_jlFp': _jobListTaskFingerprint(item),
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (taskType == DropsheetTaskType.furnitureMove) ...{
        'loadingAddress': address,
        // Offload: if area filled loading, use collectionAddress; otherwise
        // fall back to specialInstructions — same logic as the dialog picker.
        'offloadAddress': existingTask?.typeData['offloadAddress'] as String? ??
            () {
              final area = item.area.trim();
              final col = item.collectionAddress.trim();
              final si = item.specialInstructions.trim();
              if (area.isNotEmpty && !_isMapLinkOrUrl(area) && col.isNotEmpty) {
                return col;
              }
              return si.isNotEmpty ? si : '';
            }(),
        'notes': item.specialInstructions,
      },
    };

    return DropsheetTask(
      id: existingTask?.id ?? 't_jl_${item.id}',
      type: taskType,
      job: '$typeLabel: $clientName',
      details: item.specialInstructions,
      startTime: existingTask?.startTime ?? autoTime,
      location: address,
      contact: clientName,
      tel: tel,
      sourceJobListItemId: item.id,
      typeData: typeData,
    );
  }

  /// Resolves the primary address for [item], matching the dialog's
  /// `_addressForJobListItem`: prefer `area` unless it is a map/URL,
  /// then fall back to `collectionAddress`.
  static String _addressForItem(JobListItem item) {
    final area = item.area.trim();
    if (area.isNotEmpty && !_isMapLinkOrUrl(area)) return area;
    final col = item.collectionAddress.trim();
    if (col.isNotEmpty) return col;
    return area; // area even if it's a URL (last resort)
  }

  /// Splits a raw client string into a display name and a phone number,
  /// matching the dialog's `_contactTelFromClient` regex.
  static ({String contact, String tel}) _splitContactTel(String client) {
    final trimmed = client.trim();
    if (trimmed.isEmpty) return (contact: '', tel: '');
    final phoneMatch =
        RegExp(r'(?:\+?27|0)[0-9\s()\-]{8,}$').firstMatch(trimmed);
    if (phoneMatch == null) return (contact: trimmed, tel: '');
    final tel = phoneMatch.group(0)!.trim();
    final contact = trimmed.substring(0, phoneMatch.start).trim();
    return (contact: contact.isEmpty ? trimmed : contact, tel: tel);
  }

  /// Returns true when [text] looks like a map link or generic URL —
  /// used to decide whether `area` should be treated as an address or skipped.
  static bool _isMapLinkOrUrl(String text) {
    final v = text.trim().toLowerCase();
    if (v.isEmpty) return false;
    return v.startsWith('http://') ||
        v.startsWith('https://') ||
        v.contains('clm-maps.web.app/map/') ||
        v.contains('google.com/maps') ||
        v.contains('maps.app.goo.gl') ||
        v.contains('goo.gl/maps');
  }

  /// Fingerprint of [JobListItem] fields that affect how it renders as a
  /// Dropsheet task. Used by [syncJobListTasks] to skip no-op updates.
  static String _jobListTaskFingerprint(JobListItem item) {
    return '${item.jobTypeId}|${item.client}|${item.area}|'
        '${item.collectionAddress}|${item.date.millisecondsSinceEpoch}|'
        '${item.specialInstructions}|${item.jobStatusId}';
  }

  /// Syncs dropsheet tasks with the current schedule for [_date].
  ///
  /// Strategy (work-area sequence is always preserved):
  ///
  /// Pass 1 — update existing drop-off tasks in-place:
  ///   a. Match by `distributorJobId` (same Firestore job doc, distributor
  ///      may have changed).
  ///   b. Fallback: match by normalised work-area string (job was removed and
  ///      recreated for the same geographical area).
  ///   In both cases only distributor metadata (name, tel, typeData) is
  ///   refreshed; the task's position in the section is untouched.
  ///   Custom drop-off coordinates set by the user are preserved unless the
  ///   task migrated to a different job via the work-area fallback.
  ///
  /// Pass 2 — append genuinely new work areas to the Unassigned bucket.
  ///
  /// When [jobs] is provided we skip the one-off Firestore read and use
  /// the caller's pre-fetched list (the auto-sync path passes the live
  /// schedule stream snapshot).
  Future<void> syncFromSchedule({List<Job>? jobs}) async {
    final fs = FirestoreService();
    final scheduleJobs = jobs ?? await fs.fetchJobsForDate(_date);
    final distributors = await _resolveDistributors(fs);
    final synced = _computeSyncedDay(_day, scheduleJobs, distributors);
    await _save(synced, skipIfUnchanged: true);
  }

  /// One-shot sync of an **arbitrary** dropsheet date that the current
  /// provider may not be viewing. Used by [ScheduleProvider] after
  /// delete / cross-date move so the affected dropsheets stay in lockstep
  /// with the schedule, without needing the user to open them first.
  ///
  /// Works completely outside the provider's `_date` / `_day` state — it
  /// fetches the day directly, applies the same Pass-1/Pass-2 logic, and
  /// saves back if anything changed.
  static Future<void> syncDateOneShot(
    DateTime date, {
    DropsheetService? service,
    FirestoreService? firestoreService,
    List<Distributor>? distributors,
  }) async {
    final ds = service ?? DropsheetService();
    final fs = firestoreService ?? FirestoreService();
    final normalised = DateTime(date.year, date.month, date.day);
    try {
      final day = await ds.getDay(normalised);
      final jobs = await fs.fetchJobsForDate(normalised);
      final now = DateTime.now();
      List<Distributor> dists;
      if (distributors != null) {
        dists = distributors;
        if (dists.isNotEmpty) {
          _syncDistributorsCache = dists;
          _syncDistributorsCacheAt = now;
        }
      } else {
        final cached = _syncDistributorsCache;
        final cachedAt = _syncDistributorsCacheAt;
        if (cached != null &&
            cached.isNotEmpty &&
            cachedAt != null &&
            now.difference(cachedAt) <= _distributorCacheTtl) {
          dists = cached;
        } else {
          dists = await fs.fetchDistributorsOnce();
          _syncDistributorsCache = dists;
          _syncDistributorsCacheAt = now;
        }
      }
      final synced = _computeSyncedDay(day, jobs, dists);
      // Skip the save if nothing changed — avoids redundant writes and
      // the `updatedAt` bump that would echo back through any open
      // listener on this date.
      final encA = jsonEncode(day.sections.map((s) => s.toMap()).toList());
      final encB = jsonEncode(synced.sections.map((s) => s.toMap()).toList());
      if (encA == encB) return;
      await ds.saveDay(synced);
      debugPrint(
          '[DropsheetProvider] syncDateOneShot wrote ${DropsheetDay.docIdFor(normalised)}');
    } catch (e) {
      debugPrint('[DropsheetProvider] syncDateOneShot $date failed: $e');
    }
  }

  /// Pure helper that returns a new [DropsheetDay] with Pass-1 updates +
  /// Pass-2 appends applied. Shared by [syncFromSchedule] (live `_day`)
  /// and [syncDateOneShot] (arbitrary date fetched off-stream).
  static DropsheetDay _computeSyncedDay(
    DropsheetDay day,
    List<Job> scheduleJobs,
    List<Distributor> distributors,
  ) {
    final byId = {for (final d in distributors) d.id: d};

    // Build O(1) lookup maps from the live schedule. We also cache each
    // job's joined working-area string once here so later passes don't
    // recompute it 2-3 times per job.
    final jobById = <String, Job>{for (final j in scheduleJobs) j.id: j};
    final workAreaByJobId = <String, String>{
      for (final j in scheduleJobs) j.id: j.workingAreas.join(', '),
    };
    final jobByWorkArea = <String, Job>{};
    for (final j in scheduleJobs) {
      final wa = workAreaByJobId[j.id]!;
      if (wa.isNotEmpty) jobByWorkArea[wa] = j;
    }

    // Track which schedule job IDs are claimed by existing tasks.
    final consumedJobIds = <String>{};

    // ── Pass 1: update existing drop-off tasks in-place ───────────────────
    // (Mandatory tasks and non-dropOff tasks are always kept.)
    final updatedSections = day.sections.map((section) {
      final updatedTasks = <DropsheetTask>[];
      for (final task in section.tasks) {
        if (task.type != DropsheetTaskType.dropOff) {
          updatedTasks.add(task);
          continue;
        }
        final jobId = task.typeData['distributorJobId'] as String?;
        if (jobId == null) {
          // Drop-off task that wasn't seeded from a schedule job — keep.
          updatedTasks.add(task);
          continue;
        }

        // Match by job ID first, then by work area.
        Job? match = jobById[jobId];
        if (match == null) {
          final wa = task.typeData['workArea'] as String?;
          if (wa != null && wa.isNotEmpty) match = jobByWorkArea[wa];
        }
        if (match == null) {
          // Job moved to another date or was deleted — drop the task so
          // the dropsheet always reflects the current schedule.
          continue;
        }

        consumedJobIds.add(match.id);
        final dist = byId[match.distributorId];
        final name = dist?.name ?? match.distributorId;
        final phone = dist?.phone1 ?? '';
        final wa = workAreaByJobId[match.id] ?? match.workingAreas.join(', ');

        // Rebuild typeData, preserving any custom drop-off lat/lng the user
        // placed unless the task migrated to a different job.
        final td = Map<String, dynamic>.from(task.typeData)
          ..['distributorJobId'] = match.id
          ..['distributorId'] = match.distributorId
          ..['distributorName'] = name
          ..['workArea'] = wa;
        if (match.dropOffPoint != null) {
          td['lat'] = match.dropOffPoint!.latitude;
          td['lng'] = match.dropOffPoint!.longitude;
        } else if (jobId != match.id) {
          // Migrated to a different job via work-area — stale coords invalid.
          td.remove('lat');
          td.remove('lng');
        }

        updatedTasks.add(task.copyWith(
          job: wa.isEmpty ? 'Drop off' : 'Drop off: $wa',
          details: name,
          location: wa,
          contact: name,
          tel: phone,
          typeData: td,
        ));
      }
      return section.copyWith(tasks: updatedTasks);
    }).toList();

    // ── Pass 2: append genuinely new work areas to Unassigned ─────────────
    final newJobs =
        scheduleJobs.where((j) => !consumedJobIds.contains(j.id)).toList();
    List<DropsheetDriverSection> finalSections = updatedSections;
    if (newJobs.isNotEmpty) {
      final newTasks = _buildDropOffTasksStatic(newJobs, byId);
      final idx = finalSections.indexWhere((s) => s.id == kUnassignedSectionId);
      if (idx == -1) {
        finalSections = [
          DropsheetDriverSection(
            id: kUnassignedSectionId,
            driverId: kUnassignedSectionId,
            driverName: 'Unassigned stops',
            tasks: newTasks,
          ),
          ...finalSections,
        ];
      } else {
        finalSections = [
          for (var i = 0; i < finalSections.length; i++)
            i == idx
                ? finalSections[i]
                    .copyWith(tasks: [...finalSections[i].tasks, ...newTasks])
                : finalSections[i],
        ];
      }
    }

    return day.copyWith(sections: finalSections);
  }

  /// Returns true when [a] and [b] would serialise to the same Firestore
  /// document. Used to suppress no-op writes from auto-sync, which would
  /// otherwise bump `updatedAt` on every schedule snapshot and create an
  /// infinite write loop with our own `streamDay` listener.
  bool _sectionsEquivalent(
      List<DropsheetDriverSection> a, List<DropsheetDriverSection> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    final encA = jsonEncode(a.map((s) => s.toMap()).toList());
    final encB = jsonEncode(b.map((s) => s.toMap()).toList());
    return encA == encB;
  }

  /// Creates one pick-up task for each assigned drop-off task that does not
  /// already have a matching pick-up anywhere on the current day's dropsheet.
  /// The unassigned bucket is ignored until those stops are placed on drivers.
  Future<DropsheetPickupSyncResult> syncPickupsFromDropOffs(
      {bool reversed = true}) async {
    final existingPickupKeys = <String>{};
    for (final section in _day.sections) {
      for (final task in section.tasks) {
        if (task.type != DropsheetTaskType.pickUp) continue;
        final key = _pickupSyncKey(task);
        if (key != null) existingPickupKeys.add(key);
      }
    }

    final timestamp = DateTime.now().microsecondsSinceEpoch;
    var sequence = 0;
    var dropOffCount = 0;
    var createdCount = 0;
    var skippedCount = 0;
    var reorderedCount = 0;
    var changed = false;

    final updatedSections = _day.sections.map((section) {
      if (section.id == kUnassignedSectionId) return section;

      final localPickupsByKey = <String, DropsheetTask>{};
      for (final task in section.tasks) {
        if (task.type != DropsheetTaskType.pickUp) continue;
        final key = _pickupSyncKey(task);
        if (key != null) localPickupsByKey.putIfAbsent(key, () => task);
      }

      final orderedPickups = <DropsheetTask>[];
      final movedPickupIds = <String>{};
      final processedDropOffKeys = <String>{};
      final taskIter =
          reversed ? section.tasks.reversed.toList() : section.tasks.toList();
      for (final task in taskIter) {
        if (task.type != DropsheetTaskType.dropOff) continue;

        dropOffCount++;
        final dropOffKey = _dropOffSyncKey(task);
        if (!processedDropOffKeys.add(dropOffKey)) {
          skippedCount++;
          continue;
        }

        final localPickup = localPickupsByKey[dropOffKey];
        if (localPickup != null) {
          orderedPickups.add(localPickup);
          movedPickupIds.add(localPickup.id);
          skippedCount++;
          continue;
        }

        if (existingPickupKeys.contains(dropOffKey)) {
          skippedCount++;
          continue;
        }

        orderedPickups.add(_buildPickUpTaskFromDropOff(
          task,
          timestamp: timestamp,
          sequence: sequence,
        ));
        sequence++;
        existingPickupKeys.add(dropOffKey);
        createdCount++;
      }

      if (orderedPickups.isEmpty) return section;

      // Split existing tasks: everything before the trailing "Arrive" task, and
      // the trailing task itself (kept pinned at the bottom).
      final nonTrailing = section.tasks
          .where((t) =>
              !movedPickupIds.contains(t.id) && !DropsheetTask.isTrailing(t))
          .toList();
      final trailing = section.tasks.where(DropsheetTask.isTrailing).toList();

      // Insert a "Leave (start pickups)" divider once, just before the pickups.
      // Recognised by typeData['isPickupDivider'] == true; only one per section.
      final hasDivider = nonTrailing.any((t) =>
          t.type == DropsheetTaskType.leave &&
          t.typeData['isPickupDivider'] == true);
      // Default departure time: use the arrive task's existing time if
      // calculated, otherwise fall back to 17:30.
      final arriveTime = section.tasks
              .where((t) => t.type == DropsheetTaskType.arrive)
              .firstOrNull
              ?.startTime ??
          '';
      final divider = hasDivider
          ? null
          : DropsheetTask(
              id: '${section.id}_pickup_div_$timestamp',
              type: DropsheetTaskType.leave,
              job: 'Leave',
              startTime: arriveTime.isNotEmpty ? arriveTime : '17:30',
              isMandatory: false,
              typeData: const {'isPickupDivider': true},
            );

      final updatedTasks = [
        ...nonTrailing,
        if (divider != null) divider,
        ...orderedPickups,
        ...trailing,
      ];
      if (_sameTaskOrder(section.tasks, updatedTasks)) return section;

      reorderedCount += movedPickupIds.length;
      changed = true;
      return section.copyWith(tasks: updatedTasks);
    }).toList();

    final result = DropsheetPickupSyncResult(
      dropOffs: dropOffCount,
      created: createdCount,
      skipped: skippedCount,
      reordered: reorderedCount,
    );
    if (!changed) return result;
    await _save(_day.copyWith(sections: updatedSections));
    return result;
  }

  bool _sameTaskOrder(List<DropsheetTask> a, List<DropsheetTask> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  static List<DropsheetTask> _buildDropOffTasksStatic(
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

  DropsheetTask _buildPickUpTaskFromDropOff(
    DropsheetTask dropOff, {
    required int timestamp,
    required int sequence,
  }) {
    final typeData = <String, dynamic>{};
    for (final key in _distributorTaskDataKeys) {
      final value = dropOff.typeData[key];
      if (value == null) continue;
      if (value is String && value.trim().isEmpty) continue;
      typeData[key] = value;
    }
    if (_distributorSyncKey(dropOff) == null) {
      typeData['sourceDropOffTaskId'] = dropOff.id;
    }

    return DropsheetTask(
      id: 't_pickup_${timestamp}_$sequence',
      type: DropsheetTaskType.pickUp,
      job: _pickUpJobLabelFor(dropOff),
      details: dropOff.details,
      location: dropOff.location,
      contact: dropOff.contact,
      tel: dropOff.tel,
      typeData: typeData,
    );
  }

  String _pickUpJobLabelFor(DropsheetTask dropOff) {
    final sourceLabel = dropOff.job.trim();
    if (sourceLabel.isEmpty) {
      final location = dropOff.location.trim();
      return location.isEmpty ? 'Pick up' : 'Pick up: $location';
    }
    final replaced = sourceLabel.replaceFirst(
      RegExp(r'^drop[-\s]*off', caseSensitive: false),
      'Pick up',
    );
    if (replaced != sourceLabel) return replaced;
    if (sourceLabel.toLowerCase().startsWith('pick')) return sourceLabel;
    return 'Pick up: $sourceLabel';
  }

  String _dropOffSyncKey(DropsheetTask task) =>
      _distributorSyncKey(task) ?? 'dropoff:${_normaliseTaskKeyPart(task.id)}';

  String? _pickupSyncKey(DropsheetTask task) {
    final distributorKey = _distributorSyncKey(task);
    if (distributorKey != null) return distributorKey;
    final sourceDropOffTaskId =
        _normaliseTaskKeyPart(task.typeData['sourceDropOffTaskId']);
    if (sourceDropOffTaskId.isNotEmpty) {
      return 'dropoff:$sourceDropOffTaskId';
    }
    return null;
  }

  String? _distributorSyncKey(DropsheetTask task) {
    final jobId = _normaliseTaskKeyPart(task.typeData['distributorJobId']);
    if (jobId.isNotEmpty) return 'job:$jobId';

    final distributorId = _normaliseTaskKeyPart(task.typeData['distributorId']);
    final workArea = _normaliseTaskKeyPart(task.typeData['workArea']);
    if (distributorId.isNotEmpty || workArea.isNotEmpty) {
      return 'dist:$distributorId|work:$workArea';
    }

    final contact = _normaliseTaskKeyPart(task.contact);
    final location = _normaliseTaskKeyPart(task.location);
    if (contact.isNotEmpty || location.isNotEmpty) {
      return 'text:$contact|$location';
    }

    final job = _normaliseTaskKeyPart(task.job);
    if (job.isNotEmpty) return 'label:$job';
    return null;
  }

  String _normaliseTaskKeyPart(Object? value) {
    final text = value?.toString().trim().toLowerCase() ?? '';
    return text.replaceAll(RegExp(r'\s+'), ' ');
  }

  // ---------------------------------------------------------------------------
  // Mutations
  // ---------------------------------------------------------------------------

  Future<void> _save(DropsheetDay updated,
      {bool skipIfUnchanged = false}) async {
    if (skipIfUnchanged &&
        _sectionsEquivalent(_day.sections, updated.sections)) {
      return;
    }
    _day = updated;
    notifyListeners();
    await _service.saveDay(updated);
  }

  /// Optimistically refresh the cached `lat`/`lng` in any drop-off task
  /// linked to [jobId] so the route optimiser and map view stop reading
  /// the stale position immediately after a `Job.dropOffPoint` change in
  /// the schedule. Without this, the route optimiser keeps the previous
  /// coordinate until either the cloud auto-sync trigger lands or the
  /// user manually presses "Sync schedule".
  ///
  /// Pass `null` for [position] to clear the cached coordinate.
  Future<void> refreshDropOffCoords(String jobId, dynamic position) async {
    var changed = false;
    var routeInvalidatedSectionIds = <String>{};
    final nextSections = _day.sections.map((s) {
      var sectionChanged = false;
      final tasks = s.tasks.map((t) {
        if (t.type != DropsheetTaskType.dropOff) return t;
        if (t.typeData['distributorJobId'] != jobId) return t;
        final td = Map<String, dynamic>.from(t.typeData);
        if (position == null) {
          if (!td.containsKey('lat') && !td.containsKey('lng')) return t;
          td.remove('lat');
          td.remove('lng');
        } else {
          final lat = position.latitude as double;
          final lng = position.longitude as double;
          if (td['lat'] == lat && td['lng'] == lng) return t;
          td['lat'] = lat;
          td['lng'] = lng;
        }
        // Coordinates changed → stored ETA and leg duration are stale.
        // Clear them so the user immediately sees that the route needs
        // recalculation rather than incorrect timings.
        td.remove('eta');
        td.remove('legDurationS');
        changed = true;
        sectionChanged = true;
        return t.copyWith(typeData: td);
      }).toList();
      if (sectionChanged) routeInvalidatedSectionIds.add(s.id);
      return s.copyWith(tasks: tasks);
    }).toList();
    if (!changed) return;
    // Drop cached route polylines on sections that had stale coords — the
    // shape no longer matches the moved stop. User can re-run Optimise.
    final invalidated = nextSections.map((s) {
      if (!routeInvalidatedSectionIds.contains(s.id)) return s;
      if (s.routePolyline.isEmpty) return s;
      return s.copyWith(routePolyline: const []);
    }).toList();
    await _save(_day.copyWith(sections: invalidated));
  }

  /// Optimistically refresh the cached `lat`/`lng` in any pick-up task
  /// linked to [jobId] so the route optimiser and map view stop reading the
  /// stale position immediately after a `Job.pickUpPoint` change.
  Future<void> refreshPickUpCoords(String jobId, dynamic position) async {
    var changed = false;
    var routeInvalidatedSectionIds = <String>{};
    final nextSections = _day.sections.map((s) {
      var sectionChanged = false;
      final tasks = s.tasks.map((t) {
        if (t.type != DropsheetTaskType.pickUp) return t;
        if (t.typeData['distributorJobId'] != jobId) return t;
        final td = Map<String, dynamic>.from(t.typeData);
        if (position == null) {
          if (!td.containsKey('lat') && !td.containsKey('lng')) return t;
          td.remove('lat');
          td.remove('lng');
        } else {
          final lat = position.latitude as double;
          final lng = position.longitude as double;
          if (td['lat'] == lat && td['lng'] == lng) return t;
          td['lat'] = lat;
          td['lng'] = lng;
        }
        td.remove('eta');
        td.remove('legDurationS');
        changed = true;
        sectionChanged = true;
        return t.copyWith(typeData: td);
      }).toList();
      if (sectionChanged) routeInvalidatedSectionIds.add(s.id);
      return s.copyWith(tasks: tasks);
    }).toList();
    if (!changed) return;
    final invalidated = nextSections.map((s) {
      if (!routeInvalidatedSectionIds.contains(s.id)) return s;
      if (s.routePolyline.isEmpty) return s;
      return s.copyWith(routePolyline: const []);
    }).toList();
    await _save(_day.copyWith(sections: invalidated));
  }

  /// Add a driver section seeded with the 3 mandatory tasks.
  Future<void> addDriverSection(
    Driver driver, {
    VehicleType? vehicle,
    TrailerType? trailer,
  }) async {
    if (_day.sections.any((s) => s.driverId == driver.id)) return;
    final taskConfig = _ref?.read(dropsheetTaskConfigRiverpod);
    final depot = taskConfig?.depot;
    final section = DropsheetDriverSection.create(
      driverId: driver.id,
      driverName: driver.name,
      vehicle: vehicle ?? driver.defaultVehicle,
      trailer: trailer ?? driver.defaultTrailer,
      depot: depot,
    );
    await _save(_day.copyWith(sections: [..._day.sections, section]));
  }

  Future<void> removeDriverSection(String sectionId) async {
    final next = _day.sections.where((s) => s.id != sectionId).toList();
    await _save(_day.copyWith(sections: next));
  }

  Future<void> updateDriverSection(DropsheetDriverSection updated) async {
    final next =
        _day.sections.map((s) => s.id == updated.id ? updated : s).toList();
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
      // Keep the trailing "Arrive at office" task pinned to the bottom
      // — new tasks are inserted just before it.
      final trailingIdx = s.tasks.indexWhere(DropsheetTask.isTrailing);
      if (trailingIdx == -1) {
        return s.copyWith(tasks: [...s.tasks, newTask]);
      }
      final tasks = [...s.tasks];
      tasks.insert(trailingIdx, newTask);
      return s.copyWith(tasks: tasks);
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

  /// Updates the geocoded coordinates stored in a task's typeData.
  /// Used when the user drags a non-distributor task marker on the map.
  Future<void> updateTaskCoords(
      String sectionId, String taskId, double lat, double lng) async {
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      return s.copyWith(
        tasks: s.tasks.map((t) {
          if (t.id != taskId) return t;
          final td = Map<String, dynamic>.from(t.typeData)
            ..['lat'] = lat
            ..['lng'] = lng;
          return t.copyWith(typeData: td);
        }).toList(),
      );
    }).toList();
    await _save(_day.copyWith(sections: next));
  }

  /// Offline ETA propagation after a Leave task time change.
  ///
  /// Replays stored per-stop leg durations (`typeData['legDurationS']`)
  /// to shift all non-mandatory ETAs without any API call. Only runs if
  /// the section already has a computed route (at least one stop with a
  /// stored leg duration).
  ///
  /// [startTime] is the new departure time in `"HH:mm"` format (taken
  /// from the Leave task's `startTime` field).
  ///
  /// [serviceMinutes] callback returns the service-time (minutes at
  /// stop) for each task — supply `config.serviceMinutesFor` from
  /// [DropsheetTaskConfigProvider].
  Future<void> recalculateETAsFromLegs(
    String sectionId,
    String startTime,
    int Function(DropsheetTask) serviceMinutes,
  ) async {
    final sectionIndex = _day.sections.indexWhere((s) => s.id == sectionId);
    if (sectionIndex == -1) return;

    final section = _day.sections[sectionIndex];

    // Only run if the section has stored leg data from a prior optimise.
    final hasLegs = section.tasks.any(
        (t) => !t.isMandatory && (t.typeData['legDurationS'] as num?) != null);
    if (!hasLegs) return;

    // Find the pickup separator — if present, we split the replay into two
    // legs: morning (leave → drops → depot) and afternoon (separator time
    // → pickups).
    final separatorTask = section.tasks
        .where((t) =>
            t.type == DropsheetTaskType.leave &&
            t.typeData['isPickupDivider'] == true)
        .firstOrNull;
    final separatorIdx =
        separatorTask == null ? -1 : section.tasks.indexOf(separatorTask);

    final parts = startTime.split(':');
    final h = int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 7;
    final m = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 30;
    var clock = DateTime(_date.year, _date.month, _date.day, h, m);

    String fmtHHmm(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

    // ── Morning leg replay ────────────────────────────────────────────────
    final updatedTasks = <DropsheetTask>[];
    for (var i = 0; i < section.tasks.length; i++) {
      final task = section.tasks[i];

      // Separator itself keeps its own departure time unchanged.
      if (task.typeData['isPickupDivider'] == true) {
        updatedTasks.add(task);
        continue;
      }

      // Mandatory tasks are not replayed (no leg data).
      if (task.isMandatory) {
        updatedTasks.add(task);
        continue;
      }

      // Afternoon tasks (after separator) are handled in the second leg below.
      if (separatorIdx != -1 && i > separatorIdx) {
        updatedTasks.add(task); // placeholder; will be replaced below
        continue;
      }

      if (task.type == DropsheetTaskType.furnitureMove) {
        final loadLegS =
            (task.typeData['loadingLegDurationS'] as num?)?.toInt() ?? 0;
        final offLegS =
            (task.typeData['offloadLegDurationS'] as num?)?.toInt() ?? 0;
        if (loadLegS == 0 && offLegS == 0) {
          updatedTasks.add(task);
          continue;
        }
        final svc = serviceMinutes(task);
        clock = clock.add(Duration(seconds: loadLegS));
        final loadEta = fmtHHmm(clock);
        clock = clock.add(Duration(minutes: svc ~/ 2));
        clock = clock.add(Duration(seconds: offLegS));
        final offEta = fmtHHmm(clock);
        clock = clock.add(Duration(minutes: svc - (svc ~/ 2)));
        final newData = Map<String, dynamic>.from(task.typeData)
          ..['loadingEta'] = loadEta
          ..['offloadEta'] = offEta
          ..['eta'] = offEta;
        updatedTasks.add(task.copyWith(startTime: offEta, typeData: newData));
      } else {
        final legS = (task.typeData['legDurationS'] as num?)?.toInt() ?? 0;
        if (legS == 0) {
          updatedTasks.add(task);
          continue;
        }
        clock = clock.add(Duration(seconds: legS));
        final eta = fmtHHmm(clock);
        clock = clock.add(Duration(minutes: serviceMinutes(task)));
        final newData = Map<String, dynamic>.from(task.typeData)..['eta'] = eta;
        updatedTasks.add(task.copyWith(startTime: eta, typeData: newData));
      }
    }

    // Apply return-leg ETA to the arrive task using its stored leg duration.
    final withArrive = updatedTasks.map((task) {
      if (task.type != DropsheetTaskType.arrive) return task;
      final legS = (task.typeData['legDurationS'] as num?)?.toInt() ?? 0;
      if (legS == 0) return task;
      final arriveEta = fmtHHmm(clock.add(Duration(seconds: legS)));
      final newData = Map<String, dynamic>.from(task.typeData)
        ..['eta'] = arriveEta;
      return task.copyWith(startTime: arriveEta, typeData: newData);
    }).toList();

    // ── Afternoon leg replay ──────────────────────────────────────────────
    // If there's a separator, replay afternoon tasks from its departure time.
    final finalTasks = separatorIdx == -1
        ? withArrive
        : () {
            // Reset clock to separator's departure time.
            final sepTime = (withArrive[separatorIdx].startTime.isNotEmpty)
                ? withArrive[separatorIdx].startTime
                : '17:30';
            final sepParts = sepTime.split(':');
            final sh = int.tryParse(sepParts.elementAtOrNull(0) ?? '') ?? 17;
            final sm = int.tryParse(sepParts.elementAtOrNull(1) ?? '') ?? 30;
            var afClock = DateTime(_date.year, _date.month, _date.day, sh, sm);

            return withArrive.asMap().entries.map((entry) {
              final i = entry.key;
              final task = entry.value;
              if (i <= separatorIdx) return task; // morning already done
              if (task.isMandatory) return task;
              if (task.typeData['isPickupDivider'] == true) return task;

              if (task.type == DropsheetTaskType.furnitureMove) {
                final loadLegS =
                    (task.typeData['loadingLegDurationS'] as num?)?.toInt() ??
                        0;
                final offLegS =
                    (task.typeData['offloadLegDurationS'] as num?)?.toInt() ??
                        0;
                if (loadLegS == 0 && offLegS == 0) return task;
                final svc = serviceMinutes(task);
                afClock = afClock.add(Duration(seconds: loadLegS));
                final loadEta = fmtHHmm(afClock);
                afClock = afClock.add(Duration(minutes: svc ~/ 2));
                afClock = afClock.add(Duration(seconds: offLegS));
                final offEta = fmtHHmm(afClock);
                afClock = afClock.add(Duration(minutes: svc - (svc ~/ 2)));
                final newData = Map<String, dynamic>.from(task.typeData)
                  ..['loadingEta'] = loadEta
                  ..['offloadEta'] = offEta
                  ..['eta'] = offEta;
                return task.copyWith(startTime: offEta, typeData: newData);
              } else {
                final legS =
                    (task.typeData['legDurationS'] as num?)?.toInt() ?? 0;
                if (legS == 0) return task;
                afClock = afClock.add(Duration(seconds: legS));
                final eta = fmtHHmm(afClock);
                afClock = afClock.add(Duration(minutes: serviceMinutes(task)));
                final newData = Map<String, dynamic>.from(task.typeData)
                  ..['eta'] = eta;
                return task.copyWith(startTime: eta, typeData: newData);
              }
            }).toList();
          }();

    final updatedSections = [
      ..._day.sections.sublist(0, sectionIndex),
      section.copyWith(tasks: finalTasks),
      ..._day.sections.sublist(sectionIndex + 1),
    ];

    debugPrint('[Dropsheet] recalculateETAsFromLegs section=$sectionId '
        'leaveTime=$startTime hasSeparator=${separatorIdx != -1}');

    await _save(_day.copyWith(sections: updatedSections));
  }

  /// Shifts the `startTime` (and any cached ETA values in `typeData`) of
  /// every task that comes **after** [taskId] in [sectionId] by [deltaMinutes].
  ///
  /// Used when the user manually edits a task's start time so that all
  /// subsequent tasks in the same section are moved by the same offset,
  /// preserving relative spacing.
  Future<void> shiftStartTimesAfter({
    required String sectionId,
    required String taskId,
    required int deltaMinutes,
  }) async {
    if (deltaMinutes == 0) return;
    bool found = false;
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      final tasks = s.tasks.map((t) {
        if (!found) {
          if (t.id == taskId) found = true;
          return t;
        }
        // Only shift tasks that already have a start time set.
        final newStart = _addMinutesToHHmm(t.startTime, deltaMinutes);
        final newTd = Map<String, dynamic>.from(t.typeData);
        if (t.typeData['eta'] is String) {
          final v =
              _addMinutesToHHmm(t.typeData['eta'] as String, deltaMinutes);
          if (v != null) newTd['eta'] = v;
        }
        if (t.typeData['offloadEta'] is String) {
          final v = _addMinutesToHHmm(
              t.typeData['offloadEta'] as String, deltaMinutes);
          if (v != null) newTd['offloadEta'] = v;
        }
        if (t.typeData['loadingEta'] is String) {
          final v = _addMinutesToHHmm(
              t.typeData['loadingEta'] as String, deltaMinutes);
          if (v != null) newTd['loadingEta'] = v;
        }
        return t.copyWith(
          startTime: newStart ?? t.startTime,
          typeData: newTd,
        );
      }).toList();
      return s.copyWith(tasks: tasks);
    }).toList();
    debugPrint('[Dropsheet] shiftStartTimesAfter section=$sectionId '
        'taskId=$taskId delta=${deltaMinutes}min');
    await _save(_day.copyWith(sections: next));
  }

  /// Adds [deltaMinutes] to a `"HH:mm"` string.
  /// Returns `null` if the input is empty or malformed.
  /// Clamps the result to `[00:00, 23:59]` — no midnight wrapping.
  String? _addMinutesToHHmm(String hhmm, int deltaMinutes) {
    if (hhmm.isEmpty) return null;
    final parts = hhmm.split(':');
    if (parts.length != 2) return null;
    final h = int.tryParse(parts[0]);
    final m = int.tryParse(parts[1]);
    if (h == null || m == null) return null;
    final total = (h * 60 + m + deltaMinutes).clamp(0, 23 * 60 + 59);
    return '${(total ~/ 60).toString().padLeft(2, '0')}:'
        '${(total % 60).toString().padLeft(2, '0')}';
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

  /// Apply the result of a route optimisation to a single section:
  ///   - reorder its tasks (mandatory tasks stay leading & in their
  ///     original order),
  ///   - overwrite each visited task's `startTime` with the computed
  ///     arrival time,
  ///   - stamp leg distance / duration / ETA into `typeData`,
  ///   - persist the section polyline + totals.
  ///
  /// `arrivalByTaskKey` keys are `<taskId>__<role>` where role matches
  /// `DropsheetTaskRole.name` ("single" / "loading" / "offload"). For
  /// single-stop tasks the `__single` arrival is used as the task's
  /// `startTime`; for furniture-move tasks the offload arrival wins.
  Future<void> applyOptimizedRoute({
    required String sectionId,
    required List<String> taskOrder,
    required Map<String, String> arrivalByTaskKey,
    required Map<String, Map<String, dynamic>> legByTaskKey,
    required List<dynamic> polyline, // List<LatLng>
    required double totalDistanceMeters,
    required int totalDurationSeconds,
  }) async {
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      final byId = {for (final t in s.tasks) t.id: t};
      // Mandatory tasks split into leading (inspect/pack/leave) and
      // trailing (arrive). Trailing always renders last so the route
      // visualisation ends at the office.
      final leading = s.tasks
          .where((t) => t.isMandatory && !DropsheetTask.isTrailing(t))
          .toList();
      // Apply depot arrival time and return-leg duration to the arrive task.
      final depotArrival = arrivalByTaskKey['__depot'];
      final depotLeg = legByTaskKey['__depot'];
      final trailing = s.tasks.where(DropsheetTask.isTrailing).map((t) {
        if (t.type != DropsheetTaskType.arrive) return t;
        final newTypeData = Map<String, dynamic>.from(t.typeData);
        if (depotLeg != null) {
          newTypeData['legDurationS'] = depotLeg['durationSeconds'];
          newTypeData['legDistanceM'] = depotLeg['distanceMeters'];
        }
        if (depotArrival != null) newTypeData['eta'] = depotArrival;
        return t.copyWith(
          startTime: depotArrival ?? t.startTime,
          typeData: newTypeData,
        );
      }).toList();
      final orderedRest = <DropsheetTask>[];
      for (final id in taskOrder) {
        final t = byId[id];
        if (t == null || t.isMandatory) continue;
        // Build typeData updates.
        final newTypeData = Map<String, dynamic>.from(t.typeData);
        final singleEta = arrivalByTaskKey['${id}__single'];
        final offEta = arrivalByTaskKey['${id}__offload'];
        final loadEta = arrivalByTaskKey['${id}__loading'];
        final taskEta = singleEta ?? offEta ?? loadEta;
        if (loadEta != null) newTypeData['loadingEta'] = loadEta;
        if (offEta != null) newTypeData['offloadEta'] = offEta;
        if (taskEta != null) newTypeData['eta'] = taskEta;

        final legSingle = legByTaskKey['${id}__single'];
        final legOff = legByTaskKey['${id}__offload'];
        final legLoad = legByTaskKey['${id}__loading'];
        final leg = legSingle ?? legOff ?? legLoad;
        if (leg != null) {
          newTypeData['legDistanceM'] = leg['distanceMeters'];
          newTypeData['legDurationS'] = leg['durationSeconds'];
        }
        if (legLoad != null && legSingle == null) {
          newTypeData['loadingLegDistanceM'] = legLoad['distanceMeters'];
          newTypeData['loadingLegDurationS'] = legLoad['durationSeconds'];
        }
        if (legOff != null && legSingle == null) {
          newTypeData['offloadLegDistanceM'] = legOff['distanceMeters'];
          newTypeData['offloadLegDurationS'] = legOff['durationSeconds'];
        }

        orderedRest.add(t.copyWith(
          startTime: taskEta ?? t.startTime,
          typeData: newTypeData,
        ));
      }
      // Append untouched (skipped) non-mandatory tasks at the end so we
      // never silently drop user data.
      final touched = taskOrder.toSet();
      final tail = s.tasks
          .where((t) => !t.isMandatory && !touched.contains(t.id))
          .toList();

      return s.copyWith(
        tasks: [...leading, ...orderedRest, ...tail, ...trailing],
        routePolyline: List.from(polyline),
        routeDistanceMeters: totalDistanceMeters,
        routeDurationSeconds: totalDurationSeconds,
      );
    }).toList();

    debugPrint(
        '[Dropsheet] applyOptimizedRoute section=$sectionId order=${taskOrder.length} '
        'distance=${(totalDistanceMeters / 1000).toStringAsFixed(1)}km '
        'duration=${(totalDurationSeconds / 60).round()}min');

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
    // The trailing "Arrive at office" task is pinned — never move it.
    if (DropsheetTask.isTrailing(fromTasks[fromIndex])) return;
    final task = fromTasks.removeAt(fromIndex);

    if (fromSectionId == toSectionId) {
      // Cap the insert position so nothing can land after a trailing task.
      final trailingIdx = fromTasks.indexWhere(DropsheetTask.isTrailing);
      final maxIdx = trailingIdx == -1 ? fromTasks.length : trailingIdx;
      final clamped = toIndex.clamp(0, maxIdx);
      fromTasks.insert(clamped, task);
      sections[fromIdx] = sections[fromIdx].copyWith(tasks: fromTasks);
    } else {
      sections[fromIdx] = sections[fromIdx].copyWith(tasks: fromTasks);
      final toTasks = [...sections[toIdx].tasks];
      final trailingIdx = toTasks.indexWhere(DropsheetTask.isTrailing);
      final maxIdx = trailingIdx == -1 ? toTasks.length : trailingIdx;
      final clamped = toIndex.clamp(0, maxIdx);
      toTasks.insert(clamped, task);
      sections[toIdx] = sections[toIdx].copyWith(tasks: toTasks);
    }

    await _save(_day.copyWith(sections: sections));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _scheduleSub?.cancel();
    _jobListSub?.cancel();
    _removeJobListProviderListener();
    _autoSyncDebounce?.cancel();
    _jobListSyncDebounce?.cancel();
    super.dispose();
  }
}
