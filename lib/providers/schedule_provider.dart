import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseException;
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/schedule.dart';
import '../utils/schedule_time.dart';
import '../models/work_area.dart';
import '../models/work_suburb.dart';
import '../models/custom_polygon.dart';
import '../models/schedule_confirmation_status.dart';
import '../services/firestore_service.dart';
import '../services/schedule_batch_move.dart';
import '../services/schedule_mutation_types.dart';
import 'auth_provider.dart';
import 'dropsheet_provider.dart';
import '../track_editor/services/te_place_names.dart' as place_names;
import '../utils/unsaved_changes_guard.dart';

final scheduleRiverpod = riverpod.ChangeNotifierProvider<ScheduleProvider>(
  (ref) => ScheduleProvider(ref: ref),
);

class ScheduleProvider extends ChangeNotifier {
  final FirestoreService _firestoreService;
  bool _isInitialized = false;
  bool _workAreaStreamsInitialized = false;

  List<Distributor> _distributors = [];
  List<Job> _currentMonthJobs = [];
  List<Job> _nextMonthJobs = [];

  // What the Firestore streams last delivered. [_currentMonthJobs] /
  // [_nextMonthJobs] are these with every pending write laid on top (see
  // [_rebuildFromServer]).
  List<Job> _serverCurrentMonthJobs = [];
  List<Job> _serverNextMonthJobs = [];

  // Extra months streamed on request (see [ensureMonthsLoadedForRange]) for
  // views like payroll whose date range crosses into a month outside the
  // current/next window. Feeds the per-day lookups only — never [jobs] —
  // so the schedule grid and month-wide operations are unaffected.
  final Map<String, List<Job>> _extraMonthJobs = {};
  final Map<String, StreamSubscription<List<Job>>> _extraMonthSubscriptions =
      {};
  List<WorkArea> _workAreas = [];
  List<WorkSuburb> _workSuburbs = [];
  DateTime _currentMonth = scheduleNow();

  // Cached combined jobs list — invalidated when either month's data changes
  List<Job>? _cachedJobs;

  // Cached job lookup map: "distributorId:YYYY-MM-DD" → List<Job>
  // Provides O(1) lookups for cellBuilder instead of O(N) linear scans
  Map<String, List<Job>>? _jobLookupMap;

  // Cached Schedule object — rebuilt only when jobs change
  Schedule? _cachedSchedule;

  // Monotonic version counter — increments on every data change.
  // Used by the grid Selector for O(1) deterministic change detection.
  int _jobsVersion = 0;
  int get jobsVersion => _jobsVersion;

  /// Invalidate all derived caches. Call whenever raw job data changes.
  void _invalidateCaches() {
    _cachedJobs = null;
    _jobLookupMap = null;
    _cachedSchedule = null;
    _jobsVersion++;
  }

  // --- Optimistic local state helpers ---

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Ensures a job has a valid drop-off point when it has work areas.
  ///
  /// If [preferExisting] is true, an existing point is kept when still inside
  /// a polygon work area. Otherwise a new default point is estimated.
  ///
  /// Two-way sync with a dropoff-category point in [Job.workMaps]:
  /// - If only the workMap point is set (e.g. fresh edit from the map
  ///   editor), `dropOffPoint` is updated to match.
  /// - If `dropOffPoint` has been changed (e.g. marker drag from the day
  ///   planner) and disagrees with the workMap dropoff point, the workMap
  ///   point is updated to match the new `dropOffPoint`. Without this the
  ///   dragged marker would snap back to the stale workMap location on the
  ///   next read.
  Job _normalizeDropOffPoint(Job job, {bool preferExisting = true}) {
    if (job.workMaps.isEmpty) return job.copyWith(dropOffPoint: null);

    // Priority 1: explicit dropoff-category point in workMaps.
    for (int i = 0; i < job.workMaps.length; i++) {
      final wm = job.workMaps[i];
      if (!(wm.isPoint &&
          wm.pointCategory == PointCategory.dropoff &&
          wm.points.isNotEmpty)) {
        continue;
      }
      final wmPoint = wm.points.first;
      final dop = job.dropOffPoint;
      if (dop != null && !_sameLatLng(dop, wmPoint)) {
        // Caller-supplied dropOffPoint wins — propagate it back into the
        // workMap so all readers (map editor, day planner, dropsheet) see
        // a single authoritative position.
        final updatedMaps = List<CustomPolygon>.from(job.workMaps);
        updatedMaps[i] = wm.copyWith(points: [dop]);
        return job.copyWith(workMaps: updatedMaps);
      }
      return job.copyWith(dropOffPoint: wmPoint);
    }

    final estimated = Job.estimateDropOffPointFromWorkMaps(job.workMaps);
    if (estimated == null) return job;

    final existing = job.dropOffPoint;
    if (!preferExisting || existing == null) {
      return job.copyWith(dropOffPoint: estimated);
    }

    final keepExisting = Job.isPointInsideAnyWorkArea(existing, job.workMaps);
    return keepExisting ? job : job.copyWith(dropOffPoint: estimated);
  }

  /// LatLng comparison with a small epsilon so floating-point rounding
  /// from Firestore round-trips doesn't trigger spurious workMap rewrites.
  static bool _sameLatLng(dynamic a, dynamic b) {
    if (a == null || b == null) return a == b;
    const eps = 1e-7;
    return (a.latitude - b.latitude).abs() < eps &&
        (a.longitude - b.longitude).abs() < eps;
  }

  // --- Optimistic writes -------------------------------------------------
  //
  // Every schedule mutation shows on screen at once and is saved in the
  // background, one at a time, in the order the user made them:
  //
  // * The writes run through [_writeChain], so a second drag never starts its
  //   transaction before the first has committed. Run in parallel, a later
  //   drag read the day docs before the earlier one landed, missed its job
  //   and failed, rolling the grid back.
  // * Each write's optimistic change is kept as a [_PendingWrite] and laid
  //   over every stream emission until the stream shows it. Transactions
  //   are not applied to Firestore's local cache, so a snapshot arriving
  //   mid-save (another day's edit, the previous drag landing) used to
  //   replace the lists and flash the job back to where it came from.
  // * Network and contention failures are retried until they go through.
  //   Only a write that cannot apply (its job was deleted or moved by
  //   someone else) is dropped — and only its own change is undone.

  final List<_PendingWrite> _pendingWrites = [];
  _PendingWrite? _recordingWrite;
  Future<void> _writeChain = Future<void>.value();

  /// Schedule writes not yet saved. Non-zero while a save is in flight or
  /// retrying (e.g. offline) — the page warns before closing meanwhile.
  final ValueNotifier<int> pendingWriteCount = ValueNotifier<int>(0);

  /// Upper bound on how long a saved write keeps masking the stream when
  /// the stream never shows exactly what was written (the service tidied
  /// it, or someone else edited the job straight after).
  static const Duration _confirmTimeout = Duration(seconds: 8);

  /// Replace a job in the local lists by id, then notify listeners instantly.
  void _optimisticUpdateJob(Job newJob) {
    final recording = _recordingWrite;
    if (recording != null) {
      recording.upserts[newJob.id] = newJob;
      recording.removes.remove(newJob.id);
    }
    if (_upsertLocal(newJob)) {
      _invalidateCaches();
      notifyListeners();
    }
  }

  /// Remove a job from local lists by id, then notify listeners instantly.
  void _optimisticRemoveJob(String jobId) {
    final recording = _recordingWrite;
    if (recording != null) {
      recording.removes.add(jobId);
      recording.upserts.remove(jobId);
    }
    _removeLocal(jobId);
    _invalidateCaches();
    notifyListeners();
  }

