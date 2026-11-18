import 'dart:async';
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import '../services/appointment_timing.dart';
import '../services/client_address_pin.dart';
import '../services/dropsheet_undo.dart';
import '../undo/undo_history.dart';
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
import '../track_editor/services/te_place_names.dart' as place_names;
import '../utils/distribution_lag.dart' show jobListClientKey;
import '../utils/schedule_time.dart' show scheduleToday;

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
  // Carried so a pick-up built from a per-area drop-off renders at that same
  // per-area coordinate (see day_planner_page _stopPointsFor).
  'workAreaPin',
  // The resolved street corner stays valid for the same point.
  DropsheetTask.kPointOnlyKey,
  DropsheetTask.kIntersectionKey,
  DropsheetTask.kIntersectionAtKey,
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
/// What the dropsheet's job-list sync reads from [items], to tell a real
/// change from a JobListProvider notification that changed nothing here.
@visibleForTesting
String jobListItemsFingerprint(List<JobListItem> items) => [
      for (final item in items) '${item.id}:${item.toMap()}',
    ].join('\n');

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

  /// Whether [_pendingJobs] came from the server for this date — an empty
  /// list before that means "not loaded", not "nobody allocated".
  bool _pendingJobsLoaded = false;
  List<JobListItem> _pendingJobListItems = const [];

  /// Address → when geocoding it last failed (Pass C of [syncJobListTasks]).
  static final Map<String, DateTime> _failedGeocodes = {};
  static const Duration _geocodeRetryAfter = Duration(minutes: 10);

  static bool _recentlyFailedGeocode(String address) {
    final failedAt = _failedGeocodes[address];
    return failedAt != null &&
        DateTime.now().difference(failedAt) < _geocodeRetryAfter;
  }

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

    final fetched = await fs.fetchDistributorsOnce(fromServer: true);
    _resolvedDistributorsCache = fetched;
    _resolvedDistributorsCacheAt = now;
    return fetched;
  }

  DateTime get date => _date;
  DropsheetDay get day => _day;

  /// Whether [day] is a server-confirmed copy, safe to save over.
  bool get isDayReady => _dayReady;

  /// Whether this provider keeps [d]'s sheet in step with the schedule by
  /// itself right now: it is the open, loaded day and inside the auto-sync
  /// window, with the schedule stream attached. A [syncDateOneShot] of the
  /// same day would read and rewrite the same sheet a second time.
  bool liveSyncs(DateTime d) =>
      _dayReady &&
      _scheduleSub != null &&
      DateTime(d.year, d.month, d.day) == _date &&
      _isAutoSyncEligible(_date);

  /// Shown when a whole-sheet action is tried before the server copy loaded.
  static const String notReadyMessage =
      'Still loading this sheet from the server — try again in a moment.';

  /// Whole-sheet rewrites (manual sync, sync pick-ups) must not run on the
  /// cached copy shown before the first server snapshot: saving it would
  /// overwrite newer work (the 2026-10-13 wipe). Auto-sync already waits.
  void _requireDayReady() {
    if (!_dayReady) throw StateError(notReadyMessage);
  }
  bool get isLoading => _isLoading;
  String? get error => _error;

  /// SAST today, like the schedule — a device in another timezone (or with
  /// a wrong clock) otherwise disagreed on which sheet is live, archived or
  /// in the auto-sync window.
  static DateTime _today() => scheduleToday();

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

  /// Whether [date] is a **historical** dropsheet — any day before today.
  ///
  /// A past dropsheet is an audit record of what the drivers actually ran
  /// that day. Re-running the schedule/job-list sync against it would
  /// rewrite that record: Pass 1 drops every drop-off task whose schedule
  /// job no longer exists (jobs get deleted, moved, or recreated with a
  /// new id long after the fact) and Pass 2 then re-appends the current
  /// schedule's jobs to the "Unassigned stops" bucket — which is exactly
  /// how a fully allocated past day "reverts to unallocated".
  ///
  /// So every automated recompute path checks this first and leaves the
  /// stored day alone. Direct user edits (drag a task, edit a row, add a
  /// driver) are deliberately NOT blocked — the user can still correct an
  /// old sheet by hand; only automation is locked out.
  static bool isHistorical(DateTime date) =>
      DateTime(date.year, date.month, date.day).isBefore(_today());

  /// Whether the day currently being viewed is a historical record.
  /// Drives the "archived" badge and the manual-sync confirmation prompt.
  bool get isHistoricalDate => isHistorical(_date);

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
    _pendingJobsLoaded = false;
    _pendingJobListItems = const [];
    final activeDate = _date;
    _sub = _service.streamDayWithSource(activeDate).listen(
      (snap) {
        if (activeDate != _date) return;
        final wasReady = _dayReady;
        _day = snap.day;
        _isLoading = false;
        _error = null;
        notifyListeners();
        // Show a cached copy straight away, but never auto-sync against it:
        // a device's cache can be days old, and syncing + saving that copy
        // overwrites the live sheet (lost drivers/allocations, 2026-10-13).
        // Automation waits for a server-confirmed snapshot; offline devices
        // simply don't auto-sync.
        if (snap.fromCache) return;
        _dayReady = true;
        // Run the pending schedule sync once the live day state is known —
        // on the FIRST snapshot only (or when the day is empty). Re-syncing
        // on every snapshot made each save by another client trigger a sync
        // here; any client whose sync disagrees (e.g. an older build) then
        // wrote back, and the two overwrote each other indefinitely.
        // Schedule changes still sync via the schedule stream below.
        if ((!wasReady && _pendingJobs.isNotEmpty) || _day.sections.isEmpty) {
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
    _scheduleSub = fs.streamJobsForDate(activeDate, serverOnly: true).listen(
      (jobs) {
        if (activeDate != _date) return;
        _pendingJobs = jobs;
        _pendingJobsLoaded = true;
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
      String? lastFingerprint;
      _jobListProviderListener = () {
        if (activeDate != _date) return;
        final items = jlp.allJobListItems
            .where((item) => jtp!.appearsOnDropsheet(item.jobTypeId))
            .where((item) =>
                item.date.year == activeDate.year &&
                item.date.month == activeDate.month &&
                item.date.day == activeDate.day)
            .toList();
        // JobListProvider notifies for search typing, filters and loading
        // flags too; only this day's eligible items matter here.
        // Recorded only once the day is ready: before that
        // _scheduleJobListSync does nothing, so the first ready pass must
        // still run.
        final fingerprint = jobListItemsFingerprint(items);
        if (_dayReady && fingerprint == lastFingerprint) return;
        if (_dayReady) lastFingerprint = fingerprint;
        _pendingJobListItems = items;
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
  /// manually (e.g. from a "Refresh" button) to force a re-sync, but never
  /// against a historical day unless [force] is set — Pass A deletes tasks
  /// whose source job-list item is gone, which would quietly strip an
  /// archived sheet (see [isHistorical]).
  Future<void> syncJobListTasks(
      {List<JobListItem>? items, bool force = false}) async {
    final jtp = JobTypeProvider.instance;
    if (jtp == null) return;
    if (isHistorical(_date) && !force) {
      debugPrint('DropsheetProvider: skipped job-list sync for archived '
          '${DropsheetDay.docIdFor(_date)}');
      return;
    }

    final jobListItems = items ?? _pendingJobListItems;

    // Snapshot _day once before any async work so Pass A and the final
    // _save both operate on the same base. Without this, a concurrent
    // schedule sync could write to _day between our computation and save,
    // and the copyWith at the end would silently discard that write.
    final daySnapshot = _day;

    // Guard: if the item list is empty we cannot distinguish "stream not
    // yet loaded" from "genuinely zero items for this date". Allowing
    // Pass A to run against an empty list would delete every linked task
    // the moment the JLP listener fires before its first Firestore
    // snapshot — a silent data-loss bug. Skip the sync; the debounced
    // listener will retry as soon as the stream delivers real data.
    if (jobListItems.isEmpty) return;

    final itemsById = <String, JobListItem>{
      for (final item in jobListItems) item.id: item,
    };

    // ── Pass A: update / remove existing jl-sourced tasks ─────────────────
    var changed = false;
    var nextSections = daySnapshot.sections.map((section) {
      final nextTasks = <DropsheetTask>[];
      for (final task in section.tasks) {
        final srcId = task.sourceJobListItemId;
        if (srcId == null) {
          nextTasks.add(task);
          continue;
        }
        final userCreated = task.isUserCreatedJobListTask;
        final item = itemsById[srcId];
        if (item == null) {
          // Not in this date's eligible items. For a task the sync created
          // that means its source item is gone (deleted, moved to another
          // date, or its job type no longer appears on the dropsheet), so
          // drop it.
          //
          // For a HAND-BUILT task it means no such thing: [jobListItems] is
          // a filtered view and the editor's picker will happily offer items
          // the sync does not manage. Deleting on that basis is what made a
          // freshly added task vanish a few hundred ms later.
          if (userCreated) {
            nextTasks.add(task);
            continue;
          }
          changed = true;
          continue;
        }
        // Re-build only when the item's fingerprint changed — or the task
        // lacks its appointment time or the job's contact (sheets from
        // before they were stored; an older build's rebuild also drops
        // them). Not part of the fingerprint: changing that formula makes
        // old and new builds rebuild each other's tasks on every pass.
        final fp = _jobListTaskFingerprint(item);
        if (task.typeData[DropsheetTask.kJobListFingerprintKey] == fp &&
            task.appointmentTime == _appointmentTimeFor(item, jtp) &&
            _contactUpToDate(task, item)) {
          nextTasks.add(task);
          continue;
        }
        changed = true;
        nextTasks.add(_buildJobListTask(item, jtp,
            existingTask: task, manual: userCreated));
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
      // Geocode all new items in parallel rather than sequentially so
      // N new items cost one round-trip's worth of latency, not N×latency.
      final newTasks = await Future.wait(newItems.map((item) async {
        var task = _buildJobListTask(item, jtp);
        final td = Map<String, dynamic>.from(task.typeData);
        if (task.type == DropsheetTaskType.furnitureMove) {
          // Two-stop tasks need separate coords for each stop.
          final loadAddr = (td['loadingAddress'] as String?)?.trim() ?? '';
          final offAddr = (td['offloadAddress'] as String?)?.trim() ?? '';
          final results = await Future.wait([
            if (loadAddr.isNotEmpty && !td.containsKey('loadingLat'))
              GeocodingService()
                  .geocodeAddress('$loadAddr, Western Cape, South Africa')
            else
              Future.value(null),
            if (offAddr.isNotEmpty && !td.containsKey('offloadLat'))
              GeocodingService()
                  .geocodeAddress('$offAddr, Western Cape, South Africa')
            else
              Future.value(null),
          ]);
          final loadCoords = results[0];
          final offCoords = results[1];
          if (loadCoords != null) {
            td['loadingLat'] = loadCoords['lat'];
            td['loadingLng'] = loadCoords['lng'];
            td['lat'] = loadCoords['lat'];
            td['lng'] = loadCoords['lng'];
          }
          if (offCoords != null) {
            td['offloadLat'] = offCoords['lat'];
            td['offloadLng'] = offCoords['lng'];
          }
        } else {
          // The address point picked on the Job List job (the address
          // search when the job was added) beats geocoding the text again.
          final own = ClientAddressPin.pointFromItem(item)?.points.first;
          if (own != null && !td.containsKey('lat')) {
            td['lat'] = own.latitude;
            td['lng'] = own.longitude;
          }
          final address = task.location.trim();
          if (address.isNotEmpty && !td.containsKey('lat')) {
            final coords = await GeocodingService()
                .geocodeAddress('$address, Western Cape, South Africa');
            if (coords != null) {
              td['lat'] = coords['lat'];
              td['lng'] = coords['lng'];
            }
          }
        }
        task = task.copyWith(typeData: td);
        return task;
      }));

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

    // ── Pass C: backfill two-stop coords on existing furnitureMove tasks ──────
    // Handles tasks that were created before the two-stop geocoding was
    // introduced. They have loadingAddress/offloadAddress but no
    // loadingLat/offloadLat. Pass B only runs for truly new items, so these
    // tasks are never re-geocoded through normal sync — this pass catches them.
    // Addresses that failed to geocode recently are skipped: they were
    // re-geocoded over the network on every pass (every job-list change)
    // without ever succeeding.
    bool needsGeo(Map<String, dynamic> td, String latKey, String addrKey) {
      if (td.containsKey(latKey)) return false;
      final addr = (td[addrKey] as String?)?.trim() ?? '';
      return addr.isNotEmpty && !_recentlyFailedGeocode(addr);
    }

    // A single-stop Job List task whose address changed on the Job List lost
    // its old point in Pass A (see _buildJobListTask); look the new one up.
    bool singleStopNeedsGeo(DropsheetTask t) =>
        t.sourceJobListItemId != null &&
        t.type != DropsheetTaskType.furnitureMove &&
        !t.isDistributorTask &&
        needsGeo(t.typeData, 'lat', 'address');

    final fmNeedingGeo = [
      for (var si = 0; si < nextSections.length; si++)
        for (var ti = 0; ti < nextSections[si].tasks.length; ti++)
          for (final t in [nextSections[si].tasks[ti]])
            if ((t.type == DropsheetTaskType.furnitureMove &&
                    (needsGeo(t.typeData, 'loadingLat', 'loadingAddress') ||
                        needsGeo(t.typeData, 'offloadLat', 'offloadAddress'))) ||
                singleStopNeedsGeo(t))
              (si: si, ti: ti, task: t),
    ];

    if (fmNeedingGeo.isNotEmpty) {
      var filledAny = false;
      final geocoded = await Future.wait(fmNeedingGeo.map((e) async {
        final td = Map<String, dynamic>.from(e.task.typeData);
        if (e.task.type != DropsheetTaskType.furnitureMove) {
          final addr = (td['address'] as String).trim();
          final coords = await GeocodingService()
              .geocodeAddress('$addr, Western Cape, South Africa');
          if (coords != null) {
            td['lat'] = coords['lat'];
            td['lng'] = coords['lng'];
            // The stop moved: its leg timings are stale.
            td.remove('eta');
            td.remove('legDurationS');
            filledAny = true;
          } else {
            _failedGeocodes[addr] = DateTime.now();
          }
          return (si: e.si, ti: e.ti, td: td);
        }
        final loadAddr = needsGeo(td, 'loadingLat', 'loadingAddress')
            ? (td['loadingAddress'] as String).trim()
            : '';
        final offAddr = needsGeo(td, 'offloadLat', 'offloadAddress')
            ? (td['offloadAddress'] as String).trim()
            : '';
        final results = await Future.wait([
          if (loadAddr.isNotEmpty)
            GeocodingService()
                .geocodeAddress('$loadAddr, Western Cape, South Africa')
          else
            Future.value(null),
          if (offAddr.isNotEmpty)
            GeocodingService()
                .geocodeAddress('$offAddr, Western Cape, South Africa')
          else
            Future.value(null),
        ]);
        final loadCoords = results[0];
        final offCoords = results[1];
        if (loadCoords != null) {
          td['loadingLat'] = loadCoords['lat'];
          td['loadingLng'] = loadCoords['lng'];
          td['lat'] = loadCoords['lat'];
          td['lng'] = loadCoords['lng'];
          filledAny = true;
        } else if (loadAddr.isNotEmpty) {
          _failedGeocodes[loadAddr] = DateTime.now();
        }
        if (offCoords != null) {
          td['offloadLat'] = offCoords['lat'];
          td['offloadLng'] = offCoords['lng'];
          filledAny = true;
        } else if (offAddr.isNotEmpty) {
          _failedGeocodes[offAddr] = DateTime.now();
        }
        return (si: e.si, ti: e.ti, td: td);
      }));
      if (filledAny) {
        changed = true;
        final sections = nextSections.toList();
        for (final r in geocoded) {
          final s = sections[r.si];
          final tasks = [...s.tasks];
          tasks[r.ti] = tasks[r.ti].copyWith(typeData: r.td);
          sections[r.si] = s.copyWith(tasks: tasks);
        }
        nextSections = sections;
      }
    }

    // ── Pass D: who works each Junk & Stuff / Happy Sun job ──────────────────
    // The schedule sync keeps "Team: …" current when allocations change; this
    // covers a job that just arrived from the Job List. Only once this date's
    // schedule has loaded — before that an empty list would clear the names.
    if (_pendingJobsLoaded) {
      try {
        final crews = _withJobCrews(nextSections, _pendingJobs,
            await _resolveDistributors(FirestoreService()));
        if (crews.changed) {
          changed = true;
          nextSections = crews.sections;
        }
      } catch (e) {
        // Best-effort: the schedule sync fills the names in later.
        debugPrint('DropsheetProvider: crew names skipped: $e');
      }
    }

    if (!changed) return;

    // Pass B / Pass C geocode over the network, so this method can be several
    // seconds old by the time it gets here. `nextSections` is derived from the
    // snapshot taken at the top — writing it now would overwrite anything the
    // user saved in the meantime (edit a task, drag a stop, add a driver).
    // Bail out instead and let the debounced listener re-run against the
    // current day; the same work is cheap the second time because the
    // geocoded coordinates have already been persisted.
    if (!_sectionsEquivalent(_day.sections, daySnapshot.sections)) {
      debugPrint('DropsheetProvider: job-list sync raced a local edit — '
          'discarding stale pass and re-running');
      _scheduleJobListSync();
      return;
    }

    await _save(daySnapshot.copyWith(sections: nextSections),
        skipIfUnchanged: true);
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
  ///
  /// Set [manual] for a task the user built in the editor and linked to a
  /// job-list item by hand. Such a task keeps the type the user chose (and
  /// its `dynamicTypeId`) instead of adopting the type the job-list mapping
  /// implies, and is re-stamped as hand-built so later passes keep treating
  /// it that way — see [DropsheetTask.isUserCreatedJobListTask].
  static DropsheetTask _buildJobListTask(
    JobListItem item,
    JobTypeProvider jtp, {
    DropsheetTask? existingTask,
    bool manual = false,
  }) {
    // Two-stop job types (e.g. trailer towing, furniture moves) must render as
    // a furnitureMove dropsheet task — it is the only task type that carries a
    // loading + offloading address and two routing stops. Force the mapping so
    // a two-stop job never collapses to a single-stop collection/custom task.
    final isTwoStop = jtp.hasTwoStops(item.jobTypeId);
    final derivedType = isTwoStop
        ? DropsheetTaskType.furnitureMove
        : DropsheetTaskType.fromKey(jtp.dropsheetTaskTypeKey(item.jobTypeId));
    // The user picked the type for a hand-built task; never override it.
    final taskType =
        manual && existingTask != null ? existingTask.type : derivedType;
    final label = jtp.getJobTypeLabel(item.jobTypeId);

    // Address: prefer area unless it is a map link (mirrors _addressForJobListItem).
    final address = _addressForItem(item);

    // The client's name for the label, with any number typed on its end
    // dropped ("Collection: Mrs Smith").
    final clientName = JobListItem.splitClientPhone(item.client).contact;
    // Who the driver asks for and rings: the job's contact person and
    // phone, else the client's name and a number typed on its end.
    final site = item.siteContact;

    // Use a human-friendly type label that matches the dialog's task title.
    final typeLabel = switch (taskType) {
      DropsheetTaskType.collection => 'Collection',
      // For a forced two-stop mapping keep the job type's own label (e.g.
      // "Trailer Towing"); only the genuine furniture-move type reads "Furniture move".
      DropsheetTaskType.furnitureMove => isTwoStop ? label : 'Furniture move',
      _ => label,
    };

    // The booked time slot, when the job type has one.
    final autoTime = _appointmentTimeFor(item, jtp);

    final isTwoStopTask = taskType == DropsheetTaskType.furnitureMove;

    // Once the user has reworded a field of this task by hand, their wording
    // wins over the regenerated text — otherwise the next job-list change
    // would silently revert it. Every other field still follows the Job List
    // job, so editing it there reaches the sheet (only the fields the user
    // changed are theirs — see DropsheetTask.userEditedField). A field the
    // user blanked falls back to the generated value.
    String keepField(String field, String? edited, String generated) =>
        existingTask != null &&
                existingTask.userEditedField(field) &&
                edited != null &&
                edited.trim().isNotEmpty
            ? edited
            : generated;
    String existingText(String key) =>
        (existingTask?.typeData[key] as String?)?.trim() ?? '';
    // The two-stop addresses always followed the Job List job, even on a
    // task the user reworded; only a per-field edit of one keeps it now.
    bool listed(String field) {
      final fields =
          existingTask?.typeData[DropsheetTask.kUserEditedFieldsKey];
      return existingTask?.hasUserEdits == true &&
          fields is List &&
          fields.contains(field);
    }

    // Two-stop addresses, kept in sync with the job list:
    //   loading  ← the job's "Loading Address" (stored in `area`)
    //   offload  ← the dedicated `offloadingAddress` field
    final typedLoading = existingText('loadingAddress');
    final loadingAddress = listed('loadingAddress') && typedLoading.isNotEmpty
        ? typedLoading
        : address;
    final offloadAddress = () {
      final typed = existingText('offloadAddress');
      if (listed('offloadAddress') && typed.isNotEmpty) return typed;
      // Prefer the dedicated offloadingAddress field so edits on the job list
      // propagate to the dropsheet task.
      final offload = item.offloadingAddress.trim();
      if (offload.isNotEmpty) return offload;
      // Otherwise keep any offload the user typed directly on the task.
      final existing =
          (existingTask?.typeData['offloadAddress'] as String?)?.trim();
      if (existing != null && existing.isNotEmpty) return existing;
      // Legacy fallback: collectionAddress when area was used as loading.
      final area = item.area.trim();
      final col = item.collectionAddress.trim();
      if (area.isNotEmpty && !_isMapLinkOrUrl(area) && col.isNotEmpty) {
        return col;
      }
      return item.specialInstructions.trim();
    }();

    // Preserve geocoded coordinates across re-syncs — but only while the
    // matching address is unchanged. When the job list address changes the
    // stale coords are dropped so the sync re-geocodes them (Pass C / Pass B).
    final prevLoading =
        (existingTask?.typeData['loadingAddress'] as String?)?.trim() ?? '';
    final prevOffload =
        (existingTask?.typeData['offloadAddress'] as String?)?.trim() ?? '';
    final loadingUnchanged = prevLoading == loadingAddress.trim();
    final offloadUnchanged = prevOffload == offloadAddress.trim();

    // The single-stop address, as the task will store it.
    final singleAddress =
        keepField('address', existingTask?.typeData['address'] as String?,
            address);
    // A task stored without an address keeps its point (nothing to compare).
    final prevAddress = existingTask?.typeData['address'] as String?;
    final addressUnchanged =
        prevAddress == null || prevAddress.trim() == singleAddress.trim();

    // Single-stop tasks track the primary address in `lat`/`lng`; two-stop
    // tasks track the loading stop there. When the Job List address changes,
    // the old point goes and the sync looks up the new one (Pass C) —
    // the pin and route used to stay at the old address.
    final keepPrimaryCoords =
        isTwoStopTask ? loadingUnchanged : addressUnchanged;
    final lat = keepPrimaryCoords
        ? (existingTask?.typeData['lat'] as num?)?.toDouble()
        : null;
    final lng = keepPrimaryCoords
        ? (existingTask?.typeData['lng'] as num?)?.toDouble()
        : null;
    final loadingLat = loadingUnchanged
        ? (existingTask?.typeData['loadingLat'] as num?)?.toDouble()
        : null;
    final loadingLng = loadingUnchanged
        ? (existingTask?.typeData['loadingLng'] as num?)?.toDouble()
        : null;
    final offloadLat = offloadUnchanged
        ? (existingTask?.typeData['offloadLat'] as num?)?.toDouble()
        : null;
    final offloadLng = offloadUnchanged
        ? (existingTask?.typeData['offloadLng'] as num?)?.toDouble()
        : null;

    // Details: the job's special instructions, unless the user reworded them.
    final details =
        keepField('details', existingTask?.details, item.specialInstructions);

    // Build type-specific typeData (matches dialog setState block).
    final typeData = <String, dynamic>{
      'jobListItemId': item.id,
      'client': item.client,
      // The editor writes the collection address here; keep the user's
      // version so it stays consistent with the task's `location` field and
      // with the Maps link built from it.
      'address': singleAddress,
      'jobType': item.jobTypeId,
      'jobTypeLabel': label,
      if (item.area.isNotEmpty) 'area': item.area,
      if (item.quantity > 0) 'quantity': item.quantity,
      if (item.invoice.isNotEmpty) 'invoice': item.invoice,
      if (item.specialInstructions.isNotEmpty)
        'specialInstructions': item.specialInstructions,
      DropsheetTask.kJobListFingerprintKey: _jobListTaskFingerprint(item),
      if (autoTime.isNotEmpty) DropsheetTask.kAppointmentTimeKey: autoTime,
      // Carry the ownership + user-edit markers across the rebuild, or the
      // task would silently become sync-managed on its first refresh and the
      // next pass could delete or reword it.
      if (manual) DropsheetTask.kJobListManualKey: true,
      if (existingTask?.hasUserEdits == true)
        DropsheetTask.kUserEditedKey: true,
      if (existingTask?.typeData[DropsheetTask.kUserEditedFieldsKey] != null)
        DropsheetTask.kUserEditedFieldsKey:
            existingTask!.typeData[DropsheetTask.kUserEditedFieldsKey],
      // Who works the job comes from the schedule, not the Job List job
      // ([_withJobCrews] keeps it current); a rebuild must not drop it.
      if (existingTask?.typeData[DropsheetTask.kWithKey] != null)
        DropsheetTask.kWithKey: existingTask!.typeData[DropsheetTask.kWithKey],
      // A hand-built task may belong to a user-defined ("dynamic") task type;
      // that id lives only in typeData, so it must be carried over too.
      if (manual && existingTask?.typeData['dynamicTypeId'] != null)
        'dynamicTypeId': existingTask!.typeData['dynamicTypeId'],
      if (lat != null) 'lat': lat,
      if (lng != null) 'lng': lng,
      if (isTwoStopTask) ...{
        'loadingAddress': loadingAddress,
        'offloadAddress': offloadAddress,
        // The same text as Details (the editor's Notes box edits both).
        'notes': details,
        if (loadingLat != null) 'loadingLat': loadingLat,
        if (loadingLng != null) 'loadingLng': loadingLng,
        if (offloadLat != null) 'offloadLat': offloadLat,
        if (offloadLng != null) 'offloadLng': offloadLng,
      },
    };

    return DropsheetTask(
      id: existingTask?.id ?? 't_jl_${item.id}',
      type: taskType,
      // Plain "Collection: Mrs Smith"; an appointment's time and address
      // are added for display (DropsheetTask.displayJob).
      job: keepField('job', existingTask?.job, '$typeLabel: $clientName'),
      details: details,
      startTime: _startTimeFor(existingTask, autoTime),
      location: keepField('location', existingTask?.location, address),
      contact: keepField('contact', existingTask?.contact, site.contact),
      tel: keepField('tel', existingTask?.tel, site.tel),
      sourceJobListItemId: item.id,
      // Never derived from the job-list item, so it must always survive a
      // rebuild — it was previously dropped on every re-sync.
      serviceTimeMinutes: existingTask?.serviceTimeMinutes,
      typeData: typeData,
    );
  }

  /// [item]'s booked time ("10:00") when its job type takes a time slot,
  /// else ''. Read the way the Collection Schedule reads it
  /// ([JobListItem.resolvedTimeSlot]): the time on `date`, else the slot —
  /// a job added on the Collection Schedule used to carry its time only in
  /// the slot, and showed here with none. "00:00" means none was booked.
  static String _appointmentTimeFor(JobListItem item, JobTypeProvider jtp) {
    if (!jtp.needsTimeSlot(item.jobTypeId)) return '';
    final start = item.resolvedTimeSlot;
    return start == '00:00' ? '' : start;
  }

  @visibleForTesting
  static String appointmentTimeForTest(JobListItem item, JobTypeProvider jtp) =>
      _appointmentTimeFor(item, jtp);

  @visibleForTesting
  static String startTimeForTest(DropsheetTask? existing, String appointment) =>
      _startTimeFor(existing, appointment);

  /// A rebuilt task's Start: the new appointment while Start still shows
  /// the old one (or nothing) — a rebooked slot reaches the sheet — else
  /// whatever Start holds now (a route ETA or the user's own time).
  static String _startTimeFor(DropsheetTask? existing, String appointment) {
    if (existing == null) return appointment;
    final start = existing.startTime.trim();
    if (appointment.isNotEmpty &&
        (start.isEmpty || start == existing.appointmentTime)) {
      return appointment;
    }
    return existing.startTime;
  }

  /// Resolves the primary address for [item], matching the dialog's
  /// `_addressForJobListItem`: prefer `area` unless it is a map/URL,
  /// then fall back to `collectionAddress`.
  static String _addressForItem(JobListItem item) =>
      ClientAddressPin.addressText(item);

  /// Whether [task]'s Contact and Tel are what [_buildJobListTask] would
  /// write for [item] now — a hand-typed value on a task the user reworded
  /// counts as current, as the build keeps it.
  static bool _contactUpToDate(DropsheetTask task, JobListItem item) {
    final want = item.siteContact;
    bool current(String field, String have, String generated) =>
        have == generated ||
        (task.userEditedField(field) && have.trim().isNotEmpty);
    return current('contact', task.contact, want.contact) &&
        current('tel', task.tel, want.tel);
  }

  @visibleForTesting
  static DropsheetTask buildJobListTaskForTest(
          JobListItem item, JobTypeProvider jtp,
          {DropsheetTask? existingTask}) =>
      _buildJobListTask(item, jtp, existingTask: existingTask);

  @visibleForTesting
  static bool contactUpToDateForTest(DropsheetTask task, JobListItem item) =>
      _contactUpToDate(task, item);

  /// Returns true when [text] looks like a map link or generic URL —
  /// used to decide whether `area` should be treated as an address or skipped.
  static bool _isMapLinkOrUrl(String text) =>
      ClientAddressPin.isMapLinkOrUrl(text);

  /// Fingerprint of [JobListItem] fields that affect how it renders as a
  /// Dropsheet task. Used by [syncJobListTasks] to skip no-op updates.
  static String _jobListTaskFingerprint(JobListItem item) {
    return '${item.jobTypeId}|${item.client}|${item.area}|'
        '${item.collectionAddress}|${item.offloadingAddress}|'
        '${item.date.millisecondsSinceEpoch}|'
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
  ///
  /// Refuses to touch a historical day (see [isHistorical]) unless [force]
  /// is set — the UI only sets it after the user confirms they really want
  /// to overwrite an archived sheet. Returns `false` when the sync was
  /// skipped for that reason so the caller can say so.
  Future<bool> syncFromSchedule({List<Job>? jobs, bool force = false}) async {
    _requireDayReady();
    if (isHistorical(_date) && !force) {
      debugPrint('DropsheetProvider: skipped schedule sync for archived '
          '${DropsheetDay.docIdFor(_date)}');
      return false;
    }
    final fs = FirestoreService();
    final scheduleJobs = jobs ?? await fs.fetchJobsForDate(_date);
    final distributors = await _resolveDistributors(fs);
    final synced = _computeSyncedDay(_day, scheduleJobs, distributors);
    await _save(synced, skipIfUnchanged: true);
    // Name the street corner of any new or moved drop-off point.
    unawaited(resolveIntersections());
    return true;
  }

  Future<DropsheetDay>? _intersectionsInFlight;

  /// Looks up the nearest street intersection ("Voortrekker Rd & Durban Rd")
  /// for every point-only distributor task (no work-area polygons — see
  /// [DropsheetTask.kPointOnlyKey]) whose point has none yet, so the printed
  /// sheet says where to stop instead of only naming the work area.
  ///
  /// Names come from OpenStreetMap (Overpass) in one batched query and are
  /// stored in the task's typeData against the point they describe, so each
  /// point is resolved once. Returns the day with the names applied. On a
  /// historical day the names are returned for printing but never saved —
  /// the archived sheet stays exactly as it was run. Best-effort: when the
  /// map servers don't answer, the day comes back unchanged.
  Future<DropsheetDay> resolveIntersections() => _intersectionsInFlight ??=
      _resolveIntersections().whenComplete(() => _intersectionsInFlight = null);

  Future<DropsheetDay> _resolveIntersections() async {
    bool needsName(DropsheetTask t) =>
        t.wantsIntersection && t.pointKey != null && !t.hasCurrentIntersection;

    final points = <(double, double)>[
      for (final s in _day.sections)
        for (final t in s.tasks)
          if (needsName(t))
            (
              (t.typeData['lat'] as num).toDouble(),
              (t.typeData['lng'] as num).toDouble(),
            ),
    ];
    if (points.isEmpty) return _day;

    final date = _date;
    Map<String, String?> names;
    try {
      names = await place_names.resolveIntersections(points);
    } catch (e) {
      debugPrint('DropsheetProvider: intersection lookup failed: $e');
      return _day;
    }
    if (names.isEmpty ||
        DropsheetDay.docIdFor(date) != DropsheetDay.docIdFor(_date)) {
      return _day;
    }

    // Apply to the live day — it may have changed while Overpass answered.
    var changed = false;
    final sections = _day.sections.map((s) {
      final tasks = s.tasks.map((t) {
        if (!needsName(t)) return t;
        final key = t.pointKey!;
        if (!names.containsKey(key)) return t;
        changed = true;
        return t.copyWith(typeData: {
          ...t.typeData,
          DropsheetTask.kIntersectionKey: names[key] ?? '',
          DropsheetTask.kIntersectionAtKey: key,
        });
      }).toList();
      return s.copyWith(tasks: tasks);
    }).toList();
    if (!changed) return _day;
    final updated = _day.copyWith(sections: sections);
    if (isHistorical(_date)) return updated;
    await _save(updated, backgroundFollowUp: true);
    return updated;
  }

  /// One-shot sync of an **arbitrary** dropsheet date that the current
  /// provider may not be viewing. Used by [ScheduleProvider] after
  /// delete / cross-date move so the affected dropsheets stay in lockstep
  /// with the schedule, without needing the user to open them first.
  ///
  /// Works completely outside the provider's `_date` / `_day` state — it
  /// fetches the day directly, applies the same Pass-1/Pass-2 logic, and
  /// saves back if anything changed.
  ///
  /// One run per date at a time: calls made while a date's sync is running
  /// share ONE follow-up run, started when it finishes (with the newest
  /// arguments), so a burst of schedule edits on a day reads and writes its
  /// sheet twice at most rather than once per edit.
  static Future<void> syncDateOneShot(
    DateTime date, {
    DropsheetService? service,
    FirestoreService? firestoreService,
    List<Distributor>? distributors,
  }) {
    final normalised = DateTime(date.year, date.month, date.day);
    final key = DropsheetDay.docIdFor(normalised);
    final args = (service, firestoreService, distributors);
    if (_oneShotRunning.containsKey(key)) {
      final queued = _oneShotQueued[key];
      if (queued != null) {
        queued.args = args;
        return queued.done.future;
      }
      final q = _QueuedOneShot(args);
      _oneShotQueued[key] = q;
      return q.done.future;
    }
    return _startOneShot(key, normalised, args);
  }

  static final Map<String, Future<void>> _oneShotRunning = {};
  static final Map<String, _QueuedOneShot> _oneShotQueued = {};

  static Future<void> _startOneShot(
      String key, DateTime normalised, _OneShotArgs args) {
    final run = _syncDateOneShotNow(normalised,
            service: args.$1,
            firestoreService: args.$2,
            distributors: args.$3)
        .whenComplete(() {
      _oneShotRunning.remove(key);
      final next = _oneShotQueued.remove(key);
      if (next != null) {
        next.done.complete(_startOneShot(key, normalised, next.args));
      }
    });
    _oneShotRunning[key] = run;
    return run;
  }

  static Future<void> _syncDateOneShotNow(
    DateTime normalised, {
    DropsheetService? service,
    FirestoreService? firestoreService,
    List<Distributor>? distributors,
  }) async {
    // Never rewrite a past dropsheet. A schedule edit made today (deleting
    // an old job, dragging one off a past date) must not reshuffle what
    // that day's drivers actually ran — see [isHistorical].
    if (isHistorical(normalised)) {
      debugPrint('[DropsheetProvider] syncDateOneShot skipped archived '
          '${DropsheetDay.docIdFor(normalised)}');
      return;
    }
    try {
      final ds = service ?? DropsheetService();
      final fs = firestoreService ?? FirestoreService();
      // The sheet and the schedule day are read side by side. A schedule
      // read that fails throws instead of reading as "no jobs", which
      // would strip every drop-off from the sheet.
      final (day, jobs) = await (
        ds.getDay(normalised),
        fs.fetchJobsForDate(normalised, rethrowErrors: true),
      ).wait;
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
          dists = await fs.fetchDistributorsOnce(fromServer: true);
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
      debugPrint('[DropsheetProvider] syncDateOneShot $normalised failed: $e');
    }
  }

  /// Pure helper that returns a new [DropsheetDay] with Pass-1 updates +
  /// Pass-2 appends applied. Shared by [syncFromSchedule] (live `_day`)
  /// and [syncDateOneShot] (arbitrary date fetched off-stream).
  @visibleForTesting
  static DropsheetDay computeSyncedDayForTest(
    DropsheetDay day,
    List<Job> scheduleJobs,
    List<Distributor> distributors,
  ) =>
      _computeSyncedDay(day, scheduleJobs, distributors);

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
      for (final j in scheduleJobs) j.id: _workAreaText(j),
    };
    // Work-area fallback (a job removed and recreated for the same area).
    // Only names that belong to exactly one job qualify: point jobs are named
    // after their street corner, so several distributors can share a name,
    // and matching on it would hand one distributor's drop-off to another.
    final jobByWorkArea = <String, Job>{};
    final sharedWorkAreas = <String>{};
    for (final j in scheduleJobs) {
      final wa = workAreaByJobId[j.id]!;
      if (wa.isEmpty) continue;
      if (jobByWorkArea.containsKey(wa)) sharedWorkAreas.add(wa);
      jobByWorkArea[wa] = j;
    }
    sharedWorkAreas.forEach(jobByWorkArea.remove);

    // Track which schedule job IDs are claimed by existing tasks.
    final consumedJobIds = <String>{};

    Job? matchFor(DropsheetTask task) {
      final jobId = task.typeData['distributorJobId'] as String?;
      if (jobId == null) return null;
      // Match by job ID first, then by work area.
      final byJob = jobById[jobId];
      if (byJob != null) return byJob;
      final wa = task.typeData['workArea'] as String?;
      return (wa != null && wa.isNotEmpty) ? jobByWorkArea[wa] : null;
    }

    // A driver can't be dropped off: when a job's distributor has the Driver
    // role, the job becomes a Distribute task on that driver's own section.
    final sectionIdByDriverName = <String, String>{
      for (final s in day.sections)
        if (s.id != kUnassignedSectionId && s.driverName.trim().isNotEmpty)
          _normaliseName(s.driverName): s.id,
    };
    // A distributor missing from [distributors] (list still loading, or a
    // partial cache on another client) says nothing about their role — keep
    // the task's current type instead of flipping it back to a drop-off.
    DropsheetTaskType typeFor(Job job, DropsheetTaskType current) {
      final dist = byId[job.distributorId];
      if (dist == null) return current;
      return dist.role == DistributorRole.driver
          ? DropsheetTaskType.distribute
          : DropsheetTaskType.dropOff;
    }

    String? ownSectionIdFor(Job job) {
      final dist = byId[job.distributorId];
      if (dist == null || dist.role != DistributorRole.driver) return null;
      return sectionIdByDriverName[_normaliseName(dist.name)];
    }

    // One job-wide task per schedule job. A duplicate appears when the
    // dispatcher adds a drop-off by hand for a distributor the sync already
    // placed in "Unassigned stops" — both rows then showed the same name.
    // Keep the copy on a driver (it is the one being worked), else the first;
    // per-area pinned drop-offs are deliberate splits and never collapse.
    final keeperByJobId = <String, String>{};
    for (final section in day.sections) {
      final onDriver = section.id != kUnassignedSectionId;
      for (final task in section.tasks) {
        if (!_isScheduleSyncedType(task.type)) continue;
        if (task.typeData['workAreaPin'] == true) continue;
        final match = matchFor(task);
        if (match == null) continue;
        final current = keeperByJobId[match.id];
        if (current == null || (onDriver && current.startsWith('u:'))) {
          keeperByJobId[match.id] = '${onDriver ? 'd' : 'u'}:${task.id}';
        }
      }
    }

    // Distribute tasks found in "Unassigned stops" whose driver has a
    // section — moved there after Pass 1, keyed by target section id.
    final movesBySectionId = <String, List<DropsheetTask>>{};

    // ── Pass 1: update existing drop-off / distribute tasks in-place ──────
    // (Mandatory tasks and other task types are always kept.)
    // A pick-up's job can leave the day (deleted, moved) while its
    // distributor still works it: re-point the pick-up to another of their
    // jobs — the one dropped last on this run, else any. With none left it
    // goes, like the drop-off does. (Kept before, it stayed pinned on the
    // map and printed on the sheet while the panel hid it.)
    final jobsByDistributor = <String, List<Job>>{};
    for (final j in scheduleJobs) {
      jobsByDistributor.putIfAbsent(j.distributorId, () => []).add(j);
    }

    var updatedSections = day.sections.map((section) {
      final updatedTasks = <DropsheetTask>[];
      // A stop moved to its job's new point: the cached route line no
      // longer passes through it.
      var routeStale = false;
      final lastDropJobByDistributor = <String, String>{};
      for (final t in section.tasks) {
        if (!_isScheduleSyncedType(t.type)) continue;
        final job = jobById[t.typeData['distributorJobId']];
        if (job != null) lastDropJobByDistributor[job.distributorId] = job.id;
      }
      for (var task in section.tasks) {
        if (task.type == DropsheetTaskType.pickUp) {
          final jobId = task.typeData['distributorJobId'] as String?;
          if (jobId != null && !jobById.containsKey(jobId)) {
            final distributorId = task.typeData['distributorId'] as String?;
            final replacement = lastDropJobByDistributor[distributorId] ??
                jobsByDistributor[distributorId]?.first.id;
            if (replacement == null) {
              routeStale = true;
              continue;
            }
            task = task.copyWith(typeData: {
              ...task.typeData,
              'distributorJobId': replacement,
            }..remove('workAreaPin'));
          }
          final refreshed = _refreshPickUp(task, jobById, byId);
          if (refreshed.typeData['lat'] != task.typeData['lat'] ||
              refreshed.typeData['lng'] != task.typeData['lng'] ||
              refreshed.typeData['distributorJobId'] != jobId) {
            routeStale = true;
          }
          updatedTasks.add(refreshed);
          continue;
        }
        if (!_isScheduleSyncedType(task.type)) {
          updatedTasks.add(task);
          continue;
        }
        final jobId = task.typeData['distributorJobId'] as String?;
        if (jobId == null) {
          // Task that wasn't seeded from a schedule job — keep.
          updatedTasks.add(task);
          continue;
        }

        final match = matchFor(task);
        if (match == null) {
          // Job moved to another date or was deleted — drop the task so
          // the dropsheet always reflects the current schedule.
          continue;
        }
        if (task.typeData['workAreaPin'] != true &&
            keeperByJobId[match.id]?.substring(2) != task.id) {
          // Duplicate of a task kept elsewhere on the sheet.
          continue;
        }

        // Notes (`details`) are the user's — the sync never writes them. An
        // older build's auto-filled distributor name is left in place and
        // hidden by `DropsheetTask.notes`: rewriting it here would make old
        // and new clients overwrite each other on every snapshot.
        // Once reworded in the editor, the label / location / contact are the
        // user's too; a blanked field falls back to the generated value.
        String keep(String field, String edited, String generated) =>
            task.userEditedField(field) && edited.trim().isNotEmpty
                ? edited
                : generated;

        // Drop-off ↔ distribute follows the distributor's current role. The
        // label names the task type, so it is regenerated on a switch.
        final type = typeFor(match, task.type);
        final typeChanged = type != task.type;

        // Per-area drop-off (added manually for a specific work area): keep its
        // pinned work area + coordinate intact; only refresh the distributor's
        // name/phone so the row stays current. The job is still consumed so
        // Pass 2 doesn't re-add a default drop-off for it.
        if (task.typeData['workAreaPin'] == true) {
          consumedJobIds.add(match.id);
          final dist = byId[match.distributorId];
          final name = dist?.name ?? match.distributorId;
          final phone = dist?.phone1 ?? '';
          final pinnedArea = (task.typeData['workArea'] as String?) ?? '';
          final td = Map<String, dynamic>.from(task.typeData)
            ..['distributorJobId'] = match.id
            ..['distributorId'] = match.distributorId
            ..['distributorName'] = name
            ..[DropsheetTask.kPointOnlyKey] =
                DropsheetTask.isPointOnlyJob(match);
          updatedTasks.add(task.copyWith(
            type: type,
            job: typeChanged ? _scheduleTaskLabel(type, pinnedArea) : null,
            contact: keep('contact', task.contact, name),
            tel: keep('tel', task.tel, phone),
            typeData: td,
          ));
          continue;
        }

        consumedJobIds.add(match.id);
        final dist = byId[match.distributorId];
        final name = dist?.name ?? match.distributorId;
        final phone = dist?.phone1 ?? '';
        final wa = workAreaByJobId[match.id] ?? _workAreaText(match);

        // Rebuild typeData, preserving any custom drop-off lat/lng the user
        // placed unless the task migrated to a different job.
        var td = Map<String, dynamic>.from(task.typeData)
          ..['distributorJobId'] = match.id
          ..['distributorId'] = match.distributorId
          ..['distributorName'] = name
          ..['workArea'] = wa
          ..[DropsheetTask.kPointOnlyKey] = DropsheetTask.isPointOnlyJob(match);
        // Follows the job's point (dragged on any screen, any device); a
        // task migrated to a different job via work-area drops stale coords.
        if (match.dropOffPoint != null || jobId != match.id) {
          final moved = _withCoords(td, match.dropOffPoint);
          if (moved != null) {
            td = moved;
            routeStale = true;
          }
        }

        final generatedLabel = _scheduleTaskLabel(type, wa);
        // Builds without the distribute type relabel it "Drop off: …" on
        // every sync. Accept that wording (it is displayed as "Distribute")
        // rather than rewriting it back, so mixed clients stop fighting.
        final legacyLabel = type == DropsheetTaskType.distribute &&
            task.job == _scheduleTaskLabel(DropsheetTaskType.dropOff, wa);
        final updated = task.copyWith(
          type: type,
          job: typeChanged
              ? generatedLabel
              : (legacyLabel
                  ? task.job
                  : keep('job', task.job, generatedLabel)),
          location: keep('location', task.location, wa),
          contact: keep('contact', task.contact, name),
          tel: keep('tel', task.tel, phone),
          typeData: td,
        );

        final ownSectionId = ownSectionIdFor(match);
        if (section.id == kUnassignedSectionId && ownSectionId != null) {
          movesBySectionId.putIfAbsent(ownSectionId, () => []).add(updated);
          continue;
        }
        updatedTasks.add(updated);
      }
      return routeStale
          ? section.copyWith(tasks: updatedTasks, routePolyline: const [])
          : section.copyWith(tasks: updatedTasks);
    }).toList();

    // ── Pass 2: add genuinely new work areas ──────────────────────────────
    // Distribute tasks go straight to their driver's section; everything
    // else (and drivers without a section yet) lands in Unassigned.
    final newJobs =
        scheduleJobs.where((j) => !consumedJobIds.contains(j.id)).toList();
    final newUnassigned = <DropsheetTask>[];
    if (newJobs.isNotEmpty) {
      final newTasks = _buildDropOffTasksStatic(newJobs, byId);
      for (var i = 0; i < newJobs.length; i++) {
        final ownSectionId = ownSectionIdFor(newJobs[i]);
        if (ownSectionId != null) {
          movesBySectionId.putIfAbsent(ownSectionId, () => []).add(newTasks[i]);
        } else {
          newUnassigned.add(newTasks[i]);
        }
      }
    }

    if (movesBySectionId.isNotEmpty) {
      updatedSections = [
        for (final s in updatedSections)
          movesBySectionId.containsKey(s.id)
              ? s.copyWith(
                  tasks:
                      _insertBeforeAfternoon(s.tasks, movesBySectionId[s.id]!))
              : s,
      ];
    }

    List<DropsheetDriverSection> finalSections = updatedSections;
    if (newUnassigned.isNotEmpty) {
      final idx = finalSections.indexWhere((s) => s.id == kUnassignedSectionId);
      if (idx == -1) {
        finalSections = [
          DropsheetDriverSection(
            id: kUnassignedSectionId,
            driverId: kUnassignedSectionId,
            driverName: 'Unassigned stops',
            tasks: newUnassigned,
          ),
          ...finalSections,
        ];
      } else {
        finalSections = [
          for (var i = 0; i < finalSections.length; i++)
            i == idx
                ? finalSections[i].copyWith(
                    tasks: [...finalSections[i].tasks, ...newUnassigned])
                : finalSections[i],
        ];
      }
    }

    return day.copyWith(
        sections:
            _withJobCrews(finalSections, scheduleJobs, distributors).sections);
  }

  /// Stamps every Junk & Stuff / Happy Sun task in [sections] with who the
  /// schedule sends to its client on the day ([DropsheetTask.kWithKey],
  /// shown as "Team: …" in Details): the distributors whose schedule job on
  /// this date lists the task's client, in schedule row order.
  ///
  /// Tasks that already say the right thing are returned as they are, so
  /// [changed] is false when nothing needs saving. With no distributors
  /// known (list still loading) nothing is touched — names would vanish.
  static ({List<DropsheetDriverSection> sections, bool changed})
      _withJobCrews(List<DropsheetDriverSection> sections,
          List<Job> scheduleJobs, List<Distributor> distributors) {
    if (distributors.isEmpty) return (sections: sections, changed: false);
    final byId = {for (final d in distributors) d.id: d};

    // Client key → the distributors on that client's schedule jobs today.
    final crewByClient = <String, List<Distributor>>{};
    for (final job in scheduleJobs) {
      final dist = byId[job.distributorId];
      if (dist == null) continue;
      for (final key in job.clients.map(jobListClientKey).toSet()) {
        if (key.isEmpty) continue;
        final crew = crewByClient.putIfAbsent(key, () => []);
        if (!crew.any((d) => d.id == dist.id)) crew.add(dist);
      }
    }

    var changed = false;
    final out = [
      for (final section in sections)
        () {
          var sectionChanged = false;
          final tasks = [
            for (final task in section.tasks)
              () {
                final jobType = task.typeData['jobType'] as String?;
                final client = (task.typeData['client'] as String?) ?? '';
                if (jobType == null ||
                    client.trim().isEmpty ||
                    task.isDistributorTask ||
                    !ClientAddressPin.isCallOutJobType(jobType)) {
                  return task;
                }
                final crew = [
                  ...?crewByClient[jobListClientKey(client)],
                ]..sort((a, b) {
                    final byIndex = a.index.compareTo(b.index);
                    return byIndex != 0 ? byIndex : a.name.compareTo(b.name);
                  });
                final names = <String>[
                  for (final d in crew)
                    if (d.name.trim().isNotEmpty) d.name.trim(),
                ];
                if (listEquals(names, task.withNames) &&
                    (names.isNotEmpty ||
                        !task.typeData.containsKey(DropsheetTask.kWithKey))) {
                  return task;
                }
                sectionChanged = true;
                final td = Map<String, dynamic>.from(task.typeData);
                if (names.isEmpty) {
                  td.remove(DropsheetTask.kWithKey);
                } else {
                  td[DropsheetTask.kWithKey] = names;
                }
                return task.copyWith(typeData: td);
              }(),
          ];
          if (!sectionChanged) return section;
          changed = true;
          return section.copyWith(tasks: tasks);
        }(),
    ];
    return (sections: out, changed: changed);
  }

  @visibleForTesting
  static List<DropsheetDriverSection> withJobCrewsForTest(
          List<DropsheetDriverSection> sections,
          List<Job> scheduleJobs,
          List<Distributor> distributors) =>
      _withJobCrews(sections, scheduleJobs, distributors).sections;

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

  /// Creates a single pick-up task per **distributor** that has assigned
  /// drop-offs but no matching pick-up yet anywhere on the day's dropsheet.
  /// When a distributor has multiple drop-offs (e.g. several work areas), the
  /// one pick-up is collected at their **last** drop-off in route order.
  /// The unassigned bucket is ignored until those stops are placed on drivers.
  Future<DropsheetPickupSyncResult> syncPickupsFromDropOffs(
      {bool reversed = true}) async {
    _requireDayReady();
    // Existing pick-ups anywhere on the day, keyed by distributor — so at most
    // one pick-up per distributor is ever created.
    final existingPickupKeys = <String>{};
    for (final section in _day.sections) {
      for (final task in section.tasks) {
        if (task.type != DropsheetTaskType.pickUp) continue;
        final key = _distributorGroupKey(task);
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
      // Own transport people come back by themselves — nobody collects them.
      if (section.isOwnTransport) return section;

      // Pick-ups already in this section, keyed by distributor.
      final localPickupsByKey = <String, DropsheetTask>{};
      for (final task in section.tasks) {
        if (task.type != DropsheetTaskType.pickUp) continue;
        final key = _distributorGroupKey(task);
        if (key != null) localPickupsByKey.putIfAbsent(key, () => task);
      }

      // The LAST drop-off (in section/route order) per distributor — the single
      // pick-up for that distributor is built from it.
      final lastDropByDist = <String, ({DropsheetTask task, int index})>{};
      for (var i = 0; i < section.tasks.length; i++) {
        final task = section.tasks[i];
        if (task.type != DropsheetTaskType.dropOff) continue;
        dropOffCount++;
        final key = _distributorGroupKey(task);
        if (key == null) continue;
        lastDropByDist[key] = (task: task, index: i);
      }

      // Order distributors by their last drop-off position; `reversed` flips it
      // (default: pick up in the reverse of drop order).
      var groups = lastDropByDist.entries.toList()
        ..sort((a, b) => a.value.index.compareTo(b.value.index));
      if (reversed) groups = groups.reversed.toList();

      final orderedPickups = <DropsheetTask>[];
      final movedPickupIds = <String>{};
      for (final entry in groups) {
        final distKey = entry.key;
        final lastDrop = entry.value.task;

        final localPickup = localPickupsByKey[distKey];
        if (localPickup != null) {
          orderedPickups.add(localPickup);
          movedPickupIds.add(localPickup.id);
          skippedCount++;
          continue;
        }
        if (existingPickupKeys.contains(distKey)) {
          skippedCount++;
          continue;
        }
        orderedPickups.add(_buildPickUpTaskFromDropOff(
          lastDrop,
          timestamp: timestamp,
          sequence: sequence,
        ));
        sequence++;
        existingPickupKeys.add(distKey);
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
      // The divider is a purely visual marker — it carries no time or location.
      // Afternoon pick-up ETAs are anchored to the Arrive task's target time
      // and computed backwards (see DropsheetRoutePlanner).
      final hasDivider = nonTrailing.any((t) =>
          t.type == DropsheetTaskType.leave &&
          t.typeData['isPickupDivider'] == true);
      final divider = hasDivider
          ? null
          : DropsheetTask(
              id: '${section.id}_pickup_div_$timestamp',
              type: DropsheetTaskType.leave,
              job: 'Leave',
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

  /// Task types the schedule sync creates and keeps in step with the
  /// schedule (one per schedule job).
  static bool _isScheduleSyncedType(DropsheetTaskType t) =>
      t == DropsheetTaskType.dropOff || t == DropsheetTaskType.distribute;

  static String _scheduleTaskLabel(DropsheetTaskType type, String workArea) {
    final base = type.displayName;
    return workArea.isEmpty ? base : '$base: $workArea';
  }

  /// The job's working areas as one label, without the "To be assigned"
  /// placeholder — an unnamed point job reads as just "Drop off" (and its
  /// Location shows the street corner) rather than "Drop off: To be assigned".
  static String _workAreaText(Job j) => j.workingAreas
      .map((a) => a.trim())
      .where((a) => a.isNotEmpty && !DropsheetTask.isPlaceholderArea(a))
      .join(', ');

  /// Keeps a pick-up in step with its schedule job. Pick-ups are copied from
  /// a drop-off once (Sync pickups), so without this they kept whatever the
  /// job said then — "Pick up: To be assigned" long after the job was named,
  /// and no point-only flag, so no street corner either. Only descriptive
  /// fields refresh: the pick-up's position, coordinates and any wording the
  /// user changed stay as they are, and a pick-up whose job is gone is kept.
  static DropsheetTask _refreshPickUp(DropsheetTask task,
      Map<String, Job> jobById, Map<String, Distributor> byId) {
    final job = jobById[task.typeData['distributorJobId']];
    if (job == null) return task;
    final pinned = task.typeData['workAreaPin'] == true;
    final area = pinned
        ? ((task.typeData['workArea'] as String?) ?? '')
        : _workAreaText(job);
    final name = byId[job.distributorId]?.name ??
        (task.typeData['distributorName'] as String?) ??
        job.distributorId;
    final label = _scheduleTaskLabel(DropsheetTaskType.pickUp, area);
    // Collected where the job's pick-up (else drop-off) point now is — the
    // spot the day planner pins it — unless it is a per-area pin.
    final point = pickUpPointFor(job);
    final base = (pinned || point == null)
        ? task.typeData
        : (_withCoords(task.typeData, point) ?? task.typeData);
    return task.copyWith(
      job: task.userEditedField('job') && task.job.trim().isNotEmpty
          ? task.job
          : label,
      location:
          task.userEditedField('location') && task.location.trim().isNotEmpty
              ? task.location
              : area,
      typeData: {
        ...base,
        'distributorId': job.distributorId,
        'distributorName': name,
        'workArea': area,
        DropsheetTask.kPointOnlyKey: DropsheetTask.isPointOnlyJob(job),
      },
    );
  }

  static String _normaliseName(String v) =>
      v.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Inserts [tasks] into a driver's list ahead of the afternoon: before the
  /// pick-up divider when there is one, else before the trailing Arrive.
  static List<DropsheetTask> _insertBeforeAfternoon(
      List<DropsheetTask> existing, List<DropsheetTask> tasks) {
    var at = existing.indexWhere((t) =>
        t.type == DropsheetTaskType.leave &&
        t.typeData['isPickupDivider'] == true);
    if (at == -1) at = existing.indexWhere(DropsheetTask.isTrailing);
    if (at == -1) return [...existing, ...tasks];
    return [...existing.sublist(0, at), ...tasks, ...existing.sublist(at)];
  }

  /// Builds one schedule-synced task per job, index-aligned with [jobs]:
  /// a drop-off, or a Distribute task when the distributor is a driver.
  static List<DropsheetTask> _buildDropOffTasksStatic(
      List<Job> jobs, Map<String, Distributor> byId) {
    final out = <DropsheetTask>[];
    final timestamp = DateTime.now().microsecondsSinceEpoch;
    for (final j in jobs) {
      final dist = byId[j.distributorId];
      final name = dist?.name ?? j.distributorId;
      final phone = dist?.phone1 ?? '';
      final wa = _workAreaText(j);
      final type = dist?.role == DistributorRole.driver
          ? DropsheetTaskType.distribute
          : DropsheetTaskType.dropOff;
      out.add(
        DropsheetTask(
          id: 't_dropoff_${j.id}_${timestamp}_${out.length}',
          type: type,
          job: _scheduleTaskLabel(type, wa),
          location: wa,
          contact: name,
          tel: phone,
          typeData: {
            'distributorJobId': j.id,
            'distributorId': j.distributorId,
            'distributorName': name,
            'workArea': wa,
            DropsheetTask.kPointOnlyKey: DropsheetTask.isPointOnlyJob(j),
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
      details: dropOff.notes,
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

  /// Distributor-level grouping key (ignores work area / job) so all of a
  /// distributor's drop-offs collapse to one pick-up. Falls back to the
  /// distributor name / contact for hand-entered tasks without an id.
  String? _distributorGroupKey(DropsheetTask task) {
    final distributorId = _normaliseTaskKeyPart(task.typeData['distributorId']);
    if (distributorId.isNotEmpty) return 'dist:$distributorId';
    final name = _normaliseTaskKeyPart(task.typeData['distributorName']);
    if (name.isNotEmpty) return 'distname:$name';
    final contact = _normaliseTaskKeyPart(task.contact);
    if (contact.isNotEmpty) return 'distname:$contact';
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

  /// [undoLabel] makes the save a step in this day's undo history (a user
  /// edit). [backgroundFollowUp] marks a derived change (intersection names,
  /// refreshed coordinates) that joins the steps it follows. Saves with
  /// neither — schedule / Job List syncs — are not undoable.
  Future<void> _save(DropsheetDay updated,
      {bool skipIfUnchanged = false,
      String? undoLabel,
      String? coalesceKey,
      bool backgroundFollowUp = false}) async {
    if (skipIfUnchanged &&
        _sectionsEquivalent(_day.sections, updated.sections)) {
      return;
    }
    final previous = _day;
    _day = updated;
    notifyListeners();
    if (undoLabel != null) {
      _recordUndo(undoLabel, previous, updated, coalesceKey: coalesceKey);
    } else if (backgroundFollowUp) {
      for (final step in _undoSteps) {
        if (step.dayId == updated.docId) step.fold(previous, updated);
      }
    }
    await _service.saveDay(updated);
  }

  // ── Undo / Redo (per day) ─────────────────────────────────────────────────

  /// This day's undo history key.
  UndoKey get undoKey =>
      UndoKey(UndoScope.dropsheet, DropsheetDay.docIdFor(_date));

  /// Recorded steps still reachable from the histories, for folding.
  final List<DropsheetStep> _undoSteps = [];

  void _recordUndo(String label, DropsheetDay before, DropsheetDay after,
      {String? coalesceKey}) {
    final ref = _ref;
    if (ref == null || before.docId != after.docId) return;
    final history =
        ref.read(undoHistoryRiverpod(UndoKey(UndoScope.dropsheet, after.docId)));
    if (history.isApplying) return;
    if (changedSectionIds(before, after).isEmpty) return;
    final step = DropsheetStep(after.docId, before, after);
    _undoSteps.add(step);
    if (_undoSteps.length > kUndoDepth * 4) _undoSteps.removeAt(0);
    history.record(_undoEntry(label, step, coalesceKey));
  }

  UndoEntry _undoEntry(String label, DropsheetStep step, String? coalesceKey) {
    final entry = UndoEntry(
      label: label,
      coalesceKey: coalesceKey,
      mergeOnto: coalesceKey == null
          ? null
          : (previous) {
              final older = _undoStepFor[previous];
              if (older == null) return _undoEntry(label, step, coalesceKey);
              final merged = DropsheetStep(step.dayId, older.before, step.after);
              _undoSteps
                ..remove(older)
                ..remove(step)
                ..add(merged);
              return _undoEntry(label, merged, coalesceKey);
            },
      undo: () => _applyUndo(step, toBefore: true),
      redo: () => _applyUndo(step, toBefore: false),
    );
    _undoStepFor[entry] = step;
    return entry;
  }

  final Expando<DropsheetStep> _undoStepFor = Expando('dropsheetUndoStep');

  Future<void> _applyUndo(DropsheetStep step, {required bool toBefore}) async {
    if (_day.docId != step.dayId) {
      throw const UndoConflict('that day is no longer open');
    }
    final restored = restoreSections(
      current: _day,
      expected: toBefore ? step.after : step.before,
      target: toBefore ? step.before : step.after,
      ids: changedSectionIds(step.before, step.after),
    );
    await _save(restored);
  }

  /// Writes an earlier saved version of [date]'s sheet back as the live one
  /// (Version history dialog; versions come from Firestore PITR via the
  /// `dropsheetHistory` function). A deliberate user action, so it is
  /// allowed on archived days too.
  Future<void> restoreVersion(DateTime date, Map<String, dynamic> data) async {
    final normalised = DateTime(date.year, date.month, date.day);
    final day = DropsheetDay.fromMap(DropsheetDay.docIdFor(normalised), data);
    if (normalised == _date) {
      await _save(day);
    } else {
      await _service.saveDay(day);
    }
  }

  /// Where [job]'s pick-up happens: its own pick-up point, else where it was
  /// dropped off — the same fallback the day planner pins it at.
  static LatLng? pickUpPointFor(Job job) =>
      job.pickUpPoint ?? job.dropOffPoint;

  /// [day] with every task tied to [job]'s own points moved to them —
  /// drop-off / distribute tasks to [Job.dropOffPoint], pick-ups to
  /// [pickUpPointFor] — or null when nothing moved. Per-area pins
  /// (`workAreaPin`) keep their own coordinate. A moved stop loses its ETA
  /// and leg time and its section its cached route line, so the sheet shows
  /// the route needs recalculating instead of wrong timings.
  static DropsheetDay? _withJobCoords(DropsheetDay day, Job job) {
    final dropOff = job.dropOffPoint;
    final pickUp = pickUpPointFor(job);
    var changed = false;
    final sections = day.sections.map((s) {
      var sectionChanged = false;
      final tasks = s.tasks.map((t) {
        if (t.typeData['distributorJobId'] != job.id) return t;
        if (t.typeData['workAreaPin'] == true) return t;
        final LatLng? target;
        if (t.type == DropsheetTaskType.pickUp) {
          target = pickUp;
        } else if (_isScheduleSyncedType(t.type)) {
          target = dropOff;
        } else {
          return t;
        }
        final td = _withCoords(t.typeData, target);
        if (td == null) return t;
        sectionChanged = true;
        return t.copyWith(typeData: td);
      }).toList();
      if (!sectionChanged) return s;
      changed = true;
      return s.copyWith(tasks: tasks, routePolyline: const []);
    }).toList();
    return changed ? day.copyWith(sections: sections) : null;
  }

  /// [typeData] moved to [point] (null clears it), with the stale ETA and
  /// leg time dropped; null when it is already there.
  static Map<String, dynamic>? _withCoords(
      Map<String, dynamic> typeData, LatLng? point) {
    final lat = (typeData['lat'] as num?)?.toDouble();
    final lng = (typeData['lng'] as num?)?.toDouble();
    if (point == null) {
      if (lat == null && lng == null) return null;
    } else if (lat != null &&
        lng != null &&
        (lat - point.latitude).abs() < 1e-7 &&
        (lng - point.longitude).abs() < 1e-7) {
      return null;
    }
    final td = Map<String, dynamic>.from(typeData)
      ..remove('eta')
      ..remove('legDurationS')
      ..remove(DropsheetTask.kAppointmentWaitKey)
      ..remove(DropsheetTask.kAppointmentLateKey);
    if (point == null) {
      td
        ..remove('lat')
        ..remove('lng');
    } else {
      td
        ..['lat'] = point.latitude
        ..['lng'] = point.longitude;
    }
    return td;
  }

  /// Moves the open sheet's tasks for [job] to the job's current drop-off /
  /// pick-up points straight away, so the route optimiser, map links and
  /// PDF never read the old spot after a pin is dragged on any screen.
  ///
  /// Skipped while a historical day is open (moving a pin today must not
  /// rewrite an archived sheet's coordinates, ETAs and route) and before the
  /// first server snapshot (saving over a stale cached copy is the
  /// 2026-10-13 wipe) — the caller then uses [refreshCoordsFromJobOneShot].
  Future<void> refreshCoordsFromJob(Job job) => refreshCoordsFromJobs([job]);

  /// [refreshCoordsFromJob] for several jobs in one save.
  Future<void> refreshCoordsFromJobs(List<Job> jobs) async {
    if (isHistorical(_date) || !_dayReady) return;
    final next = _withJobsCoords(_day, jobs);
    if (next == null) return;
    await _save(next, backgroundFollowUp: true);
    unawaited(resolveIntersections());
  }

  /// [_withJobCoords] applied for each of [jobs]; null when nothing moved.
  static DropsheetDay? _withJobsCoords(DropsheetDay day, List<Job> jobs) {
    var current = day;
    var changed = false;
    for (final job in jobs) {
      final next = _withJobCoords(current, job);
      if (next == null) continue;
      current = next;
      changed = true;
    }
    return changed ? current : null;
  }

  /// [refreshCoordsFromJob] for a sheet that isn't open (or not loaded yet):
  /// patched in a transaction against the server copy. Offline, it is
  /// skipped; the live sync or a manual Sync picks the move up later.
  static Future<void> refreshCoordsFromJobOneShot(Job job,
          {DropsheetService? service}) =>
      refreshCoordsFromJobsOneShot([job], service: service);

  /// [refreshCoordsFromJobOneShot] for several jobs: one transaction per day.
  static Future<void> refreshCoordsFromJobsOneShot(List<Job> jobs,
      {DropsheetService? service}) async {
    final byDay = <String, List<Job>>{};
    for (final j in jobs) {
      if (isHistorical(j.date)) continue;
      byDay.putIfAbsent(DropsheetDay.docIdFor(j.date), () => []).add(j);
    }
    final svc = service ?? DropsheetService();
    for (final dayJobs in byDay.values) {
      try {
        await svc.updateDayTxn(
            dayJobs.first.date, (day) => _withJobsCoords(day, dayJobs));
      } catch (e) {
        debugPrint('[DropsheetProvider] coords for '
            '${dayJobs.map((j) => j.id).join(', ')} not saved: $e');
      }
    }
  }

  @visibleForTesting
  static DropsheetDay? withJobCoordsForTest(DropsheetDay day, Job job) =>
      _withJobCoords(day, job);

  /// Add a driver section seeded with the 3 mandatory tasks.
  Future<void> addDriverSection(
    Driver driver, {
    VehicleType? vehicle,
    TrailerType? trailer,
  }) async {
    if (_day.sections.any((s) => s.driverId == driver.id)) return;
    final taskConfig = _ref?.read(dropsheetTaskConfigRiverpod);
    final depot = taskConfig?.depot;
    final packDefault =
        taskConfig?.configFor(DropsheetTaskType.pack).defaultDetails;
    final section = DropsheetDriverSection.create(
      driverId: driver.id,
      driverName: driver.name,
      vehicle: vehicle ?? driver.defaultVehicle,
      trailer: trailer ?? driver.defaultTrailer,
      depot: depot,
      packDetails: packDefault?.isNotEmpty == true ? packDefault : null,
    );
    await _save(_day.copyWith(sections: [..._day.sections, section]),
        undoLabel: 'Add ${driver.name}');
  }

  /// Adds the "Own transport" list (once per day) for distributors who walk
  /// or take a train, bus or taxi from the office. Drag their drop-offs in.
  Future<void> addOwnTransportSection() async {
    if (_day.sections.any((s) => s.isOwnTransport)) return;
    await _save(
        _day.copyWith(sections: [
          ..._day.sections,
          DropsheetDriverSection.ownTransport(),
        ]),
        undoLabel: 'Add $kOwnTransportLabel');
  }

  Future<void> removeDriverSection(String sectionId) async {
    final removed = _day.sections.where((s) => s.id == sectionId).firstOrNull;
    final next = _day.sections.where((s) => s.id != sectionId).toList();
    await _save(_day.copyWith(sections: next),
        undoLabel: 'Remove ${removed?.driverName ?? 'driver'}');
  }

  Future<void> updateDriverSection(DropsheetDriverSection updated) async {
    final next =
        _day.sections.map((s) => s.id == updated.id ? updated : s).toList();
    await _save(_day.copyWith(sections: next),
        undoLabel: 'Edit ${updated.driverName}',
        coalesceKey: 'section:${updated.id}');
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
    await _save(_day.copyWith(sections: next), undoLabel: 'Add task');
    if (newTask.isDistributorTask) unawaited(resolveIntersections());
  }

  Future<void> updateTask(String sectionId, DropsheetTask task) async {
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      return s.copyWith(
        tasks: s.tasks.map((t) => t.id == task.id ? task : t).toList(),
      );
    }).toList();
    // Typing into a task saves on every change; a burst is one step.
    await _save(_day.copyWith(sections: next),
        undoLabel: 'Edit task', coalesceKey: 'task:$sectionId:${task.id}');
    if (task.isDistributorTask) unawaited(resolveIntersections());
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
    await _save(_day.copyWith(sections: next), undoLabel: 'Move task pin');
  }

  /// [updateTaskCoords] for several tasks (keyed by task id → section id),
  /// all moved to one point, in a single save and Undo step.
  Future<void> updateTasksCoords(
      Map<String, String> sectionIdByTaskId, double lat, double lng) async {
    if (sectionIdByTaskId.isEmpty) return;
    final next = _day.sections.map((s) {
      if (!sectionIdByTaskId.containsValue(s.id)) return s;
      return s.copyWith(
        tasks: s.tasks.map((t) {
          if (sectionIdByTaskId[t.id] != s.id) return t;
          final td = Map<String, dynamic>.from(t.typeData)
            ..['lat'] = lat
            ..['lng'] = lng;
          return t.copyWith(typeData: td);
        }).toList(),
      );
    }).toList();
    await _save(_day.copyWith(sections: next), undoLabel: 'Move task pins');
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

      // Afternoon tasks (after separator) are anchored to the Arrive target
      // time, not the morning leave time — leave them unchanged here.
      if (separatorIdx != -1 && i > separatorIdx) {
        updatedTasks.add(task);
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
        // A booked move starts with the loading: wait for it if early.
        final met = meetAppointment(clock.add(Duration(seconds: loadLegS)),
            hhmmToMinutes(task.appointmentTime));
        clock = met.start;
        final loadEta = fmtHHmm(clock);
        clock = clock.add(Duration(minutes: svc ~/ 2));
        clock = clock.add(Duration(seconds: offLegS));
        final offEta = fmtHHmm(clock);
        clock = clock.add(Duration(minutes: svc - (svc ~/ 2)));
        final newData = Map<String, dynamic>.from(task.typeData)
          ..['loadingEta'] = loadEta
          ..['offloadEta'] = offEta
          ..['eta'] = loadEta;
        _stampAppointmentTiming(newData,
            wait: met.waitMinutes, late: met.lateMinutes);
        updatedTasks.add(task.copyWith(startTime: loadEta, typeData: newData));
      } else {
        final legS = (task.typeData['legDurationS'] as num?)?.toInt() ?? 0;
        if (legS == 0) {
          updatedTasks.add(task);
          continue;
        }
        // Work starts on arrival, or at the booked time if that is later.
        final met = meetAppointment(clock.add(Duration(seconds: legS)),
            hhmmToMinutes(task.appointmentTime));
        clock = met.start;
        final eta = fmtHHmm(clock);
        clock = clock.add(Duration(minutes: serviceMinutes(task)));
        final newData = Map<String, dynamic>.from(task.typeData)..['eta'] = eta;
        _stampAppointmentTiming(newData,
            wait: met.waitMinutes, late: met.lateMinutes);
        updatedTasks.add(task.copyWith(startTime: eta, typeData: newData));
      }
    }

    // Apply return-leg ETA to the arrive task using its stored leg duration.
    // Skipped when a separator exists: the afternoon leg (and therefore the
    // depot arrival) is anchored to the Arrive task's user-specified target
    // time, not derived from the morning leave time. The afternoon is
    // recomputed separately by [recalculateAfternoonFromArrive].
    final withArrive = updatedTasks.map((task) {
      if (task.type != DropsheetTaskType.arrive) return task;
      if (separatorIdx != -1) return task;
      final legS = (task.typeData['legDurationS'] as num?)?.toInt() ?? 0;
      if (legS == 0) return task;
      final arriveEta = fmtHHmm(clock.add(Duration(seconds: legS)));
      final newData = Map<String, dynamic>.from(task.typeData)
        ..['eta'] = arriveEta;
      // The Arrive time stays the target; the morning return is its ETA.
      return task.copyWith(startTime: _arriveTarget(task), typeData: newData);
    }).toList();

    // When a separator exists the afternoon tasks are left untouched here —
    // changing the morning departure does not move the afternoon pick-ups,
    // which are pinned backwards from the Arrive target time.
    final finalTasks = withArrive;

    final updatedSections = [
      ..._day.sections.sublist(0, sectionIndex),
      section.copyWith(tasks: finalTasks),
      ..._day.sections.sublist(sectionIndex + 1),
    ];

    debugPrint('[Dropsheet] recalculateETAsFromLegs section=$sectionId '
        'leaveTime=$startTime hasSeparator=${separatorIdx != -1}');

    await _save(_day.copyWith(sections: updatedSections),
        undoLabel: 'Recalculate ETAs');
  }

  /// Recomputes the afternoon (post-separator) pick-up ETAs by walking
  /// **backwards** from the Arrive task's target [arriveTime], using each
  /// stop's stored leg duration (`typeData['legDurationS']`) and service
  /// minutes. Each stop's `startTime` becomes the time the driver must reach
  /// it so they get back to the office at [arriveTime].
  ///
  /// Runs entirely offline (no Directions API call) by replaying stored legs.
  /// Only applies when the section has a pickup separator. When no leg data is
  /// stored yet (the route hasn't been calculated), only the Arrive task's
  /// time is pinned and the pick-up ETAs are left untouched.
  Future<void> recalculateAfternoonFromArrive(
    String sectionId,
    String arriveTime,
    int Function(DropsheetTask) serviceMinutes,
  ) async {
    final sectionIndex = _day.sections.indexWhere((s) => s.id == sectionId);
    if (sectionIndex == -1) return;
    final section = _day.sections[sectionIndex];

    final separatorIdx = section.tasks.indexWhere((t) =>
        t.type == DropsheetTaskType.leave &&
        t.typeData['isPickupDivider'] == true);
    if (separatorIdx == -1) return;

    final arriveTask = section.tasks
        .where((t) => t.type == DropsheetTaskType.arrive)
        .firstOrNull;
    // The return leg (last pick-up → office) is stored on the Arrive task.
    final returnLegS =
        (arriveTask?.typeData['legDurationS'] as num?)?.toInt() ?? 0;

    final parts = arriveTime.split(':');
    final h = int.tryParse(parts.elementAtOrNull(0) ?? '') ?? 17;
    final m = int.tryParse(parts.elementAtOrNull(1) ?? '') ?? 30;

    // The afternoon run in order — a furniture move is two stops (loading,
    // then offload) — timed back from the Arrive target, earlier if that
    // would miss a booking (see [timeRunToArrive]).
    final runTasks = <DropsheetTask>[];
    final runStops = <TimedStop>[];
    var hasLegs = returnLegS != 0;
    for (var i = separatorIdx + 1; i < section.tasks.length; i++) {
      final task = section.tasks[i];
      if (task.isMandatory) continue; // the Arrive task itself
      if (task.typeData['isPickupDivider'] == true) continue;
      final svc = serviceMinutes(task);
      final booked = hhmmToMinutes(task.appointmentTime);
      runTasks.add(task);
      if (task.type == DropsheetTaskType.furnitureMove) {
        final loadLegS =
            (task.typeData['loadingLegDurationS'] as num?)?.toInt() ?? 0;
        final offLegS =
            (task.typeData['offloadLegDurationS'] as num?)?.toInt() ?? 0;
        if (loadLegS != 0 || offLegS != 0) hasLegs = true;
        runStops
          ..add((legSeconds: loadLegS, serviceMinutes: svc ~/ 2,
              appointment: booked))
          ..add((legSeconds: offLegS, serviceMinutes: svc - (svc ~/ 2),
              appointment: null));
      } else {
        final legS = (task.typeData['legDurationS'] as num?)?.toInt() ?? 0;
        if (legS != 0) hasLegs = true;
        runStops.add((legSeconds: legS, serviceMinutes: svc,
            appointment: booked));
      }
    }
    final times =
        timeRunToArrive(runStops, (h * 60 + m) * 60, returnLegS);

    final etaUpdates = <String, Map<String, String>>{}; // taskId -> field->eta
    final timingByTask = <String, ({int wait, int late})>{};
    var k = 0;
    for (final task in runTasks) {
      if (task.type == DropsheetTaskType.furnitureMove) {
        final loadEta = secondsToHHmm(times.startSeconds[k]);
        final offEta = secondsToHHmm(times.startSeconds[k + 1]);
        etaUpdates[task.id] = {
          'eta': loadEta,
          'offloadEta': offEta,
          'loadingEta': loadEta,
        };
        timingByTask[task.id] =
            (wait: times.waitMinutes[k], late: times.lateMinutes[k]);
        k += 2;
      } else {
        etaUpdates[task.id] = {'eta': secondsToHHmm(times.startSeconds[k])};
        timingByTask[task.id] =
            (wait: times.waitMinutes[k], late: times.lateMinutes[k]);
        k += 1;
      }
    }
    // Back at the office: the target, unless a booking holds the driver up.
    final backAt =
        returnLegS == 0 ? arriveTime : secondsToHHmm(times.endSeconds);

    final applyEtas = hasLegs;
    final updatedTasks = section.tasks.map((task) {
      // The Arrive time is the target (kept); its ETA is when he's back.
      if (task.type == DropsheetTaskType.arrive) {
        final td = Map<String, dynamic>.from(task.typeData)
          ..['eta'] = applyEtas ? backAt : arriveTime;
        return task.copyWith(startTime: arriveTime, typeData: td);
      }
      if (!applyEtas) return task;
      final fields = etaUpdates[task.id];
      if (fields == null) return task;
      final td = Map<String, dynamic>.from(task.typeData);
      fields.forEach((k, v) => td[k] = v);
      final timing = timingByTask[task.id];
      _stampAppointmentTiming(td, wait: timing?.wait, late: timing?.late);
      return task.copyWith(
        startTime: fields['eta'] ?? task.startTime,
        typeData: td,
      );
    }).toList();

    debugPrint('[Dropsheet] recalculateAfternoonFromArrive section=$sectionId '
        'arrive=$arriveTime hasLegs=$hasLegs');

    final updatedSections = [
      ..._day.sections.sublist(0, sectionIndex),
      section.copyWith(tasks: updatedTasks),
      ..._day.sections.sublist(sectionIndex + 1),
    ];
    await _save(_day.copyWith(sections: updatedSections),
        undoLabel: 'Recalculate afternoon');
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
    // A morning edit stops at the "Leave and start pickups" divider: the
    // afternoon is worked back from the Arrive time, not from the morning.
    bool stopped = false;
    final next = _day.sections.map((s) {
      if (s.id != sectionId) return s;
      final tasks = s.tasks.map((t) {
        if (!found) {
          if (t.id == taskId) found = true;
          return t;
        }
        if (stopped) return t;
        if (t.typeData['isPickupDivider'] == true) {
          stopped = true;
          return t;
        }
        // The Arrive time is the target: only its ETA (when the driver is
        // back) moves.
        if (t.type == DropsheetTaskType.arrive) {
          final eta = t.typeData['eta'];
          final moved =
              eta is String ? _addMinutesToHHmm(eta, deltaMinutes) : null;
          if (moved == null) return t;
          return t.copyWith(typeData: {...t.typeData, 'eta': moved});
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
    await _save(_day.copyWith(sections: next),
        undoLabel: 'Shift start times');
  }

  /// The Arrive task's target time: its own, else the 17:30 default.
  static String _arriveTarget(DropsheetTask arrive) =>
      arrive.startTime.trim().isNotEmpty ? arrive.startTime : '17:30';

  /// Records in [typeData] how long the driver waits for a stop's booked
  /// time, or how late he is for it (cleared when neither).
  static void _stampAppointmentTiming(Map<String, dynamic> typeData,
      {int? wait, int? late}) {
    if (wait != null && wait > 0) {
      typeData[DropsheetTask.kAppointmentWaitKey] = wait;
    } else {
      typeData.remove(DropsheetTask.kAppointmentWaitKey);
    }
    if (late != null && late > 0) {
      typeData[DropsheetTask.kAppointmentLateKey] = late;
    } else {
      typeData.remove(DropsheetTask.kAppointmentLateKey);
    }
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
    await _save(_day.copyWith(sections: next),
        undoLabel: 'Remove task');
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
  /// `startTime`; for furniture-move tasks it is the loading arrival — when
  /// the driver must be at the first address. The offload arrival is kept
  /// in `typeData['offloadEta']`.
  Future<void> applyOptimizedRoute({
    required String sectionId,
    required List<String> taskOrder,
    required Map<String, String> arrivalByTaskKey,
    required Map<String, Map<String, dynamic>> legByTaskKey,
    required List<dynamic> polyline, // List<LatLng>
    required double totalDistanceMeters,
    required int totalDurationSeconds,
    Map<String, int> waitByTaskKey = const {},
    Map<String, int> lateByTaskKey = const {},
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
        // The Arrive time is the target the afternoon is worked back from
        // (17:30 unless changed) — never a result. The calculated return is
        // its ETA. Writing the morning return into it (a run with no
        // pick-ups yet) made the afternoon later anchor to e.g. 12:10.
        return t.copyWith(
          startTime: _arriveTarget(t),
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
        final taskEta = singleEta ?? loadEta ?? offEta;
        if (loadEta != null) newTypeData['loadingEta'] = loadEta;
        if (offEta != null) newTypeData['offloadEta'] = offEta;
        if (taskEta != null) newTypeData['eta'] = taskEta;
        // Waiting for / late for a booked time (at the stop the booking is
        // for: the single stop, or a move's loading).
        _stampAppointmentTiming(
          newTypeData,
          wait: waitByTaskKey['${id}__single'] ??
              waitByTaskKey['${id}__loading'],
          late: lateByTaskKey['${id}__single'] ??
              lateByTaskKey['${id}__loading'],
        );

        final legSingle = legByTaskKey['${id}__single'];
        final legOff = legByTaskKey['${id}__offload'];
        final legLoad = legByTaskKey['${id}__loading'];
        // The leg that brings the driver to this task.
        final leg = legSingle ?? legLoad ?? legOff;
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

    await _save(_day.copyWith(sections: next),
        undoLabel: 'Optimise route');
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

    await _save(_day.copyWith(sections: sections),
        undoLabel: 'Move task');
  }

  /// Moves [taskIds] (from whichever sections hold them) onto
  /// [toSectionId], straight after [afterTaskId] — so stops sharing a drop
  /// point sit together in the driver's run — or before the trailing task
  /// when [afterTaskId] isn't there; or straight before [beforeTaskId]
  /// (a job site moving up the run). One Undo step.
  Future<void> moveTasksTogether(List<String> taskIds, String toSectionId,
      {String? afterTaskId, String? beforeTaskId, String? undoLabel}) async {
    final ids = taskIds.toSet();
    final moving = <DropsheetTask>[
      for (final s in _day.sections)
        for (final t in s.tasks)
          if (ids.contains(t.id) && !DropsheetTask.isTrailing(t)) t,
    ];
    if (moving.isEmpty ||
        !_day.sections.any((s) => s.id == toSectionId)) {
      return;
    }
    final movingIds = moving.map((t) => t.id).toSet();
    final sections = _day.sections.map((s) {
      final kept = s.tasks.where((t) => !movingIds.contains(t.id)).toList();
      if (s.id != toSectionId) return s.copyWith(tasks: kept);
      final at = beforeTaskId != null
          ? kept.indexWhere((t) => t.id == beforeTaskId)
          : afterTaskId == null
              ? -1
              : kept.indexWhere((t) => t.id == afterTaskId) + 1;
      if (at > 0 || (at == 0 && beforeTaskId != null)) {
        return s.copyWith(
            tasks: [...kept.sublist(0, at), ...moving, ...kept.sublist(at)]);
      }
      // No anchor: drop-offs join the morning run (before the pick-up
      // divider), pick-ups the end of the afternoon (before Arrive).
      final pickUps =
          moving.where((t) => t.type == DropsheetTaskType.pickUp).toList();
      final others =
          moving.where((t) => t.type != DropsheetTaskType.pickUp).toList();
      var tasks = others.isEmpty ? kept : _insertBeforeAfternoon(kept, others);
      if (pickUps.isNotEmpty) {
        var end = tasks.indexWhere(DropsheetTask.isTrailing);
        if (end == -1) end = tasks.length;
        tasks = [...tasks.sublist(0, end), ...pickUps, ...tasks.sublist(end)];
      }
      return s.copyWith(tasks: tasks);
    }).toList();
    final driver =
        _day.sections.firstWhere((s) => s.id == toSectionId).driverName;
    await _save(_day.copyWith(sections: sections),
        undoLabel:
            undoLabel ?? 'Move to ${driver.isEmpty ? 'driver' : driver}');
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

/// [DropsheetProvider.syncDateOneShot]'s arguments: service, schedule
/// service, distributors.
typedef _OneShotArgs = (
  DropsheetService?,
  FirestoreService?,
  List<Distributor>?,
);

/// The one follow-up run queued behind a running one-shot sync of a date.
class _QueuedOneShot {
  _QueuedOneShot(this.args);
  _OneShotArgs args;
  final Completer<void> done = Completer<void>();
}
