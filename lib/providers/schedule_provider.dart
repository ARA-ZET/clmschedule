import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart'
    show DocumentReference, FirebaseException, FirebaseFirestore;
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;
import '../models/distributor.dart';
import '../models/job.dart';
import '../models/job_list_item.dart';
import '../models/schedule.dart';
import '../utils/schedule_time.dart';
import '../models/work_area.dart';
import '../models/work_suburb.dart';
import '../models/custom_polygon.dart';
import '../models/schedule_confirmation_status.dart';
import '../services/client_address_pin.dart';
import '../services/firestore_service.dart';
import '../services/geocoding_service.dart';
import '../services/job_list_service.dart';
import '../utils/distribution_lag.dart' show jobListClientKey;
import '../services/schedule_batch_move.dart';
import '../services/schedule_mutation_types.dart';
import '../services/area_link_resolver.dart';
import 'auth_provider.dart';
import 'dropsheet_provider.dart';
import '../track_editor/services/te_place_names.dart' as place_names;
import '../utils/resilient_subscription.dart';
import '../services/sync_status.dart';
import '../services/storage_health.dart';
import '../undo/undo_history.dart';

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
  final Map<String, ResilientSubscription<List<Job>>>
      _extraMonthSubscriptions = {};
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
  ///
  /// When the two disagree, [previous] (the job as stored before this edit)
  /// says which one the user moved: a map-editor drag moves only the workMap
  /// point while the job still carries the old `dropOffPoint`, and that drag
  /// must win rather than snap back.
  static Job _normalizeDropOffPoint(Job job,
      {bool preferExisting = true, Job? previous}) {
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
      final wmMoved = previous != null &&
          !_sameLatLng(_dropOffWorkMapPoint(previous), wmPoint);
      final dopMoved =
          previous == null || !_sameLatLng(previous.dropOffPoint, dop);
      if (dop != null &&
          !_sameLatLng(dop, wmPoint) &&
          !(wmMoved && !dopMoved)) {
        // Caller-supplied dropOffPoint wins — propagate it back into the
        // workMap so all readers (map editor, day planner, dropsheet) see
        // a single authoritative position.
        final updatedMaps = List<CustomPolygon>.from(job.workMaps);
        updatedMaps[i] = wm.copyWith(points: [dop]);
        return job.copyWith(workMaps: updatedMaps);
      }
      return job.copyWith(dropOffPoint: wmPoint);
    }

    // This edit moved the drop-off (a day-planner drag) and the job has no
    // dropoff map point yet: store it as one. Otherwise a spot outside the
    // job's own polygons — a neighbour's area, shared with another
    // distributor to save fuel — is re-estimated back to the centroid on
    // the next save.
    final moved = job.dropOffPoint;
    if (moved != null &&
        previous != null &&
        !_sameLatLng(previous.dropOffPoint, moved)) {
      return job.copyWith(workMaps: [
        ...job.workMaps,
        CustomPolygon(
          name: 'Drop-off Point',
          description: 'Auto-generated drop-off point',
          points: [moved],
          color: PointCategory.dropoff.color,
          type: MapElementType.point,
          pointCategory: PointCategory.dropoff,
        ),
      ]);
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

  static LatLng? _dropOffWorkMapPoint(Job job) {
    for (final wm in job.workMaps) {
      if (wm.isPoint &&
          wm.pointCategory == PointCategory.dropoff &&
          wm.points.isNotEmpty) {
        return wm.points.first;
      }
    }
    return null;
  }

  @visibleForTesting
  static Job normalizeDropOffPointForTest(Job job, {Job? previous}) =>
      _normalizeDropOffPoint(job, previous: previous);

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
  // * Writes queue per DAY ([_dayLaneTails]): a write waits only for earlier
  //   writes that touch one of its days, so a second drag on the same day
  //   never starts its transaction before the first has committed — run
  //   together, the later one read the day docs before the earlier landed,
  //   missed its job and failed, rolling the grid back. Writes on different
  //   days save side by side. A job lives on exactly one day, and every
  //   write names the day the job is on now (as shown, pending writes
  //   included), so two writes involving the same job always share a day.
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

  /// Day key → the last queued write touching that day. Completes (never
  /// with an error) once that write is done, saved or not.
  final Map<String, Future<void>> _dayLaneTails = {};

  /// A write that named no day waits for everything queued before it, and
  /// everything after waits for it.
  Future<void>? _barrierTail;

  /// Writes currently retrying, across the day lanes — the sync banner says
  /// "retrying" while any is.
  int _retryingWrites = 0;

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

  static String _dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';

  /// Uniform pattern for every schedule mutation: apply the optimistic
  /// update now, then persist it through the write queue (see above). The
  /// returned future completes once the write is saved, or fails if it
  /// cannot be applied — after its optimistic change has been undone.
  ///
  /// [dates] are every day [persist] reads or writes: the job's current day
  /// and, for a move, its new one. The write queues behind earlier writes
  /// on those days only.
  ///
  /// [persist] must not call [_guardedMutation] itself: it would wait in the
  /// queue behind its own write.
  Future<void> _guardedMutation<T>({
    required Iterable<DateTime> dates,
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

    // Join the lanes of [dates]: wait for the last write on each of them,
    // then become the last write on each.
    final keys = {for (final d in dates) _dayKey(d)};
    final finished = Completer<void>();
    final waitFor = <Future<void>>[];
    final barrier = _barrierTail;
    if (barrier != null) waitFor.add(barrier);
    if (keys.isEmpty) {
      waitFor.addAll(_dayLaneTails.values);
      _barrierTail = finished.future;
    } else {
      for (final k in keys) {
        final tail = _dayLaneTails[k];
        if (tail != null) waitFor.add(tail);
        _dayLaneTails[k] = finished.future;
      }
    }

    final done = Completer<void>();
    unawaited(() async {
      await Future.wait(waitFor);
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
        // Leave the lanes (unless a later write already took them over) and
        // let the writes queued behind this one go.
        for (final k in keys) {
          if (identical(_dayLaneTails[k], finished.future)) {
            _dayLaneTails.remove(k);
          }
        }
        if (identical(_barrierTail, finished.future)) _barrierTail = null;
        finished.complete();
      }
    }());
    return done.future;
  }

  void _setPendingWriteCount(int count) {
    pendingWriteCount.value = count;
    // Also drives the web "leave page?" warning, across schedule + payroll.
    SyncStatus.instance.reportPendingWrites('schedule', count);
  }

  /// Runs [persist] until it succeeds. Transient failures (offline, timeouts,
  /// transaction contention) are retried with backoff, indefinitely;
  /// anything else is thrown.
  Future<void> _persistWithRetry<T>(Future<T> Function() persist) async {
    var attempt = 0;
    var lastWasAmbiguous = false;
    // Writes on different days retry side by side; the banner says
    // "retrying" while any of them is.
    var retrying = false;
    void setRetrying(bool on) {
      if (on == retrying) return;
      retrying = on;
      _retryingWrites += on ? 1 : -1;
      SyncStatus.instance
          .reportWriteRetrying('schedule', _retryingWrites > 0);
    }

    try {
      while (true) {
        attempt++;
        try {
          await persist().timeout(const Duration(seconds: 30));
          return;
        } catch (e) {
          StorageHealth.instance.noteError(e);
          // A retry after a timeout / dropped connection can find its job
          // already moved: the earlier attempt did commit, only the reply
          // was lost. The stream then shows the result.
          if (e is JobNotFoundException && lastWasAmbiguous) {
            debugPrint('ScheduleProvider: write already applied on attempt '
                '${attempt - 1} ($e)');
            return;
          }
          // On web a runTransaction timeout (slow connection) arrives as a
          // TypeError, not a TimeoutException — see _isMaskedWebTimeout.
          // Retry it like a timeout, but not forever in case it is a real
          // bug.
          final maskedTimeout = _isMaskedWebTimeout(e) && attempt <= 8;
          if (!_isTransientWriteError(e) && !maskedTimeout) rethrow;
          lastWasAmbiguous = true;
          setRetrying(true);
          final delayMs =
              (500 * (1 << (attempt - 1).clamp(0, 5))).clamp(500, 15000);
          debugPrint('ScheduleProvider: schedule write attempt $attempt '
              'failed ($e); retrying in ${delayMs}ms');
          await Future<void>.delayed(Duration(milliseconds: delayMs));
        }
      }
    } finally {
      setRetrying(false);
    }
  }

  /// FlutterFire web casts every error from runTransaction to a JS error,
  /// so its own 30 s timeout surfaces as "type 'minified:xx' is not a
  /// subtype of type 'minified:yy'" — the commit may or may not have
  /// landed. Treated as ambiguous: retried, and a JobNotFound afterwards
  /// counts as already applied.
  static bool _isMaskedWebTimeout(Object e) => kIsWeb && e is TypeError;

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
  ResilientSubscription<List<Distributor>>? _distributorsSubscription;
  ResilientSubscription<List<Job>>? _currentMonthJobsSubscription;
  ResilientSubscription<List<Job>>? _nextMonthJobsSubscription;
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
      _extraMonthSubscriptions[e.key] = ResilientSubscription<List<Job>>(
        debugLabel: 'schedule ${e.key}',
        userLabel: 'the schedule',
        open: () => _firestoreService.streamJobs(e.value),
        onData: (jobs) {
          _extraMonthJobs[e.key] = jobs;
          _invalidateCaches();
          notifyListeners();
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
  /// dropsheet so any task linked to this job updates its cached
  /// `lat`/`lng` immediately. Safe to call from any screen — the dropsheet
  /// ignores the call when no matching task exists.
  ///
  /// A pick-up without its own point is collected where it was dropped
  /// ([DropsheetProvider.pickUpPointFor]), so it moves with the drop-off.
  /// The open sheet is patched in place; any other date's sheet (or the
  /// open one before its first server snapshot) is patched off-stream.
  void _notifyDropsheetOfCoordChanges(Job? previous, Job updatedJob) =>
      _notifyDropsheetOfCoordChangesBatch(
          {if (previous != null) updatedJob.id: previous}, [updatedJob]);

  /// [_notifyDropsheetOfCoordChanges] for several jobs: one save per
  /// dropsheet day, however many of its stops moved.
  void _notifyDropsheetOfCoordChangesBatch(
      Map<String, Job> previousById, List<Job> updated) {
    final moved = updated.where((job) {
      final previous = previousById[job.id];
      return !_sameLatLng(previous?.dropOffPoint, job.dropOffPoint) ||
          !_sameLatLng(
              previous == null
                  ? null
                  : DropsheetProvider.pickUpPointFor(previous),
              DropsheetProvider.pickUpPointFor(job));
    }).toList();
    if (moved.isEmpty) return;
    final dropsheet = _ref?.read(dropsheetRiverpod);
    final onOpenSheet = dropsheet != null && dropsheet.isDayReady
        ? moved.where((j) => _isSameDay(dropsheet.date, j.date)).toList()
        : const <Job>[];
    if (onOpenSheet.isNotEmpty) {
      unawaited(dropsheet!.refreshCoordsFromJobs(onOpenSheet));
    }
    final elsewhere = moved.where((j) => !onOpenSheet.contains(j)).toList();
    if (elsewhere.isNotEmpty) {
      unawaited(DropsheetProvider.refreshCoordsFromJobsOneShot(elsewhere));
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
    _distributorsSubscription = ResilientSubscription<List<Distributor>>(
      debugLabel: 'distributors',
      userLabel: 'the distributor list',
      open: _firestoreService.streamDistributors,
      onData: (distributors) {
        _distributors = distributors;
        _cachedSchedule = null; // Schedule depends on distributors
        notifyListeners();
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
    _currentMonthJobsSubscription = ResilientSubscription<List<Job>>(
      debugLabel:
          'schedule ${_firestoreService.getMonthlyDocumentId(month)}',
      userLabel: 'the schedule',
      open: () => _firestoreService.streamJobs(month),
      onData: (jobs) {
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

    // Re-check after the async gap — the user may have navigated away, or
    // ensureNextMonthLoaded may have attached the stream meanwhile (a second
    // subscription would leak: only one is held, and only one cancelled).
    if (_currentMonth != currentMonth) return;
    if (_nextMonthSubscribedFor != null) return;
    if (!hasData) {
      debugPrint(
          'ScheduleProvider: Skipping next-month stream (no data) for ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
      return;
    }

    _nextMonthSubscribedFor = nextMonth;
    _nextMonthJobsSubscription = ResilientSubscription<List<Job>>(
      debugLabel:
          'schedule ${_firestoreService.getMonthlyDocumentId(nextMonth)}',
      userLabel: 'the schedule',
      open: () => _firestoreService.streamJobs(nextMonth),
      onData: (jobs) {
        _serverNextMonthJobs = jobs;
        if (!_nextMonthLoaded.isCompleted) _nextMonthLoaded.complete();
        _rebuildFromServer();
        _schedulePointNameBackfill();
        debugPrint(
            'ScheduleProvider: Received ${jobs.length} jobs for next month ${_firestoreService.getMonthlyDocumentId(nextMonth)}');
        notifyListeners();
      },
    );
  }

  /// Public hook for callers (e.g. cross-date drag) that know they need
  /// next-month data even if the existence probe missed it.
  Future<void> ensureNextMonthLoaded() async {
    if (_nextMonthSubscribedFor != null) return;
    final nextMonth = DateTime(_currentMonth.year, _currentMonth.month + 1);
    _nextMonthSubscribedFor = nextMonth;
    _nextMonthJobsSubscription = ResilientSubscription<List<Job>>(
      debugLabel:
          'schedule ${_firestoreService.getMonthlyDocumentId(nextMonth)}',
      userLabel: 'the schedule',
      open: () => _firestoreService.streamJobs(nextMonth),
      onData: (jobs) {
        _serverNextMonthJobs = jobs;
        if (!_nextMonthLoaded.isCompleted) _nextMonthLoaded.complete();
        _rebuildFromServer();
        _schedulePointNameBackfill();
        notifyListeners();
      },
    );
  }

  /// Makes sure the jobs on [date] are loaded. The provider holds the grid's
  /// month and the next; the day planner (and its panel) read a day's jobs
  /// from here, so a day outside both showed no drop-offs in the panel and
  /// map pins with no job behind them — a drag then moved only the
  /// dropsheet task, never the schedule. Moves the grid to [date]'s month
  /// when it is neither.
  Future<void> ensureDateLoaded(DateTime date) async {
    bool sameMonth(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month;
    if (sameMonth(date, _currentMonth)) return;
    if (sameMonth(
        date, DateTime(_currentMonth.year, _currentMonth.month + 1))) {
      return ensureNextMonthLoaded();
    }
    goToMonthContaining(date);
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

  /// Commit every pending distributor edit — adds, reorders, field changes
  /// and deletes — in a single Firestore batch (0 reads, 1 round-trip).
  ///
  /// [finalState] is the list exactly as it should end up; anything in it with
  /// an id this device doesn't know yet is created. `payroll` is deliberately
  /// taken from the live copy rather than [finalState]: the management screen
  /// never edits wage rates or payment accounts, so writing its (possibly
  /// stale) copy back would clobber a change made meanwhile in Payroll.
  Future<void> saveDistributorChanges({
    required List<Distributor> finalState,
    required Set<String> deletedIds,
  }) async {
    final currentById = {for (final d in _distributors) d.id: d};

    final toCreate = <Distributor>[];
    final toUpdate = <Distributor>[];
    for (final raw in finalState) {
      final current = currentById[raw.id];
      if (current == null) {
        toCreate.add(raw);
        continue;
      }
      final d = raw.copyWith(
        payroll: current.payroll,
        clearPayroll: current.payroll == null,
      );
      if (current.index != d.index ||
          current.name != d.name ||
          current.phone1 != d.phone1 ||
          current.phone2 != d.phone2 ||
          current.status != d.status ||
          current.imageUrl != d.imageUrl ||
          current.role != d.role ||
          current.fullName != d.fullName ||
          current.idNumber != d.idNumber ||
          current.homeAddress != d.homeAddress) {
        toUpdate.add(d);
      }
    }

    await _firestoreService.batchSaveDistributors(
      toCreate: toCreate,
      toUpdate: toUpdate,
      toDelete: deletedIds,
    );
  }

  /// A locally minted id for a staff member who hasn't been saved yet.
  String newDistributorId() => _firestoreService.newDistributorId();

  // JOB OPERATIONS

  /// Adds [job] and returns it as saved, with its new id.
  ///
  /// Shown on the grid at once and saved through the write queue like every
  /// other schedule change ([_guardedMutation]). It used to wait for the
  /// transaction — and for a street-name lookup of up to 3 s before that —
  /// and transactions don't reach the local cache, so the cell sat empty
  /// until the server's snapshot came back. The returned future still
  /// completes only once the job is saved (callers such as the unfinished-
  /// areas assign rely on that), and fails after undoing the add if it
  /// cannot be saved.
  Future<Job> addJob(Job job) async {
    // Named from an intersection already in memory; an uncached one is
    // looked up after the save by [_nameBarePointLater], off the hot path.
    final normalized = _nameBarePointFromCache(
        _normalizeDropOffPoint(job, preferExisting: false));
    final minted = normalized.id.isEmpty;
    final id = minted ? _firestoreService.newJobId() : normalized.id;
    // As it is stored — the same shape undo compares against.
    final saved = Job.fromMap(id, normalized.toMap());

    await _ensureMonthStreamsCover(saved.date);
    try {
      await _guardedMutation<void>(
        dates: [saved.date],
        // Linked client-map areas filled in, as the stream would deliver it.
        applyOptimistic: () => _optimisticUpdateJob(saved.areaLinks.isEmpty
            ? saved
            : AreaLinkResolver.instance.hydrate(saved)),
        // A fresh id is one append, no read of the day; a job that came
        // with its id may be stored already, so it is merged in instead.
        persist: minted
            ? _appendOnce([saved])
            : () => _firestoreService.addJob(saved, saved.date),
      );
    } catch (e) {
      debugPrint('Error adding job: $e');
      rethrow;
    }
    _nameBarePointLater(id, saved);
    _pinClientAddressLater(saved);
    return saved;
  }

  /// The save step for jobs whose ids were just minted here: one append of
  /// them all ([FirestoreService.appendNewJobs]) — one round trip, no read
  /// of their days. Sent once: a retry after a timeout waits on the same
  /// write, which the Firestore SDK keeps sending until the server has it.
  /// Only a refused write is sent again.
  Future<void> Function() _appendOnce(List<Job> saved) {
    Future<void>? commit;
    return () => commit ??=
        _firestoreService.appendNewJobs(saved).onError<Object>((e, st) {
          commit = null;
          Error.throwWithStackTrace(e, st);
        });
  }

  /// Whether [date]'s month is streamed into [jobs] — the grid's month, or
  /// the next one once attached. A job missing from [jobs] in such a month
  /// is gone; in any other month it just isn't loaded.
  bool _monthIsLive(DateTime date) {
    bool same(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month;
    final next = _nextMonthSubscribedFor;
    return same(date, _currentMonth) || (next != null && same(date, next));
  }

  /// The live copy of job [id] on [date]: from memory when its month is
  /// streamed, else read from the server.
  Future<Job?> _currentJob(String id, DateTime date) async {
    final live = jobs.where((j) => j.id == id).firstOrNull;
    if (live != null || _monthIsLive(date)) return live;
    return (await _firestoreService.fetchJobsForDate(date))
        .where((j) => j.id == id)
        .firstOrNull;
  }

  /// Re-syncs the dropsheets of [dates] after a schedule write. Each day
  /// once, however many of its jobs moved; and not the day the open day
  /// planner keeps in step itself — a second sync there only read and
  /// rewrote the same sheet again.
  void _syncDropsheets(Iterable<DateTime> dates) {
    final r = _ref;
    final live = r != null && r.exists(dropsheetRiverpod)
        ? r.read(dropsheetRiverpod)
        : null;
    final dists = _distributors.isNotEmpty ? _distributors : null;
    final seen = <String>{};
    for (final d in dates) {
      final day = DateTime(d.year, d.month, d.day);
      if (!seen.add(_dayKey(day))) continue;
      if (live != null && live.liveSyncs(day)) continue;
      unawaited(DropsheetProvider.syncDateOneShot(
        day,
        firestoreService: _firestoreService,
        distributors: dists,
      ));
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

  /// [job] named from an intersection already in memory — no network call.
  /// Used when adding a job, so the save is never held up by a lookup;
  /// [_nameBarePointLater] names it once the lookup finishes.
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
        // The live copy (edits still saving included) — no read of the
        // whole day from the server when its month is on screen.
        final current = await _currentJob(jobId, saved.date);
        if (current == null) return;
        final stillBare = _barePointToName(current);
        if (stillBare == null || !_sameLatLng(stillBare, point)) return;
        await _updateJob(current.copyWith(workingAreas: [name]),
            background: true);
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
    _pointNameDebounce = Timer(const Duration(seconds: 2), () {
      unawaited(_backfillPointNames());
      _backfillClientAddressPins();
    });
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

    final edits = <Job>[];
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
      edits.add(current.copyWith(workingAreas: [name]));
    }
    // One schedule write for them all, not one transaction per job.
    try {
      await _saveBackgroundEdits(edits);
      for (final e in edits) {
        debugPrint('ScheduleProvider: named point job ${e.id} '
            '"${e.workingAreas.first}"');
      }
    } catch (e) {
      debugPrint('ScheduleProvider: naming point jobs failed: $e');
    }
  }

  /// Saves automatic follow-up edits (street names, address pins) of
  /// several jobs as ONE schedule write that joins the Undo steps they
  /// follow. If that write is refused because one of the jobs is gone
  /// (deleted or moved meanwhile), each job is saved on its own, so the
  /// others still go in.
  Future<void> _saveBackgroundEdits(List<Job> edited) async {
    if (edited.isEmpty) return;
    try {
      await updateJobs(edited, background: true);
    } on JobNotFoundException {
      if (edited.length == 1) rethrow;
      await Future.wait([
        for (final j in edited)
          _updateJob(j, background: true).catchError((Object e) =>
              debugPrint('ScheduleProvider: saving ${j.id} failed: $e')),
      ]);
    }
  }

  // ── Client address pins ──────────────────────────────────────────────────
  //
  // A worker given a junk collection or window cleaning client on the
  // Schedule gets the client's address as a map point, copied from the Job
  // List job, so their dropsheet drop-off lands at the house — see
  // services/client_address_pin.dart. Like naming, a follow-up: saves never
  // wait on the Job List or the geocoder.

  /// `jobId@clients` already looked up this session, so editing a job with
  /// no such client (a flyer job with no areas yet) doesn't query the Job
  /// List on every save. Changing the clients makes it eligible again.
  final Set<String> _clientPinAttempts = {};

  static String _clientPinKey(Job job) {
    final keys = ClientAddressPin.unpinnedClientKeys(job).toList()..sort();
    return '${job.id}@${keys.join('|')}';
  }

  void _pinClientAddressLater(Job saved) {
    if (saved.id.isEmpty || !ClientAddressPin.needsPin(saved)) return;
    if (!_clientPinAttempts.add(_clientPinKey(saved))) return;
    unawaited(_pinClientAddresses([saved]));
  }

  /// Pins jobs from today onwards that were given their client before pins
  /// existed (or while the Job List job was not there yet, in an earlier
  /// session). Past days are left as run.
  void _backfillClientAddressPins() {
    final today = scheduleToday();
    final todo = [
      for (final j in jobs)
        if (j.id.isNotEmpty &&
            !DateTime(j.date.year, j.date.month, j.date.day).isBefore(today) &&
            ClientAddressPin.needsPin(j) &&
            _clientPinAttempts.add(_clientPinKey(j)))
          j,
    ];
    if (todo.isNotEmpty) unawaited(_pinClientAddresses(todo));
  }

  /// Looks up the Job List jobs of [todo]'s clients in one go, geocodes the
  /// addresses that have no point of their own, then saves each job that
  /// still needs its pins as a background edit (joining the Undo step it
  /// follows). Built on the live job, which includes edits still saving.
  Future<void> _pinClientAddresses(List<Job> todo) async {
    final List<JobListItem> items;
    try {
      final months = {
        for (final j in todo) ...[
          DateTime(j.date.year, j.date.month - 1),
          DateTime(j.date.year, j.date.month),
          DateTime(j.date.year, j.date.month, j.date.day + 7),
        ],
      };
      items = await JobListService(FirebaseFirestore.instance)
          .getJobListItemsForClients(
              {for (final j in todo) ...j.clients}, months);
    } catch (e) {
      debugPrint('ScheduleProvider: client address lookup failed: $e');
      for (final j in todo) {
        _clientPinAttempts.remove(_clientPinKey(j));
      }
      return;
    }

    // Every job's addresses side by side — all jobs at once, not one job
    // after another — and each distinct address geocoded once.
    final geocoded = <String, Future<Map<String, double>?>>{};
    final pinsByJob = await Future.wait(
        [for (final job in todo) _addressPinsFor(job, items, geocoded)]);

    final edits = <Job>[];
    for (var i = 0; i < todo.length; i++) {
      final job = todo[i];
      final pins = pinsByJob[i];
      if (pins.isEmpty) continue;
      final current = await _currentJob(job.id, job.date);
      if (current == null || !ClientAddressPin.needsPin(current)) continue;
      final wanted = ClientAddressPin.unpinnedClientKeys(current);
      pins.removeWhere((key, _) => !wanted.contains(key));
      if (pins.isEmpty) continue;
      edits.add(ClientAddressPin.apply(current, pins));
    }

    // One schedule write for every pinned job of the allocation.
    try {
      await _saveBackgroundEdits(edits);
      for (final e in edits) {
        debugPrint('ScheduleProvider: pinned client address '
            'for ${_jobLabel(e)} (${e.id})');
      }
    } catch (e) {
      debugPrint('ScheduleProvider: pinning client addresses failed: $e');
    }
  }

  /// [job]'s client address pins (client key → Job List job and its pin),
  /// geocoding addresses without a point of their own through [geocoded],
  /// shared across one run so an address is looked up once.
  Future<Map<String, (JobListItem, CustomPolygon)>> _addressPinsFor(
    Job job,
    List<JobListItem> items,
    Map<String, Future<Map<String, double>?>> geocoded,
  ) async {
    final matches = ClientAddressPin.matchItems(job, items);
    final pins = <String, (JobListItem, CustomPolygon)>{};
    await Future.wait(matches.entries.map((e) async {
      final item = e.value;
      var pin = ClientAddressPin.pointFromItem(item);
      if (pin == null) {
        final address = ClientAddressPin.addressText(item);
        if (address.isEmpty || ClientAddressPin.isMapLinkOrUrl(address)) {
          return;
        }
        try {
          final c = await geocoded.putIfAbsent(
              address,
              () => GeocodingService()
                  .geocodeAddress('$address, Western Cape, South Africa'));
          if (c == null) return;
          pin = ClientAddressPin.pointAt(item, LatLng(c['lat']!, c['lng']!));
        } catch (err) {
          debugPrint('ScheduleProvider: geocoding "$address" failed: $err');
          return;
        }
      }
      pins[e.key] = (item, pin);
    }));
    return pins;
  }

  /// A client taken off a schedule job takes its address pin along. Pins
  /// marked with their client go in the same save ([ClientAddressPin
  /// .withoutStalePins]); this follow-up clears the unmarked ones the Job
  /// List's address search copied onto schedule jobs before pins were
  /// marked, which can only be recognised against the removed client's
  /// Junk & Stuff / Happy Sun Job List job.
  void _unpinRemovedClientsLater(Job? previous, Job saved) {
    if (previous == null || saved.id.isEmpty) return;
    final kept = saved.clients.map(jobListClientKey).toSet();
    final removed = [
      for (final c in previous.clients)
        if (jobListClientKey(c).isNotEmpty &&
            !kept.contains(jobListClientKey(c)))
          c,
    ];
    if (removed.isEmpty) return;
    if (!saved.workMaps.any((p) => p.isPoint && p.description.trim().isEmpty)) {
      return;
    }
    unawaited(_unpinRemovedClients(saved, removed));
  }

  Future<void> _unpinRemovedClients(Job saved, List<String> removed) async {
    try {
      final d = saved.date;
      final removedKeys = removed.map(jobListClientKey).toSet();
      final items = (await JobListService(FirebaseFirestore.instance)
              .getJobListItemsForClients(removed, {
        DateTime(d.year, d.month - 1),
        DateTime(d.year, d.month),
        DateTime(d.year, d.month, d.day + 7),
      }))
          .where((i) =>
              removedKeys.contains(jobListClientKey(i.client)) &&
              ClientAddressPin.isCallOutJobType(i.jobTypeId))
          .toList();
      if (items.isEmpty) return;

      final current = jobs.where((j) => j.id == saved.id).firstOrNull;
      if (current == null) return;
      // Put back since? Then the client is on the job again — keep its pin.
      final back = current.clients.map(jobListClientKey).toSet();
      final gone =
          items.where((i) => !back.contains(jobListClientKey(i.client)));
      final unpinned = ClientAddressPin.withoutPins(current,
          (p) => gone.any((i) => ClientAddressPin.isUnmarkedItemPin(p, i)));
      if (identical(unpinned, current)) return;
      await _updateJob(unpinned, background: true);
      debugPrint('ScheduleProvider: removed address pin of '
          '${removed.join(', ')} from ${_jobLabel(current)} (${saved.id})');
    } catch (e) {
      debugPrint('ScheduleProvider: unpinning ${saved.id} failed: $e');
    }
  }

  /// Saves [job]. Not an Undo step on the Schedule — other screens (track
  /// editor, day planner, map views) call this; the Schedule's own edits go
  /// through the `...WithUndo` methods.
  Future<void> updateJob(Job job) => _updateJob(job);

  /// [updateJob] for several jobs as one change: one on-screen update, one
  /// dropsheet update and one schedule transaction, instead of one of each
  /// per job. Combining distributors onto one drop point saved them one by
  /// one, each save rebuilding the grid, map and dropsheet, which froze the
  /// day planner. [onApplied] runs once the change shows on screen, before
  /// the save completes.
  ///
  /// [background] marks automatic follow-ups (see [_updateJob]).
  Future<void> updateJobs(List<Job> jobs,
      {VoidCallback? onApplied, bool background = false}) async {
    if (jobs.isEmpty) {
      onApplied?.call();
      return;
    }
    if (jobs.length == 1) {
      final write = _updateJob(jobs.single, background: background);
      onApplied?.call();
      return write;
    }
    final live = {for (final j in this.jobs) j.id: j};
    final previousById = <String, Job>{};
    final normalized = <Job>[];
    for (final job in jobs) {
      final previous = live[job.id];
      if (previous != null) previousById[job.id] = previous;
      normalized.add(_nameBarePointFromCache(_normalizeDropOffPoint(
          ClientAddressPin.withoutStalePins(job),
          previous: previous)));
    }
    final write = _guardedMutation<void>(
      dates: [for (final j in normalized) j.date],
      applyOptimistic: () => _optimisticUpdateJobs(normalized),
      persist: () => _firestoreService.updateJobs(normalized),
    );
    if (background) {
      for (final j in normalized) {
        final previous = previousById[j.id];
        if (previous != null) _foldIntoSteps(previous, j);
      }
    }
    _notifyDropsheetOfCoordChangesBatch(previousById, normalized);
    onApplied?.call();
    try {
      await write;
    } catch (_) {
      _notifyDropsheetOfCoordChangesBatch(
        {for (final j in normalized) j.id: j},
        [for (final j in normalized) previousById[j.id] ?? j],
      );
      rethrow;
    }
    for (final j in normalized) {
      _nameBarePointLater(j.id, j);
      _pinClientAddressLater(j);
      _unpinRemovedClientsLater(previousById[j.id], j);
    }
  }

  /// [_optimisticUpdateJob] for several jobs with a single notification.
  void _optimisticUpdateJobs(List<Job> jobs) {
    final recording = _recordingWrite;
    var changed = false;
    for (final job in jobs) {
      if (recording != null) {
        recording.upserts[job.id] = job;
        recording.removes.remove(job.id);
      }
      changed = _upsertLocal(job) || changed;
    }
    if (changed) {
      _invalidateCaches();
      notifyListeners();
    }
  }

  /// [undoLabel] records the edit as a Schedule Undo step. [background]
  /// marks an automatic follow-up (naming a point job), which joins the step
  /// it follows instead of making that step look changed-since.
  Future<void> _updateJob(Job job,
      {String? undoLabel, bool background = false}) async {
    // Edits never wait on the map server: only an already-known name is
    // applied here; [_nameBarePointLater] fills it in otherwise.
    final previous = jobs.where((j) => j.id == job.id).firstOrNull;
    final normalized = _nameBarePointFromCache(_normalizeDropOffPoint(
        ClientAddressPin.withoutStalePins(job),
        previous: previous));
    // Optimistic UI: surface the change locally before the Firestore
    // round-trip so the calling screen (work-areas map, print map, day
    // planner, etc.) reflects the new state instantly; rolled back
    // exactly if the transactional write fails.
    final write = _guardedMutation<void>(
      dates: [normalized.date],
      applyOptimistic:
          previous != null ? () => _optimisticUpdateJob(normalized) : null,
      persist: () => _firestoreService.updateJob(normalized, normalized.date),
    );
    if (undoLabel != null && previous != null) {
      _recordStep(undoLabel, [previous], [normalized]);
    } else if (background && previous != null) {
      _foldIntoSteps(previous, normalized);
    }
    await _withDropsheetCoords(previous, normalized, write);
    _nameBarePointLater(normalized.id, normalized);
    _pinClientAddressLater(normalized);
    _unpinRemovedClientsLater(previous, normalized);
  }

  /// Moves the dropsheet's pins for [updated] at once, alongside the
  /// optimistic schedule change, instead of after [write] commits — the
  /// write queue retries forever while offline, which used to leave the
  /// dropsheet on the old spot indefinitely. Put back if [write] fails.
  Future<void> _withDropsheetCoords(
      Job? previous, Job updated, Future<void> write) async {
    _notifyDropsheetOfCoordChanges(previous, updated);
    try {
      await write;
    } catch (_) {
      if (previous != null) _notifyDropsheetOfCoordChanges(updated, previous);
      rethrow;
    }
  }

  /// Deletes the job into the Recycle Bin. [onBinned] receives the bin
  /// entry id once the delete is saved.
  Future<void> deleteJob(String jobId,
      [DateTime? targetDate,
      void Function(String? binEntryId)? onBinned]) async {
    // Find the job to get its date for proper monthly context
    final job = jobs.where((j) => j.id == jobId).firstOrNull;
    final jobDate = targetDate ?? job?.date ?? _currentMonth;
    await _guardedMutation<void>(
      dates: [jobDate],
      // Remove locally right away so the cell empties without waiting for
      // the stream; restored if the delete fails.
      applyOptimistic: () => _optimisticRemoveJob(jobId),
      persist: () async =>
          onBinned?.call(await _firestoreService.deleteJob(jobId, jobDate)),
    );
    // Scrub any orphaned dropoff task from the affected date's
    // dropsheet — the live `DropsheetProvider` only auto-syncs for
    // today + next planning day, so this catches every other date.
    _syncDropsheets([jobDate]);
  }

  Future<void> moveJobBetweenDates(Job originalJob, Job movedJob) =>
      _guardedMutation<void>(
        dates: [originalJob.date, movedJob.date],
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
    _syncDropsheets([originalJob.date, movedJob.date]);
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

  // ── Schedule Undo / Redo ────────────────────────────────────────────────
  //
  // The `...WithUndo` methods are the Schedule screen's own edits; each
  // records a step (the jobs before → after) in the Schedule's undo history.
  // Plain updateJob / deleteJob calls from other screens are not recorded.
  //
  // Undo and redo replace exactly what the step left with what it found, in
  // one logged transaction ([FirestoreService.restoreScheduleJobs]) through
  // the same write queue as every other edit, so an undo never overtakes
  // the write it reverts. A job changed since (another user, a Job List
  // cascade) makes the step a conflict: it is skipped, never overwritten.

  ScreenUndoHistory? get _undoHistory =>
      _ref?.read(undoHistoryRiverpod(UndoKey.schedule));

  /// Recorded steps still reachable from the history, newest last, so an
  /// automatic follow-up can update the step it follows.
  final List<_ScheduleStep> _undoSteps = [];

  _ScheduleStep? _recordStep(String label, List<Job> before, List<Job> after,
      {bool isDelete = false}) {
    final history = _undoHistory;
    if (history == null || history.isApplying) return null;
    final step = _ScheduleStep(
      {for (final j in before) j.id: j},
      {for (final j in after) j.id: j},
      isDelete: isDelete,
    );
    _undoSteps.add(step);
    if (_undoSteps.length > kUndoDepth * 2) _undoSteps.removeAt(0);
    step.entry = UndoEntry(
      label: label,
      undo: () => _applyStep(step, toBefore: true),
      redo: () => _applyStep(step, toBefore: false),
    );
    history.record(step.entry!);
    return step;
  }

  /// An automatic change to [previous] (now [updated]) joins every step
  /// that left the job exactly as [previous].
  void _foldIntoSteps(Job previous, Job updated) {
    final fp = _fingerprint(previous);
    for (final step in _undoSteps) {
      final after = step.after[previous.id];
      if (after != null && _fingerprint(after) == fp) {
        step.after[previous.id] = updated;
      }
    }
  }

  Future<void> _applyStep(_ScheduleStep step, {required bool toBefore}) async {
    final expected = toBefore ? step.after : step.before;
    final replacement = toBefore ? step.before : step.after;
    final binned = await swapScheduleJobs(
      expected: expected.values.toList(),
      replacement: replacement.values.toList(),
      action: toBefore ? 'undo' : 'redo',
      // Redoing a delete deletes into the bin again; undoing one takes it
      // back out.
      binRemovals: step.isDelete && !toBefore,
      restoredBinIds: [
        for (final id in replacement.keys)
          if (step.binIds[id] != null) step.binIds[id]!,
      ],
    );
    replacement.keys.forEach(step.binIds.remove);
    step.binIds.addAll(binned);
  }

  /// Replaces exactly [expected] with [replacement] — shown at once, saved
  /// through the write queue as one verified transaction. Throws
  /// [UndoConflict] (after rolling the screen back) when any expected job
  /// has changed. For undoing Schedule steps and the schedule side of Job
  /// List edits. Returns the bin entry ids of jobs binned by [binRemovals].
  Future<Map<String, String>> swapScheduleJobs({
    required List<Job> expected,
    required List<Job> replacement,
    required String action,
    bool binRemovals = false,
    List<String> restoredBinIds = const [],
  }) async {
    final replacementIds = {for (final j in replacement) j.id};
    final dates = <String, DateTime>{
      for (final j in [...expected, ...replacement])
        DateFormat('yyyy-MM-dd').format(j.date): j.date,
    };
    var binned = const <String, String>{};
    await _guardedMutation<void>(
      dates: dates.values,
      applyOptimistic: () {
        for (final j in expected) {
          if (!replacementIds.contains(j.id)) _optimisticRemoveJob(j.id);
        }
        replacement.forEach(_optimisticUpdateJob);
      },
      persist: () async {
        for (final d in dates.values) {
          await _ensureMonthStreamsCover(d);
        }
        binned = await _firestoreService.restoreScheduleJobs(
          expected: expected,
          replacement: replacement,
          action: action,
          binRemovals: binRemovals,
          restoredBinIds: restoredBinIds,
        );
      },
    );
    _syncDropsheets(dates.values);
    return binned;
  }

  /// The live copy of [job] (what is on screen now), falling back to [job].
  Job _live(Job job) => jobs.where((j) => j.id == job.id).firstOrNull ?? job;

  static String _jobLabel(Job job) {
    final clients = job.clients.where((c) => c.trim().isNotEmpty).join(', ');
    return clients.isEmpty ? 'job' : clients;
  }

  /// Restores a schedule job from the Recycle Bin, marking [entryRef]
  /// restored in the same transaction (see the bin's schedule handler).
  Future<void> restoreJobFromBin(
    Map<String, dynamic> payload,
    DocumentReference<Map<String, dynamic>> entryRef,
    Map<String, dynamic> restoredFields,
  ) async {
    final raw = Map<String, dynamic>.from(payload['job'] as Map);
    final job = Job.fromMap(raw['id'] as String, raw);
    await _ensureMonthStreamsCover(job.date);
    await _guardedMutation<void>(
      dates: [job.date],
      applyOptimistic: () => _optimisticUpdateJob(job),
      persist: () => _firestoreService.restoreScheduleJobFromBin(
          payload, entryRef, restoredFields),
    );
    _syncDropsheets([job.date]);
  }

  Future<void> addJobWithUndo(Job job, DateTime targetDate) async {
    final saved =
        await addJob(_normalizeDropOffPoint(job, preferExisting: false));
    _recordStep('Add ${_jobLabel(saved)}', const [], [saved]);
  }

  /// Adds a whole allocation as ONE schedule write and ONE Undo step.
  ///
  /// Every job shows on the grid straight away. They used to be saved as one
  /// transaction each, one after another through the write queue — the
  /// audit logs show a median of 2.5 s per job and up to 3¾ minutes for a
  /// 19-job allocation on a slow connection. Now every affected day is read
  /// and written in a single transaction.
  ///
  /// They are on the grid before the first await that waits on the server,
  /// so a caller need not wait. The returned future completes once the
  /// server has them, and fails after taking them all back off the grid if
  /// they cannot be saved.
  Future<List<Job>> addJobsWithUndo(List<Job> jobs,
      {String? undoLabel}) async {
    if (jobs.isEmpty) return const [];
    // Whether every id is minted here, so the lot can be appended without
    // reading their days ([_appendOnce]).
    var allMinted = true;
    final saved = <Job>[
      for (final job in jobs)
        () {
          final normalized = _nameBarePointFromCache(
              _normalizeDropOffPoint(job, preferExisting: false));
          if (normalized.id.isNotEmpty) allMinted = false;
          final id = normalized.id.isEmpty
              ? _firestoreService.newJobId()
              : normalized.id;
          // As it is stored — the same shape undo compares against.
          return Job.fromMap(id, normalized.toMap());
        }(),
    ];

    final months = <DateTime>{
      for (final j in saved) DateTime(j.date.year, j.date.month),
    };
    for (final month in months) {
      await _ensureMonthStreamsCover(month);
    }

    final write = _guardedMutation<void>(
      dates: [for (final j in saved) j.date],
      applyOptimistic: () => _optimisticUpdateJobs([
        // Linked client-map areas filled in, as the stream would deliver it.
        for (final j in saved)
          j.areaLinks.isEmpty ? j : AreaLinkResolver.instance.hydrate(j),
      ]),
      // New ids: one append for the lot, no read of their days. Otherwise
      // one transaction that merges any already stored.
      persist: allMinted
          ? _appendOnce(saved)
          : () => _firestoreService.addJobs(saved),
    );
    try {
      await write;
    } catch (e) {
      debugPrint('Error adding ${saved.length} jobs: $e');
      rethrow;
    }

    _recordStep(
      undoLabel ??
          (saved.length == 1
              ? 'Add ${_jobLabel(saved.single)}'
              : 'Add ${saved.length} jobs for ${_jobLabel(saved.first)}'),
      const [],
      saved,
    );
    for (final j in saved) {
      _nameBarePointLater(j.id, j);
    }
    // One lookup of the Job List for the whole allocation, not one per job.
    final toPin = [
      for (final j in saved)
        if (ClientAddressPin.needsPin(j) &&
            _clientPinAttempts.add(_clientPinKey(j)))
          j,
    ];
    if (toPin.isNotEmpty) unawaited(_pinClientAddresses(toPin));
    return saved;
  }

  Future<void> updateJobWithUndo(
      Job originalJob, Job modifiedJob, DateTime targetDate) async {
    final normalized = _normalizeDropOffPoint(
        ClientAddressPin.withoutStalePins(modifiedJob),
        previous: _live(originalJob));

    // Check if we're moving the job to a different date
    if (!_isSameDay(originalJob.date, normalized.date)) {
      final before = _live(originalJob);
      final write = _guardedMutation<void>(
        dates: [originalJob.date, normalized.date],
        applyOptimistic: () => _optimisticUpdateJob(normalized),
        persist: () => _persistMoveBetweenDates(originalJob, normalized),
      );
      _recordStep('Move ${_jobLabel(normalized)}', [before], [normalized]);
      // The move re-syncs both dates' sheets itself once it commits.
      await write;
      _unpinRemovedClientsLater(before, normalized);
    } else {
      // _updateJob applies its own optimistic update, rollback, and
      // dropsheet coordinate notification.
      await _updateJob(normalized,
          undoLabel: _editLabel(originalJob, normalized));
    }
  }

  /// "Assign Smith to Thabo", "Edit Smith"… for the Undo tooltip.
  String _editLabel(Job before, Job after) {
    final what = _jobLabel(after);
    if (before.distributorId != after.distributorId) return 'Reassign $what';
    if (before.statusId != after.statusId) return 'Change status of $what';
    if (!listEquals(before.clients, after.clients)) return 'Edit clients';
    return 'Edit $what';
  }

  Future<void> moveJobBetweenDatesWithUndo(Job originalJob, Job movedJob,
      DateTime originalDate, DateTime newDate) async {
    final before = _live(originalJob);
    final write = _guardedMutation<void>(
      dates: [originalJob.date, movedJob.date],
      applyOptimistic: () => _optimisticUpdateJob(movedJob),
      persist: () => _persistMoveBetweenDates(originalJob, movedJob),
    );
    _recordStep('Move ${_jobLabel(movedJob)}', [before], [movedJob]);
    await write;
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

    final write = _guardedMutation<void>(
      dates: [
        for (final (original, moved) in moves) ...[original.date, moved.date],
      ],
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
        _syncDropsheets([
          for (final (original, moved) in moves) ...[original.date, moved.date],
        ]);
      },
    );
    _recordStep(
      moves.length == 1
          ? 'Move ${_jobLabel(moves.single.$2)}'
          : 'Move ${moves.length} jobs',
      [for (final (original, _) in moves) original],
      [for (final (_, moved) in moves) moved],
    );
    await write;
    return plan;
  }

  /// Takes [job] off the schedule because it now lives in the unfinished
  /// work areas panel. Not a delete: no Recycle Bin copy, no Undo step.
  Future<void> moveJobToUnfinished(Job job) async {
    await _guardedMutation<void>(
      dates: [job.date],
      applyOptimistic: () => _optimisticRemoveJob(job.id),
      persist: () => _firestoreService.removeJobMovedElsewhere(
          job.id, job.date, 'moveToUnfinished'),
    );
    _syncDropsheets([job.date]);
  }

  /// Deletes [jobs] into the Recycle Bin as ONE schedule write and ONE Undo
  /// step, with no confirmation — Undo puts them all back. They leave the
  /// grid at once; the returned future completes once the server has the
  /// delete, or fails after putting them back. [onRecorded] receives the
  /// Undo step, for a toast's Undo button (`undoEntryAction`).
  Future<void> deleteJobsWithUndo(List<Job> jobs,
      {void Function(UndoEntry entry)? onRecorded}) async {
    final byId = <String, Job>{
      for (final j in jobs)
        if (j.id.isNotEmpty) j.id: _live(j),
    };
    if (byId.isEmpty) return;
    final before = byId.values.toList();
    _ScheduleStep? step;
    final write = _guardedMutation<void>(
      dates: [for (final j in before) j.date],
      applyOptimistic: () => _optimisticRemoveJobs(byId.keys),
      persist: () async {
        final binned = await _firestoreService
            .deleteJobs({for (final j in before) j.id: j.date});
        step?.binIds.addAll(binned);
      },
    );
    step = _recordStep(
      before.length == 1
          ? 'Delete ${_jobLabel(before.single)}'
          : 'Delete ${before.length} jobs',
      before,
      const [],
      isDelete: true,
    );
    final entry = step?.entry;
    if (entry != null) onRecorded?.call(entry);
    await write;
    // Scrub their drop-off tasks from the affected days' dropsheets.
    _syncDropsheets([for (final j in before) j.date]);
  }

  /// [_optimisticRemoveJob] for several jobs with a single notification.
  void _optimisticRemoveJobs(Iterable<String> ids) {
    final recording = _recordingWrite;
    for (final id in ids) {
      if (recording != null) {
        recording.removes.add(id);
        recording.upserts.remove(id);
      }
      _removeLocal(id);
    }
    _invalidateCaches();
    notifyListeners();
  }

  Future<void> deleteJobWithUndo(Job job, DateTime targetDate) async {
    final before = _live(job);
    _ScheduleStep? step;
    final write = deleteJob(job.id, targetDate, (binId) {
      if (binId != null) step?.binIds[job.id] = binId;
    });
    step = _recordStep('Delete ${_jobLabel(before)}', [before], const [],
        isDelete: true);
    await write;
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

    _syncDropsheets(affected.values);

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
    // _updateJob handles optimistic apply + rollback.
    await _updateJob(updatedJob,
        undoLabel: 'Change status of ${_jobLabel(job)}');
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
    final before = [_live(draggedJob), _live(targetJob)];

    final write = _guardedMutation<void>(
      dates: [draggedJob.date, targetJob.date],
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
    _recordStep('Swap ${_jobLabel(draggedJob)} and ${_jobLabel(targetJob)}',
        before, [newDraggedJob, newTargetJob]);
    await write;
  }

  Future<void> combineJobsWithUndo(Job draggedJob, Job targetJob,
      Job combinedJob, DateTime targetDate) async {
    final before = [_live(draggedJob), _live(targetJob)];
    final write = _guardedMutation<void>(
      dates: [draggedJob.date, targetJob.date],
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
    _recordStep('Combine ${_jobLabel(draggedJob)} into ${_jobLabel(targetJob)}',
        before, [combinedJob]);
    await write;
  }

  Future<void> copyAndCombineJobsWithUndo(
      Job targetJob, Job combinedJob, DateTime targetDate) async {
    // _updateJob handles optimistic apply + rollback.
    await _updateJob(combinedJob,
        undoLabel: 'Combine into ${_jobLabel(targetJob)}');
  }

  // Undo/Redo functionality for map operations - DISABLED
  Future<void> addPolygonWithUndo(
      String jobId, CustomPolygon polygon, DateTime targetDate) async {
    // Bypass command pattern - add polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedJob = job.copyWith(
      workMaps: [...job.workMaps, polygon],
    );
    await _updateJob(updatedJob, undoLabel: 'Add area ${polygon.name}');
  }

  Future<void> editPolygonWithUndo(String jobId, CustomPolygon originalPolygon,
      CustomPolygon modifiedPolygon, DateTime targetDate) async {
    // Bypass command pattern - edit polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedMaps = job.workMaps
        .map((p) => p.name == originalPolygon.name ? modifiedPolygon : p)
        .toList();
    final updatedJob = job.copyWith(workMaps: updatedMaps);
    await _updateJob(updatedJob,
        undoLabel: 'Edit area ${modifiedPolygon.name}');
  }

  Future<void> deletePolygonWithUndo(
      String jobId, CustomPolygon polygon, DateTime targetDate) async {
    // Bypass command pattern - delete polygon directly
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedMaps =
        job.workMaps.where((p) => p.name != polygon.name).toList();
    final updatedJob = job.copyWith(workMaps: updatedMaps);
    await _updateJob(updatedJob, undoLabel: 'Remove area ${polygon.name}');
  }

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

  /// Every job in the months [months] fall in, read once — for work that
  /// must see months the schedule isn't streaming. Jobs already held in
  /// memory replace their fetched copy, so unsaved edits are not lost.
  Future<List<Job>> fetchJobsForMonths(Iterable<DateTime> months) async {
    final starts = {for (final m in months) DateTime(m.year, m.month)};
    final fetched = await Future.wait(
        starts.map((m) => _firestoreService.streamJobsForMonth(m).first));
    final byId = {
      for (final list in fetched)
        for (final j in list) j.id: j,
    };
    final wanted = {for (final m in starts) '${m.year}-${m.month}'};
    for (final j in jobs) {
      if (wanted.contains('${j.date.year}-${j.date.month}')) byId[j.id] = j;
    }
    return byId.values.toList();
  }

  /// Renames client [from] to [to] on [jobs] — the client fields only (see
  /// [FirestoreService.renameClientOnJobs]). Returns how many changed.
  Future<int> renameClientOnJobs(
    List<Job> jobs, {
    required String from,
    required String to,
  }) async {
    if (jobs.isEmpty) return 0;
    final changed = await _firestoreService.renameClientOnJobs(
      {for (final j in jobs) j.id: j.date},
      from: from,
      to: to,
    );
    // Day planner tasks carry the client name too.
    _syncDropsheets([for (final j in jobs) j.date]);
    return changed;
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

/// One Schedule Undo step: the jobs it touched as they were before and as it
/// left them (an id missing from [before] was added; from [after], deleted).
/// [after] is updated in place by automatic follow-ups ([_foldIntoSteps]).
class _ScheduleStep {
  final Map<String, Job> before;
  final Map<String, Job> after;
  final bool isDelete;

  /// Job id → its current Recycle Bin entry, while a deleted job is binned.
  final Map<String, String> binIds = {};

  /// The entry in the Schedule's undo history, so a toast's Undo can check
  /// the step is still the newest.
  UndoEntry? entry;

  _ScheduleStep(this.before, this.after, {this.isDelete = false});
}