  /// Puts [job] in the local lists in place of its old copy, in the list for
  /// its month (a job moved across the month boundary changes list). A job
  /// the lists have never held is only added when one of the loaded months
  /// owns its date. Returns whether anything changed.
  bool _upsertLocal(Job job) {
    final ci = _currentMonthJobs.indexWhere((j) => j.id == job.id);
    final ni = ci >= 0 ? -1 : _nextMonthJobs.indexWhere((j) => j.id == job.id);
    final next = DateTime(_currentMonth.year, _currentMonth.month + 1);
    final inCurrent = job.date.year == _currentMonth.year &&
        job.date.month == _currentMonth.month;
    final inNext = job.date.year == next.year && job.date.month == next.month;
    if (ci < 0 && ni < 0 && !inCurrent && !inNext) return false;

    final toCurrent = inCurrent || (!inNext && ci >= 0);
    final current = List.of(_currentMonthJobs);
    final nextJobs = List.of(_nextMonthJobs);
    if (ci >= 0) current.removeAt(ci);
    if (ni >= 0) nextJobs.removeAt(ni);
    if (toCurrent) {
      current.insert(ci >= 0 ? ci : current.length, job);
    } else {
      nextJobs.insert(ni >= 0 ? ni : nextJobs.length, job);
    }
    _currentMonthJobs = current;
    _nextMonthJobs = nextJobs;
    return true;
  }

  void _removeLocal(String jobId) {
    final beforeCurrent = _currentMonthJobs.length;
    _currentMonthJobs = _currentMonthJobs.where((j) => j.id != jobId).toList();
    if (_currentMonthJobs.length == beforeCurrent) {
      _nextMonthJobs = _nextMonthJobs.where((j) => j.id != jobId).toList();
    }
  }

  /// Rebuilds the local lists from the last stream data plus every pending
  /// write, oldest first. Saved writes the stream now shows are retired.
  void _rebuildFromServer() {
    _pendingWrites.removeWhere((w) => w.committed && _serverShows(w));
    _currentMonthJobs = List.of(_serverCurrentMonthJobs);
    _nextMonthJobs = List.of(_serverNextMonthJobs);
    for (final w in _pendingWrites) {
      w.removes.forEach(_removeLocal);
      w.upserts.values.forEach(_upsertLocal);
    }
    _invalidateCaches();
  }

  /// Whether the stream data already reflects [write].
  bool _serverShows(_PendingWrite write) {
    final server = <String, Job>{
      for (final j in _serverCurrentMonthJobs) j.id: j,
      for (final j in _serverNextMonthJobs) j.id: j,
    };
    if (write.removes.any(server.containsKey)) return false;
    for (final e in write.upserts.entries) {
      final s = server[e.key];
      if (s == null || _fingerprint(s) != _fingerprint(e.value)) return false;
    }
    return true;
  }

  /// What a job saves as — resolved link areas excluded, the way [Job.toMap]
  /// writes it — so the stream's copy and the optimistic one compare equal.
  static String _fingerprint(Job job) => job.toMap().toString();

  /// Uniform pattern for every schedule mutation: apply the optimistic
  /// update now, then persist it through the write queue (see above). The
  /// returned future completes once the write is saved, or fails if it
  /// cannot be applied — after its optimistic change has been undone.
  ///
  /// [persist] must not call [_guardedMutation] itself: it would wait in the
  /// queue behind its own write.
  Future<void> _guardedMutation<T>({
    void Function()? applyOptimistic,
    required Future<T> Function() persist,
  }) {
    final write = _PendingWrite();
    _recordingWrite = write;
    try {
      applyOptimistic?.call();
    } finally {
      _recordingWrite = null;
    }
    _pendingWrites.add(write);
    _setPendingWriteCount(pendingWriteCount.value + 1);

    final done = Completer<void>();
    _writeChain = _writeChain.then((_) async {
      try {
        await _persistWithRetry(persist);
        write.committed = true;
        // The stream normally confirms within a moment; if it never shows
        // exactly this, stop masking it after [_confirmTimeout].
        Timer(_confirmTimeout, () {
          if (_pendingWrites.remove(write)) {
            _rebuildFromServer();
            notifyListeners();
          }
        });
        if (_serverShows(write)) {
          _pendingWrites.remove(write);
        }
        done.complete();
      } catch (e, st) {
        _pendingWrites.remove(write);
        _rebuildFromServer();
        notifyListeners();
        done.completeError(e, st);
      } finally {
        _setPendingWriteCount(pendingWriteCount.value - 1);
      }
    });
    return done.future;
  }

  void _setPendingWriteCount(int count) {
    pendingWriteCount.value = count;
    setUnsavedChangesGuard(count > 0);
  }

  /// Runs [persist] until it succeeds. Transient failures (offline, timeouts,
  /// transaction contention) are retried with backoff, indefinitely;
  /// anything else is thrown.
  Future<void> _persistWithRetry<T>(Future<T> Function() persist) async {
    var attempt = 0;
    var lastWasAmbiguous = false;
    while (true) {
      attempt++;
      try {
        await persist().timeout(const Duration(seconds: 30));
        return;
      } catch (e) {
        // A retry after a timeout / dropped connection can find its job
        // already moved: the earlier attempt did commit, only the reply was
        // lost. The stream then shows the result.
        if (e is JobNotFoundException && lastWasAmbiguous) {
          debugPrint('ScheduleProvider: write already applied on attempt '
              '${attempt - 1} ($e)');
          return;
        }
        if (!_isTransientWriteError(e)) rethrow;
        lastWasAmbiguous = true;
        final delayMs =
            (500 * (1 << (attempt - 1).clamp(0, 5))).clamp(500, 15000);
        debugPrint('ScheduleProvider: schedule write attempt $attempt failed '
            '($e); retrying in ${delayMs}ms');
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
  }

  static bool _isTransientWriteError(Object e) {
    if (e is TimeoutException) return true;
    if (e is FirebaseException) {
      return const {
        'unavailable',
        'aborted',
        'deadline-exceeded',
        'resource-exhausted',
        'internal',
        'unknown',
        'failed-precondition',
      }.contains(e.code);
    }
    return false;
  }

  /// Attaches the next-month job stream before a write that targets a date
  /// in that month, so the written job doesn't vanish from the local cache
  /// (the current-month stream drops it and nothing else would pick it up).
  Future<void> _ensureMonthStreamsCover(DateTime date) async {
    final next = DateTime(_currentMonth.year, _currentMonth.month + 1);
    if (date.year == next.year && date.month == next.month) {
      await ensureNextMonthLoaded();
    }
  }

  /// When true (set via `--dart-define=REPAIR_SCHEDULE=true`), the provider
  /// runs a one-time schedule integrity repair after the first data load.
  /// Defaults to false, so normal runs never touch data on load.
  static const bool _repairScheduleOnLoad =
      bool.fromEnvironment('REPAIR_SCHEDULE');
  bool _integrityRepairAttempted = false;

  /// One-time no-area duplicate cleanup, requested via
  /// `--dart-define=CLEAN_DUPS=dry` (report only) or `=apply` (write).
  /// Empty (the default) means never run.
  static const String _cleanDupsMode = String.fromEnvironment('CLEAN_DUPS');
  bool _cleanDupsAttempted = false;

  // Streams subscriptions
  StreamSubscription<List<Distributor>>? _distributorsSubscription;
  StreamSubscription<List<Job>>? _currentMonthJobsSubscription;
  StreamSubscription<List<Job>>? _nextMonthJobsSubscription;
  StreamSubscription<List<WorkArea>>? _workAreasSubscription;
  StreamSubscription<List<WorkSuburb>>? _workSuburbsSubscription;

  // Getters
  List<Distributor> get distributors => _distributors;
  List<Job> get jobs =>
      _cachedJobs ??= [..._currentMonthJobs, ..._nextMonthJobs];
  List<WorkArea> get workAreas => _workAreas;
  List<WorkSuburb> get workSuburbs => _workSuburbs;
  Schedule get schedule =>
      _cachedSchedule ??= Schedule(distributors: _distributors, jobs: jobs);

  /// Distributors filtered for grid display:
  /// - Always show active distributors
  /// - Hide non-active distributors unless they have jobs in the current month
  List<Distributor> get gridDistributors {
    final currentJobs = jobs;
    final distributorIdsWithJobs = <String>{};
    for (final job in currentJobs) {
      distributorIdsWithJobs.add(job.distributorId);
    }
    return _distributors.where((d) {
      if (d.status == DistributorStatus.active) return true;
      return distributorIdsWithJobs.contains(d.id);
    }).toList();
  }

  /// Distributors filtered for payroll: active distributors, or non-active
  /// distributors who have at least one schedule job whose date falls
  /// within `[start, end]` (inclusive) — same rule as [gridDistributors],
  /// but scoped to an arbitrary date range (a payroll week) instead of the
  /// rolling current/next-month cache. Also sees any extra months requested
  /// via [ensureMonthsLoadedForRange], which payroll does for each week it
  /// opens, so weeks crossing a month boundary find their jobs too.
  List<Distributor> distributorsWithJobsInRange(DateTime start, DateTime end) {
    final distributorIdsWithJobs = <String>{};
    for (final job in _jobsWithExtraMonths) {
      // Compare by date only — job.date may carry a time-of-day component
      // (e.g. time-slotted job types), which would wrongly exclude a job
      // later on the range's end day if compared against midnight directly.
      final d = DateTime(job.date.year, job.date.month, job.date.day);
      if (!d.isBefore(start) && !d.isAfter(end)) {
        distributorIdsWithJobs.add(job.distributorId);
      }
    }
    return _distributors.where((d) {
      if (d.status == DistributorStatus.active) return true;
      return distributorIdsWithJobs.contains(d.id);
    }).toList();
  }

  /// [jobs] plus any extra months requested via [ensureMonthsLoadedForRange]
  /// that the current/next streams don't already cover.
  List<Job> get _jobsWithExtraMonths {
    if (_extraMonthJobs.isEmpty) return jobs;
    final covered = {
      _firestoreService.getMonthlyDocumentId(_currentMonth),
      if (_nextMonthSubscribedFor != null)
        _firestoreService.getMonthlyDocumentId(_nextMonthSubscribedFor!),
    };
    return [
      ...jobs,
      for (final e in _extraMonthJobs.entries)
        if (!covered.contains(e.key)) ...e.value,
    ];
  }

  /// Streams every month touched by `[start, end]` that isn't already
  /// loaded, so [getJobsForDistributorAndDate] and
  /// [distributorsWithJobsInRange] see jobs across a month boundary (e.g. a
  /// payroll week of 25 Sep – 1 Oct viewed in October). Replaces any
  /// previously requested extra months — one caller-defined range at a time.
  void ensureMonthsLoadedForRange(DateTime start, DateTime end) {
    final wanted = <String, DateTime>{};
    for (var m = DateTime(start.year, start.month);
        !m.isAfter(DateTime(end.year, end.month));
        m = DateTime(m.year, m.month + 1)) {
      wanted[_firestoreService.getMonthlyDocumentId(m)] = m;
    }
    wanted.remove(_firestoreService.getMonthlyDocumentId(_currentMonth));
    final nextId = _firestoreService.getMonthlyDocumentId(
        DateTime(_currentMonth.year, _currentMonth.month + 1));
    if (_nextMonthSubscribedFor != null) wanted.remove(nextId);

    for (final id in _extraMonthSubscriptions.keys.toList()) {
      if (wanted.containsKey(id)) continue;
      _extraMonthSubscriptions.remove(id)?.cancel();
      _extraMonthJobs.remove(id);
      _invalidateCaches();
    }
    for (final e in wanted.entries) {
      if (_extraMonthSubscriptions.containsKey(e.key)) continue;
      _extraMonthSubscriptions[e.key] =
          _firestoreService.streamJobs(e.value).listen(
        (jobs) {
          _extraMonthJobs[e.key] = jobs;
          _invalidateCaches();
          notifyListeners();
        },
        onError: (error) {
          debugPrint(
              'ScheduleProvider: Extra month ${e.key} jobs stream error: $error');
        },
      );
    }
  }

  /// Build (or return cached) lookup map for O(1) cell queries.
  Map<String, List<Job>> get _lookupMap {
    if (_jobLookupMap != null) return _jobLookupMap!;
    final map = <String, List<Job>>{};
    for (final job in _jobsWithExtraMonths) {
      final key =
          '${job.distributorId}:${job.date.year}-${job.date.month.toString().padLeft(2, '0')}-${job.date.day.toString().padLeft(2, '0')}';
      (map[key] ??= []).add(job);
    }
    _jobLookupMap = map;
    return map;
  }

  DateTime get currentMonth => _currentMonth;
  String get currentMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(_currentMonth);

  // Helper method to check if the next month has any jobs
  bool get hasJobsInNextMonth => _nextMonthJobs.isNotEmpty;

  ScheduleProvider({FirestoreService? firestoreService, riverpod.Ref? ref})
      : _firestoreService = firestoreService ?? FirestoreService(),
        _ref = ref {
    final r = _ref;
    if (r != null) {
      // Attach the signed-in user's identity to every schedule audit-log
      // entry. Resolved lazily at mutation time, not at construction.
      _firestoreService.logUserResolver = () {
        final auth = r.read(authRiverpod);
        return ScheduleLogUser(
          uid: auth.user?.uid,
          email: auth.user?.email,
          name:
              auth.appUser?.name ?? auth.user?.displayName ?? auth.user?.email,
        );
      };
    }
  }

  /// Optional riverpod ref so the provider can notify peer providers
  /// (currently the dropsheet) about distributor coordinate changes.
  final riverpod.Ref? _ref;

  /// Push dropOff/pickUp coordinate changes for [updatedJob] into the
  /// dropsheet provider so any task linked to this job updates its
  /// cached `lat`/`lng` immediately. Safe to call from any screen — the
  /// dropsheet ignores the call when no matching task exists.
  void _notifyDropsheetOfCoordChanges(Job? previous, Job updatedJob) {
    final ref = _ref;
    if (ref == null) return;
    final prevDrop = previous?.dropOffPoint;
    final newDrop = updatedJob.dropOffPoint;
    final dropChanged = !_sameLatLng(prevDrop, newDrop);
    final prevPick = previous?.pickUpPoint;
    final newPick = updatedJob.pickUpPoint;
    final pickChanged = !_sameLatLng(prevPick, newPick);
    if (!dropChanged && !pickChanged) return;
    final dropsheet = ref.read(dropsheetRiverpod);
    if (dropChanged) {
      unawaited(dropsheet.refreshDropOffCoords(updatedJob.id, newDrop));
    }
    if (pickChanged) {
      unawaited(dropsheet.refreshPickUpCoords(updatedJob.id, newPick));
    }
  }
  // Don't initialize streams in constructor - let it be done async

  // Initialize streams asynchronously without blocking (full app)
  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await _initStreamsAsync();
  }

  /// Lightweight init for the CLM Maps flavor.
  /// Starts only the workAreas and workSuburbs streams — no distributors,
  /// no job streams. Safe to call multiple times (idempotent).
  void initializeWorkAreaStreams() {
    if (_workAreaStreamsInitialized) return;
    _workAreaStreamsInitialized = true;

    _workAreasSubscription = _firestoreService.streamWorkAreas().listen(
      (workAreas) {
        _workAreas = workAreas;
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: WorkAreas stream error: $error');
      },
    );

    _workSuburbsSubscription = _firestoreService.streamWorkSuburbs().listen(
      (suburbs) {
        _workSuburbs = suburbs;
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: WorkSuburbs stream error: $error');
      },
    );
  }

  /// Lightweight init for the track editor flavor.
  /// Fetches distributors once (no ongoing streams) — jobs are read
  /// on-demand via [fetchJobsForDistributorAndDate].
  Future<void> initForTrackEditor() async {
    try {
      _distributors = await _firestoreService.fetchDistributorsOnce();
      notifyListeners();
    } catch (e) {
      debugPrint('ScheduleProvider.initForTrackEditor: $e');
    }
  }

  /// One-time read of all work areas from Firestore (cache-first).
  Future<List<WorkArea>> fetchWorkAreas() async {
    try {
      return await _firestoreService.fetchWorkAreasOnce();
    } catch (e) {
      debugPrint('ScheduleProvider.fetchWorkAreas: $e');
      return [];
    }
  }

  // Load data streams asynchronously and concurrently
  Future<void> _initStreamsAsync() async {
    // Set up global streams once (distributors + work areas)
    _setupGlobalStreams();
    // Set up month-specific job streams
    _loadJobStreamsForMonth(_currentMonth);
  }

  /// Set up distributors and workAreas streams.
  /// These are global (not month-specific) and only need to be created once.
  void _setupGlobalStreams() {
    // Listen to distributors stream from root collection (not monthly)
    _distributorsSubscription = _firestoreService.streamDistributors().listen(
      (distributors) {
        _distributors = distributors;
        _cachedSchedule = null; // Schedule depends on distributors
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Distributors stream error: $error');
      },
    );

    // Listen to work areas / work suburbs streams — skip if already started
    // by initializeWorkAreaStreams() (CLM Maps flavor calls that first).
    if (!_workAreaStreamsInitialized) {
      _workAreaStreamsInitialized = true;

      _workAreasSubscription = _firestoreService.streamWorkAreas().listen(
        (workAreas) {
          _workAreas = workAreas;
          notifyListeners();
        },
        onError: (error) {
          debugPrint('ScheduleProvider: WorkAreas stream error: $error');
        },
      );

      _workSuburbsSubscription = _firestoreService.streamWorkSuburbs().listen(
        (suburbs) {
          _workSuburbs = suburbs;
          notifyListeners();
        },
        onError: (error) {
          debugPrint('ScheduleProvider: WorkSuburbs stream error: $error');
        },
      );
    }
  }

  // Tracks the month the next-month subscription is currently attached to.
  // Null when no next-month listener is active.
  DateTime? _nextMonthSubscribedFor;

  /// Completes on the next-month stream's first delivery, so code that needs
  /// that month's occupancy (batch moves) can wait for it.
  Completer<void> _nextMonthLoaded = Completer<void>();

  // Load job streams for a specific month (and next month when it has data)
  // Only tears down and recreates the two job subscriptions.
  void _loadJobStreamsForMonth(DateTime month) {
    // Cancel ONLY job subscriptions (not global distributors/workAreas)
    _currentMonthJobsSubscription?.cancel();
    _nextMonthJobsSubscription?.cancel();
    _nextMonthSubscribedFor = null;
    _nextMonthLoaded = Completer<void>();

    // Clear stale data from previous month so the lookup map
    // doesn't contain old-month entries while new streams start.
    _currentMonthJobs = [];
    _nextMonthJobs = [];
    _serverCurrentMonthJobs = [];
    _serverNextMonthJobs = [];

    // Invalidate all derived caches
    _invalidateCaches();

    debugPrint(
        'ScheduleProvider: Starting job stream for current month: ${_firestoreService.getMonthlyDocumentId(month)}');

    // Listen to jobs stream for the current month — set up synchronously
    _currentMonthJobsSubscription = _firestoreService.streamJobs(month).listen(
      (jobs) {
        _serverCurrentMonthJobs = jobs;
        _rebuildFromServer();
        _schedulePointNameBackfill();
        debugPrint(
            'ScheduleProvider: Received ${jobs.length} jobs for current month ${_firestoreService.getMonthlyDocumentId(month)}');
        notifyListeners();
        // One-time integrity repair, only when explicitly requested via
        // --dart-define=REPAIR_SCHEDULE=true. No-op in normal runs.
        if (_repairScheduleOnLoad && !_integrityRepairAttempted) {
          _integrityRepairAttempted = true;
          unawaited(repairIntegrityForLoadedMonths());
        }
        if (_cleanDupsMode.isNotEmpty && !_cleanDupsAttempted) {
          _cleanDupsAttempted = true;
          unawaited(cleanNoAreaDuplicatesForLoadedMonths(
              dryRun: _cleanDupsMode != 'apply'));
        }
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Current month jobs stream error: $error');
      },
    );

    // Next month is attached lazily: only when the monthly index document
    // exists (i.e. the month has real data). This avoids an empty collection
    // listener for every session on months that haven't been populated.
    unawaited(_maybeAttachNextMonthStream(month));
  }

  /// Attach the next-month jobs stream only if that month has any data.
  /// Uses a cache-first existence probe on the monthly index doc.
  Future<void> _maybeAttachNextMonthStream(DateTime currentMonth) async {
    final nextMonth = DateTime(currentMonth.year, currentMonth.month + 1);

    // Skip if another month change already happened.
    if (_currentMonth != currentMonth) return;

    final hasData = await _firestoreService.hasScheduleDataForMonth(nextMonth);

    // Re-check after the async gap — the user may have navigated away.
    if (_currentMonth != currentMonth) return;
    if (!hasData) {
      debugPrint(
          'ScheduleProvider: Skipping next-month stream (no data) for ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
      return;
    }

    _nextMonthSubscribedFor = nextMonth;
    _nextMonthJobsSubscription = _firestoreService.streamJobs(nextMonth).listen(
      (jobs) {
        _serverNextMonthJobs = jobs;
        if (!_nextMonthLoaded.isCompleted) _nextMonthLoaded.complete();
        _rebuildFromServer();
        _schedulePointNameBackfill();
        debugPrint(
            'ScheduleProvider: Received ${jobs.length} jobs for next month ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Next month jobs stream error: $error');
      },
    );
  }

  /// Public hook for callers (e.g. cross-date drag) that know they need
  /// next-month data even if the existence probe missed it.
  Future<void> ensureNextMonthLoaded() async {
    if (_nextMonthSubscribedFor != null) return;
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    _nextMonthSubscribedFor = nextMonth;
    _nextMonthJobsSubscription = _firestoreService.streamJobs(nextMonth).listen(
      (jobs) {
        _serverNextMonthJobs = jobs;
        if (!_nextMonthLoaded.isCompleted) _nextMonthLoaded.complete();
        _rebuildFromServer();
        _schedulePointNameBackfill();
        notifyListeners();
      },
      onError: (error) {
        debugPrint('ScheduleProvider: Next month jobs stream error: $error');
      },
    );
  }

  // Change current month
  void setCurrentMonth(DateTime month) {
    if (_currentMonth != month) {
      _currentMonth = month;
      _invalidateCaches();
      _loadJobStreamsForMonth(_currentMonth);
      notifyListeners();
    }
  }

  // Go to next month
  void goToNextMonth() {
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    setCurrentMonth(nextMonth);
  }

  // Go to previous month
  void goToPreviousMonth() {
    final previousMonth = DateTime(_currentMonth.year, _currentMonth.month - 1);
    setCurrentMonth(previousMonth);
  }

  // Go to current month
  void goToCurrentMonth() {
    setCurrentMonth(scheduleNow());
  }

  // Go to specific month by month string (e.g., "Sep 2025")
  void goToMonth(String monthString) {
    final DateTime? month = _parseMonthString(monthString);
    if (month != null) {
      setCurrentMonth(month);
    }
  }

  // Jump the grid to whichever month contains [date] (used by the
  // Today/Tomorrow confirmation quick buttons).
  void goToMonthContaining(DateTime date) {
    setCurrentMonth(DateTime(date.year, date.month));
  }

  // Streams the admin confirmation status for a single schedule day.
  Stream<ScheduleDayConfirmation> watchDayConfirmation(DateTime date) {
    return _firestoreService.streamScheduleDayConfirmation(date);
  }

  // Sets the admin confirmation status for a single schedule day.
  Future<void> setDayConfirmation(
    DateTime date,
    ScheduleConfirmationStatus status, {
    String? confirmedBy,
  }) {
    return _firestoreService.setScheduleDayConfirmation(
      date,
      status,
      confirmedBy: confirmedBy,
    );
  }

  // Helper method to parse month string back to DateTime
  DateTime? _parseMonthString(String monthString) {
    final parts = monthString.split(' ');
    if (parts.length != 2) return null;

    const months = {
      'Jan': 1,
      'Feb': 2,
      'Mar': 3,
      'Apr': 4,
      'May': 5,
      'Jun': 6,
      'Jul': 7,
      'Aug': 8,
      'Sep': 9,
      'Oct': 10,
      'Nov': 11,
      'Dec': 12
    };

    final monthNum = months[parts[0]];
    final year = int.tryParse(parts[1]);

    if (monthNum != null && year != null) {
      return DateTime(year, monthNum);
    }
    return null;
  }

  // Get available months
  Future<List<String>> getAvailableMonths() {
    return _firestoreService.getAvailableScheduleMonths();
  }

  // DISTRIBUTOR OPERATIONS

  Future<void> addDistributor(String name) async {
    // Distributors are in root collection, no monthly context needed
    await _firestoreService.addDistributor(name);
  }

  Future<void> updateDistributor(Distributor distributor) async {
    // Distributors are in root collection, no monthly context needed
    await _firestoreService.updateDistributor(distributor);
  }

  // Smart update distributor with automatic index management
  Future<void> updateDistributorSmart(
      Distributor updatedDistributor, int oldIndex) async {
    // Validate index bounds
    final maxIndex = _distributors.length - 1;
    if (updatedDistributor.index < 0 || updatedDistributor.index > maxIndex) {
      throw ArgumentError('Index must be between 0 and $maxIndex');
    }

    // Use smart indexing service method
    await _firestoreService.updateDistributorWithSmartIndexing(
        updatedDistributor, oldIndex);
  }

  Future<void> deleteDistributor(String distributorId) async {
    // Distributors are in root collection, no monthly context needed
    await _firestoreService.deleteDistributor(distributorId);
  }

  // Smart delete that reindexes remaining distributors.
  // Delete + reindex commit in a single batch so a mid-operation failure
  // can't leave the index ordering corrupted.
  Future<void> deleteDistributorSmart(String distributorId) async {
    final distributorToDelete =
        _distributors.where((d) => d.id == distributorId).firstOrNull;
    if (distributorToDelete == null) return;

    final toUpdate = _distributors
        .where(
            (d) => d.id != distributorId && d.index > distributorToDelete.index)
        .map((d) => d.copyWith(index: d.index - 1))
        .toList();

    await _firestoreService.batchSaveDistributors(
      toUpdate: toUpdate,
      toDelete: {distributorId},
    );
  }

  // Reorder distributors by updating their index values in a single batch.
  Future<void> reorderDistributors(
      List<Distributor> reorderedDistributors) async {
    final toUpdate = <Distributor>[
      for (int i = 0; i < reorderedDistributors.length; i++)
        reorderedDistributors[i].copyWith(index: i),
    ];
    await _firestoreService.batchSaveDistributors(
      toUpdate: toUpdate,
      toDelete: const {},
    );
  }

  // Commit all pending distributor edits (reorders, field changes, deletes)
  // in a single Firestore batch — 0 reads, 1 round-trip.
  Future<void> saveDistributorChanges({
    required List<Distributor> finalState,
    required Set<String> deletedIds,
  }) async {
    final currentById = {for (final d in _distributors) d.id: d};

    final toUpdate = <Distributor>[];
    for (final d in finalState) {
      final current = currentById[d.id];
      if (current == null) continue;
      if (current.index != d.index ||
          current.name != d.name ||
          current.phone1 != d.phone1 ||
          current.phone2 != d.phone2 ||
          current.status != d.status ||
          current.imageUrl != d.imageUrl ||
          current.role != d.role) {
        toUpdate.add(d);
      }
    }

    await _firestoreService.batchSaveDistributors(
      toUpdate: toUpdate,
      toDelete: deletedIds,
    );
  }

  // JOB OPERATIONS

  Future<void> addJob(Job job) async {
    try {
      final normalized = await _nameBarePoint(
          _normalizeDropOffPoint(job, preferExisting: false));
      final id = await _firestoreService.addJob(normalized, normalized.date);
      debugPrint('Successfully added job for ${job.date}');
      _nameBarePointLater(id, normalized);
    } catch (e) {
      debugPrint('Error adding job: $e');
      rethrow;
    }
  }

  // ── Naming point-only jobs ───────────────────────────────────────────────
  //
  // A job placed as a single point (tapped or found by address search) has
  // no work-area polygon to take a name from, so it used to read "To be
  // assigned" on the schedule and the dropsheet. Such jobs are named after
  // the nearest street intersection ("Voortrekker Rd & Durban Rd") from
  // OpenStreetMap. Only an empty / placeholder working area is ever filled;
  // a name someone typed is never replaced.

  static bool _isUnnamedArea(String area) {
    final t = area.trim().toLowerCase();
    return t.isEmpty || t == 'to be assigned';
  }

  /// The point to name when [job] is "just a point" and still unnamed, else
  /// null. Jobs with work-area polygons (own or linked) are never renamed.
  @visibleForTesting
  static LatLng? barePointToNameForTest(Job job) => _barePointToName(job);

  static LatLng? _barePointToName(Job job) {
    if (job.areaLinks.isNotEmpty) return null;
    if (job.workMaps.any((w) => w.isPolygon)) return null;
    if (!job.workingAreas.every(_isUnnamedArea)) return null;
    if (job.dropOffPoint != null) return job.dropOffPoint;
    for (final w in job.workMaps) {
      if (w.isPoint && w.points.isNotEmpty) return w.points.first;
    }
    return null;
  }

  /// Street intersection at [point], or null if none / not answered in time.
  static Future<String?> _intersectionAt(LatLng point,
      {Duration? timeout}) async {
    final key = place_names.tePlaceKey(point.latitude, point.longitude);
    var lookup =
        place_names.resolveIntersections([(point.latitude, point.longitude)]);
    if (timeout != null) {
      lookup = lookup.timeout(timeout, onTimeout: () => const {});
    }
    try {
      final name = (await lookup)[key]?.trim();
      return (name == null || name.isEmpty) ? null : name;
    } catch (e) {
      debugPrint('ScheduleProvider: intersection lookup failed: $e');
      return null;
    }
  }

  /// [job] with its working area set to the intersection name when it is an
  /// unnamed point and the name is known quickly (usually from memory — the
  /// jobs split off one Job List item share a point). Never delays a save by
  /// more than a few seconds; [_nameBarePointLater] covers the slow case.
  Future<Job> _nameBarePoint(Job job) async {
    final point = _barePointToName(job);
    if (point == null) return job;
    final name =
        await _intersectionAt(point, timeout: const Duration(seconds: 3));
    return name == null ? job : job.copyWith(workingAreas: [name]);
  }

  /// [job] named from an intersection already in memory — no network call.
  Job _nameBarePointFromCache(Job job) {
    final point = _barePointToName(job);
    if (point == null) return job;
    final (known, name) =
        place_names.cachedIntersection(point.latitude, point.longitude);
    final n = name?.trim();
    return known && n != null && n.isNotEmpty
        ? job.copyWith(workingAreas: [n])
        : job;
  }

  /// `jobId@lat,lng` naming follow-ups in flight, so repeated edits of the
  /// same unnamed job don't each start another lookup.
  final Set<String> _pointNamesInFlight = {};

  /// Names a saved point-only job once the lookup finishes, re-reading the
  /// job first so a name added meanwhile (or a new polygon) is respected.
  void _nameBarePointLater(String jobId, Job saved) {
    final point = _barePointToName(saved);
    if (point == null || jobId.isEmpty) return;
    final flightKey =
        '$jobId@${place_names.tePlaceKey(point.latitude, point.longitude)}';
    if (!_pointNamesInFlight.add(flightKey)) return;
    unawaited(() async {
      final name = await _intersectionAt(point)
          .whenComplete(() => _pointNamesInFlight.remove(flightKey));
      if (name == null) return;
      try {
        final current = (await _firestoreService.fetchJobsForDate(saved.date))
            .where((j) => j.id == jobId)
            .firstOrNull;
        if (current == null) return;
        final stillBare = _barePointToName(current);
        if (stillBare == null || !_sameLatLng(stillBare, point)) return;
        await updateJob(current.copyWith(workingAreas: [name]));
      } catch (e) {
        debugPrint('ScheduleProvider: naming point job $jobId failed: $e');
      }
    }());
  }

  /// `jobId@lat,lng` pairs already sent for naming this session, so a job
  /// is looked up once per point (moving its point makes it eligible again).
  final Set<String> _pointNameAttempts = {};
  Timer? _pointNameDebounce;

  void _schedulePointNameBackfill() {
    _pointNameDebounce?.cancel();
    _pointNameDebounce = Timer(
        const Duration(seconds: 2), () => unawaited(_backfillPointNames()));
  }

  /// Names point-only jobs that were created before naming existed (or whose
  /// lookup failed then), for today onwards — past days are left as run. All
  /// points go to Overpass in one batched lookup, then each job still
  /// unnamed at the same point gets its intersection as the working area.
  Future<void> _backfillPointNames() async {
    final today = scheduleToday();
    final todo = <(Job, LatLng, String)>[];
    for (final j in jobs) {
      if (j.id.isEmpty) continue;
      if (DateTime(j.date.year, j.date.month, j.date.day).isBefore(today)) {
        continue;
      }
      final p = _barePointToName(j);
      if (p == null) continue;
      final key = place_names.tePlaceKey(p.latitude, p.longitude);
      if (!_pointNameAttempts.add('${j.id}@$key')) continue;
      todo.add((j, p, key));
    }
    if (todo.isEmpty) return;

    Map<String, String?> names;
    try {
      names = await place_names.resolveIntersections(
          [for (final t in todo) (t.$2.latitude, t.$2.longitude)]);
    } catch (e) {
      debugPrint('ScheduleProvider: point-name backfill failed: $e');
      names = const {};
    }

    for (final (job, point, key) in todo) {
      if (!names.containsKey(key)) {
        // Map servers didn't answer — allow a retry on a later update.
        _pointNameAttempts.remove('${job.id}@$key');
        continue;
      }
      final name = names[key]?.trim();
      if (name == null || name.isEmpty) continue;
      final current = jobs.where((j) => j.id == job.id).firstOrNull;
      if (current == null) continue;
      final stillBare = _barePointToName(current);
      if (stillBare == null || !_sameLatLng(stillBare, point)) continue;
      try {
        await updateJob(current.copyWith(workingAreas: [name]));
        debugPrint('ScheduleProvider: named point job ${job.id} "$name"');
      } catch (e) {
        debugPrint('ScheduleProvider: naming point job ${job.id} failed: $e');
      }
    }
  }

  Future<void> updateJob(Job job) async {
    // Edits never wait on the map server: only an already-known name is
    // applied here; [_nameBarePointLater] fills it in otherwise.
    final normalized = _nameBarePointFromCache(_normalizeDropOffPoint(job));
    // Optimistic UI: surface the change locally before the Firestore
    // round-trip so the calling screen (work-areas map, print map, day
    // planner, etc.) reflects the new state instantly; rolled back
    // exactly if the transactional write fails.
    final previous = jobs.where((j) => j.id == normalized.id).firstOrNull;
    await _guardedMutation<void>(
      applyOptimistic:
          previous != null ? () => _optimisticUpdateJob(normalized) : null,
      persist: () => _firestoreService.updateJob(normalized, normalized.date),
    );
    _notifyDropsheetOfCoordChanges(previous, normalized);
    _nameBarePointLater(normalized.id, normalized);
  }

  Future<void> deleteJob(String jobId, [DateTime? targetDate]) async {
    // Find the job to get its date for proper monthly context
    final job = jobs.where((j) => j.id == jobId).firstOrNull;
    final jobDate = targetDate ?? job?.date ?? _currentMonth;
    await _guardedMutation<void>(
      // Remove locally right away so the cell empties without waiting for
      // the stream; restored if the delete fails.
      applyOptimistic: () => _optimisticRemoveJob(jobId),
      persist: () => _firestoreService.deleteJob(jobId, jobDate),
    );
    // Scrub any orphaned dropoff task from the affected date's
    // dropsheet — the live `DropsheetProvider` only auto-syncs for
    // today + next planning day, so this catches every other date.
    unawaited(DropsheetProvider.syncDateOneShot(
      jobDate,
      firestoreService: _firestoreService,
      distributors: _distributors.isNotEmpty ? _distributors : null,
    ));
  }

  Future<void> moveJobBetweenDates(Job originalJob, Job movedJob) =>
      _guardedMutation<void>(
        persist: () => _persistMoveBetweenDates(originalJob, movedJob),
      );

  /// The write behind [moveJobBetweenDates], for callers already inside a
  /// [_guardedMutation].
  Future<void> _persistMoveBetweenDates(Job originalJob, Job movedJob) async {
    // Attach the destination month's stream first so the moved job stays
    // visible in the local cache after the current-month stream drops it.
    await _ensureMonthStreamsCover(movedJob.date);
    await _firestoreService.moveJobBetweenDates(
      originalJob,
      movedJob,
      originalJob.date,
      movedJob.date,
    );
    // Sync the dropsheets for BOTH the source and destination dates so
    // the dropoff task moves with the job — even when neither date is
    // inside the auto-sync window of the live DropsheetProvider.
    final dists = _distributors.isNotEmpty ? _distributors : null;
    unawaited(DropsheetProvider.syncDateOneShot(
      originalJob.date,
      firestoreService: _firestoreService,
      distributors: dists,
    ));
    if (!_isSameDay(originalJob.date, movedJob.date)) {
      unawaited(DropsheetProvider.syncDateOneShot(
        movedJob.date,
        firestoreService: _firestoreService,
        distributors: dists,
      ));
    }
  }

  // Helper methods

  List<Job> getJobsForDistributorAndDate(String distributorId, DateTime date) {
    final key =
        '$distributorId:${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    return _lookupMap[key] ?? const [];
  }

  List<Job> getJobsForDistributor(String distributorId) {
    return schedule.getJobsForDistributor(distributorId);
  }

  List<Job> getJobsForDate(DateTime date) {
    return schedule.getJobsForDate(date);
  }

  // Get jobs for current month only
  List<Job> get currentMonthJobs => _currentMonthJobs;

  // Get jobs for next month only
  List<Job> get nextMonthJobs => _nextMonthJobs;

  // Get next month date
  DateTime get nextMonth =>
      DateTime(_currentMonth.year, _currentMonth.month + 1);

  // Get next month display string
  String get nextMonthDisplay =>
      _firestoreService.getMonthlyDocumentId(nextMonth);

  // Undo/Redo functionality for schedule operations - DISABLED
  // Direct operations without command pattern to avoid state corruption
  Future<void> addJobWithUndo(Job job, DateTime targetDate) async {
    // Bypass command pattern - add job directly
    await addJob(_normalizeDropOffPoint(job, preferExisting: false));
  }

  Future<void> updateJobWithUndo(
      Job originalJob, Job modifiedJob, DateTime targetDate) async {
    final normalized = _normalizeDropOffPoint(modifiedJob);

    // Check if we're moving the job to a different date
    if (!_isSameDay(originalJob.date, normalized.date)) {
      await _guardedMutation<void>(
        applyOptimistic: () => _optimisticUpdateJob(normalized),
        persist: () => _persistMoveBetweenDates(originalJob, normalized),
      );
      _notifyDropsheetOfCoordChanges(originalJob, normalized);
    } else {
      // updateJob applies its own optimistic update, rollback, and
      // dropsheet coordinate notification.
      await updateJob(normalized);
    }
  }

  Future<void> moveJobBetweenDatesWithUndo(Job originalJob, Job movedJob,
      DateTime originalDate, DateTime newDate) async {
    await _guardedMutation<void>(
      applyOptimistic: () => _optimisticUpdateJob(movedJob),
      persist: () => _persistMoveBetweenDates(originalJob, movedJob),
    );
  }

  /// Moves [jobs] onto [startDate] and the days after it, each to the
  /// first free distributor (see [planBatchMove]); a full day spills to the
  /// next. Shown at once and saved as one atomic write. Throws a
  /// [BatchMoveException] — before changing anything — when the loaded
  /// schedule has no room for every job.
  Future<BatchMovePlan> moveJobsFromDate(
    List<Job> jobs,
    DateTime startDate, {
    bool Function(String distributorId, DateTime date)? isDayOff,
  }) async {
    // Next month's jobs decide which of its slots are free.
    var lastDate = DateTime(_currentMonth.year, _currentMonth.month + 2, 0);
    await ensureNextMonthLoaded();
    try {
      await _nextMonthLoaded.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      lastDate = DateTime(_currentMonth.year, _currentMonth.month + 1, 0);
    }

    // Plan from the live copies: the selection may be a few edits old.
    final byId = {for (final j in this.jobs) j.id: j};
    final fresh = [
      for (final j in jobs)
        if (byId[j.id] != null) byId[j.id]!,
    ];
    if (fresh.isEmpty) throw BatchMoveException('The selected jobs are gone.');

    final plan = planBatchMove(
      jobs: fresh,
      distributors: _distributors,
      startDate: startDate,
      lastDate: lastDate,
      occupiedOn: (d) => {for (final j in getJobsForDate(d)) j.distributorId},
      isDayOff: isDayOff ?? (_, __) => false,
    );
    if (plan.unplaced.isNotEmpty) {
      throw BatchMoveException(
        'Only ${plan.moved.length} of ${fresh.length} jobs fit between '
        '${DateFormat('d MMM').format(startDate)} and '
        '${DateFormat('d MMM').format(lastDate)} — nothing was moved.',
      );
    }

    final moves = <(Job, Job)>[
      for (final j in fresh)
        if (plan.moved[j.id]!.distributorId != j.distributorId ||
            !_isSameDay(plan.moved[j.id]!.date, j.date))
          (j, plan.moved[j.id]!),
    ];
    if (moves.isEmpty) return plan;

    await _guardedMutation<void>(
      applyOptimistic: () {
        final recording = _recordingWrite;
        for (final (_, moved) in moves) {
          recording?.upserts[moved.id] = moved;
          recording?.removes.remove(moved.id);
          _upsertLocal(moved);
        }
        _invalidateCaches();
        notifyListeners();
      },
      persist: () async {
        await _firestoreService.moveJobsAtomically(moves);
        final dists = _distributors.isNotEmpty ? _distributors : null;
        final dates = <String, DateTime>{
          for (final (original, moved) in moves) ...{
            DateFormat('yyyy-MM-dd').format(original.date): original.date,
            DateFormat('yyyy-MM-dd').format(moved.date): moved.date,
          },
        };
        for (final date in dates.values) {
          unawaited(DropsheetProvider.syncDateOneShot(
            date,
            firestoreService: _firestoreService,
            distributors: dists,
          ));
        }
      },
    );
    return plan;
  }

  Future<void> deleteJobWithUndo(Job job, DateTime targetDate) async {
    await deleteJob(job.id, targetDate);
  }

  /// Atomically replaces a set of schedule jobs with another set.
  ///
  /// This is used by job-list date shift flows to avoid per-job delete/add
  /// churn that can emit many intermediate stream states.
  Future<List<Job>> reallocateJobsAtomically({
    required List<Job> removeJobs,
    required List<Job> addJobs,
    String debugTag = 'schedule-reallocation',
  }) async {
    final sw = Stopwatch()..start();
    debugPrint(
      '[$debugTag] provider start: remove=${removeJobs.length}, add=${addJobs.length}',
    );

    final added = await _firestoreService.reallocateJobsAtomically(
      removeJobs: removeJobs,
      addJobs: addJobs,
      debugTag: debugTag,
    );

    final affected = <String, DateTime>{};
    for (final j in removeJobs) {
      final d = DateTime(j.date.year, j.date.month, j.date.day);
      affected['${d.year}-${d.month}-${d.day}'] = d;
    }
    for (final j in added) {
      final d = DateTime(j.date.year, j.date.month, j.date.day);
      affected['${d.year}-${d.month}-${d.day}'] = d;
    }

    final dists = _distributors.isNotEmpty ? _distributors : null;
    for (final date in affected.values) {
      unawaited(DropsheetProvider.syncDateOneShot(
        date,
        firestoreService: _firestoreService,
        distributors: dists,
      ));
    }

    sw.stop();
    debugPrint(
      '[$debugTag] provider complete in ${sw.elapsedMilliseconds}ms (affectedDates=${affected.length})',
    );

    return added;
  }

  /// Maintenance: heals legacy data-integrity issues (misfiled `date` fields
  /// and within-day duplicate job ids) for the current and next month by
  /// running each populated day document back through the transactional
  /// integrity pass. Safe to re-run — clean days are skipped. Distinct jobs
  /// sharing a distributor-day are preserved, never merged.
  Future<String> repairIntegrityForLoadedMonths() async {
    final parts = <String>[];
    for (final month in [
      _currentMonth,
      DateTime(_currentMonth.year, _currentMonth.month + 1),
    ]) {
      final label = _firestoreService.getMonthlyDocumentId(month);
      // Repair each month independently so an unrelated failure on one
      // (e.g. a transient Firestore timeout) can't abort the other.
      try {
        final days = await _firestoreService.repairScheduleMonth(month);
        parts.add('${days.length} day(s) in $label');
      } catch (e) {
        parts.add('FAILED for $label: $e');
      }
    }
    final summary = '🛠️ Integrity repair: ${parts.join(', ')}';
    debugPrint('ScheduleProvider: $summary');
    return summary;
  }

  /// Maintenance: clears no-area duplicate jobs (see
  /// [FirestoreService.cleanNoAreaDuplicates]) for the current and next month.
  /// [dryRun] true only reports; false writes. Jobs with real work areas are
  /// never touched.
  Future<String> cleanNoAreaDuplicatesForLoadedMonths(
      {bool dryRun = true}) async {
    final parts = <String>[];
    for (final month in [
      _currentMonth,
      DateTime(_currentMonth.year, _currentMonth.month + 1),
    ]) {
      final label = _firestoreService.getMonthlyDocumentId(month);
      try {
        final ids = await _firestoreService.cleanNoAreaDuplicates(month,
            dryRun: dryRun);
        parts.add('${ids.length} in $label');
      } catch (e) {
        parts.add('FAILED for $label: $e');
      }
    }
    final summary =
        '🧹 No-area duplicate cleanup (${dryRun ? "DRY-RUN" : "APPLIED"}): ${parts.join(', ')}';
    debugPrint('ScheduleProvider: $summary');
    return summary;
  }

  Future<void> updateJobStatusWithUndo(String jobId, String newStatusId,
      String originalStatusId, DateTime targetDate) async {
    final job = jobs.where((j) => j.id == jobId).firstOrNull;
    if (job == null) throw JobNotFoundException(jobId);
    final updatedJob = job.copyWith(statusId: newStatusId);
    // updateJob handles optimistic apply + rollback.
    await updateJob(updatedJob);
  }

  Future<void> swapJobsWithUndo(
      Job draggedJob, Job targetJob, DateTime targetDate) async {
    // Each job takes the other's position (distributorId + date)
    final newDraggedJob = draggedJob.copyWith(
      distributorId: targetJob.distributorId,
      date: targetJob.date,
    );
    final newTargetJob = targetJob.copyWith(
      distributorId: draggedJob.distributorId,
      date: draggedJob.date,
    );

    await _guardedMutation<void>(
      applyOptimistic: () {
        _optimisticUpdateJob(newDraggedJob);
        _optimisticUpdateJob(newTargetJob);
      },
      persist: () async {
        if (_isSameDay(draggedJob.date, targetJob.date)) {
          await _firestoreService.swapJobsOnSameDate(
              newDraggedJob, newTargetJob, draggedJob.date);
        } else {
          await _ensureMonthStreamsCover(targetJob.date);
          await _ensureMonthStreamsCover(draggedJob.date);
          await _firestoreService.swapJobsBetweenDates(
            draggedJob,
            newDraggedJob,
            targetJob,
            newTargetJob,
            draggedJob.date,
            targetJob.date,
          );
        }
      },
    );
  }

  Future<void> combineJobsWithUndo(Job draggedJob, Job targetJob,
      Job combinedJob, DateTime targetDate) async {
    await _guardedMutation<void>(
      applyOptimistic: () {
        _optimisticRemoveJob(draggedJob.id);
        _optimisticUpdateJob(combinedJob);
      },
      persist: () async {
        if (_isSameDay(draggedJob.date, targetJob.date)) {
          await _firestoreService.combineJobsOnSameDate(
              draggedJob.id, combinedJob, draggedJob.date);
        } else {
          await _firestoreService.combineJobsBetweenDates(
              draggedJob.id, combinedJob, draggedJob.date, targetJob.date);
        }
      },
    );
  }

  Future<void> copyAndCombineJobsWithUndo(
      Job targetJob, Job combinedJob, DateTime targetDate) async {
    // updateJob handles optimistic apply + rollback.
    await updateJob(combinedJob);
  }

  // Undo/Redo functionality for map operations - DISABLED
  Future<void> addPolygonWithUndo(
      String jobId, CustomPolygon polygon, DateTime targetDate) async {
    // Bypass command pattern - add polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedJob = job.copyWith(
      workMaps: [...job.workMaps, polygon],
    );
    await updateJob(updatedJob);
  }

  Future<void> editPolygonWithUndo(String jobId, CustomPolygon originalPolygon,
      CustomPolygon modifiedPolygon, DateTime targetDate) async {
    // Bypass command pattern - edit polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedMaps = job.workMaps
        .map((p) => p.name == originalPolygon.name ? modifiedPolygon : p)
        .toList();
    final updatedJob = job.copyWith(workMaps: updatedMaps);
    await updateJob(updatedJob);
  }

  Future<void> deletePolygonWithUndo(
      String jobId, CustomPolygon polygon, DateTime targetDate) async {
    // Bypass command pattern - delete polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedMaps =
        job.workMaps.where((p) => p.name != polygon.name).toList();
    final updatedJob = job.copyWith(workMaps: updatedMaps);
    await updateJob(updatedJob);
  }

  // Undo/Redo no longer available - stubs for compatibility
  bool get canUndo => false;
  bool get canRedo => false;
  String? get nextUndoDescription => null;
  String? get nextRedoDescription => null;

  /// Fetch jobs directly from Firestore for a specific date and distributor.
  /// Uses a one-time read so it works regardless of debug/release stream scope.
  Future<List<Job>> fetchJobsForDistributorAndDate(
    String distributorId,
    DateTime date,
  ) async {
    // Normalize to midnight local to ensure we target the right daily doc.
    final localDate = DateTime(date.year, date.month, date.day);
    final jobs = await _firestoreService.fetchJobsForDate(localDate);
    return jobs.where((j) => j.distributorId == distributorId).toList();
  }

  /// Live version of [fetchJobsForDistributorAndDate]. Works for any day,
  /// not just the months this provider keeps streaming.
  Stream<List<Job>> watchJobsForDistributorAndDate(
    String distributorId,
    DateTime date,
  ) {
    final localDate = DateTime(date.year, date.month, date.day);
    return _firestoreService.watchJobsForDate(localDate).map(
        (jobs) => jobs.where((j) => j.distributorId == distributorId).toList());
  }

  Future<bool> undo() async {
    return false;
  }

  Future<bool> redo() async {
    return false;
  }

  @override
  void dispose() {
    _pointNameDebounce?.cancel();
    pendingWriteCount.dispose();
    _isInitialized = false;
    _workAreaStreamsInitialized = false;
    _distributorsSubscription?.cancel();
    _currentMonthJobsSubscription?.cancel();
    _nextMonthJobsSubscription?.cancel();
    for (final sub in _extraMonthSubscriptions.values) {
      sub.cancel();
    }
    _workAreasSubscription?.cancel();
    _workSuburbsSubscription?.cancel();
    super.dispose();
  }
}

/// One schedule write's optimistic change, kept until the stream shows it.
class _PendingWrite {
  final Map<String, Job> upserts = {};
  final Set<String> removes = {};
  bool committed = false;
}

/// A batch move that could not be planned; nothing was changed.
class BatchMoveException implements Exception {
  final String message;
  BatchMoveException(this.message);
  @override
  String toString() => message;
}
