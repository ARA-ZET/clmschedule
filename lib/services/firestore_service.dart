import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:intl/intl.dart' show DateFormat;
import '../models/distributor.dart';
import 'area_link_resolver.dart';
import '../models/job_area_link.dart';
import '../models/job.dart';
import '../models/work_area.dart';
import '../models/work_suburb.dart';
import '../models/collection_job.dart';
import '../models/schedule_confirmation_status.dart';
import '../models/custom_polygon.dart';
import '../shareable_maps/utils/linked_map_polygons.dart'
    show polygonGeometryKey;
import '../utils/schedule_time.dart';
import '../recycle_bin/recycle_bin_entry.dart';
import '../recycle_bin/recycle_bin_writer.dart';
import 'schedule_restore.dart';
import 'daily_service.dart';
import 'schedule_mutation_types.dart';

class FirestoreService {
  final DailyService _dailyService;
  final FirebaseFirestore _firestore;

  /// [firestore] is only passed by tests, which hand in an in-memory
  /// instance; the app always uses the real one.
  FirestoreService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance,
        _dailyService =
            DailyService(firestore ?? FirebaseFirestore.instance);

  /// Resolves the identity recorded on schedule audit logs. Set by
  /// ScheduleProvider (which knows the app user's display name); other
  /// FirestoreService instances fall back to FirebaseAuth.
  ScheduleLogUser Function()? logUserResolver;

  /// Resolves the signed-in user for the audit log. Throws
  /// [ScheduleAuthRequiredException] when nobody is signed in — every
  /// schedule change must be attributable, so unauthenticated writes are
  /// rejected before the transaction starts (the provider rolls back its
  /// optimistic state and the UI surfaces the error).
  ScheduleLogUser _resolveLogUser() {
    final resolved = logUserResolver?.call();
    if (resolved != null && resolved.uid != null) return resolved;

    // Resolver missing or its auth state not yet populated — fall back to
    // FirebaseAuth directly.
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw ScheduleAuthRequiredException();
    }
    return ScheduleLogUser(
      uid: user.uid,
      email: user.email,
      name: resolved?.name ?? user.displayName ?? user.email,
    );
  }

  // Transactions are capped at 500 writes; each affected day costs two
  // (day doc + log doc).
  static const int _maxMutationDates = 250;

  /// Runs a schedule mutation as a single Firestore transaction:
  /// reads every affected day doc, applies [mutate] to the in-memory state,
  /// writes back the changed day docs and one audit-log doc per changed day
  /// (in `schedules/{month}/logs`) — all atomically. Either everything
  /// commits or nothing does.
  ///
  /// [mutate] must be pure over the [ScheduleTxContext]: the context is
  /// rebuilt from fresh reads whenever the transaction retries on contention.
  /// Days whose content is unchanged after [mutate] are neither written nor
  /// logged, making no-op mutations (e.g. deleting an already-deleted job)
  /// idempotent.
  Future<T> _runScheduleMutation<T>({
    required String action,
    required List<DateTime> dates,
    required T Function(ScheduleTxContext ctx) mutate,
    List<String> affectedJobIds = const [],
    void Function(Transaction tx, ScheduleTxContext ctx)? extraWrites,
  }) async {
    final datesByKey = <String, DateTime>{};
    for (final d in dates) {
      final normalized = DateTime(d.year, d.month, d.day);
      datesByKey[_dailyService.getDailyDocumentId(normalized)] = normalized;
    }
    if (datesByKey.isEmpty) {
      throw ArgumentError('Schedule mutation "$action" has no affected dates');
    }
    if (datesByKey.length > _maxMutationDates) {
      throw ArgumentError(
        'Schedule mutation "$action" touches ${datesByKey.length} days; '
        'maximum is $_maxMutationDates per operation',
      );
    }

    // The month index (month pickers and the next-month probe read it). The
    // transaction creates a missing day doc itself, so the per-day existence
    // check that used to run here — a server read and a write before the
    // transaction, for every empty day — isn't needed.
    final monthsByKey = <String, DateTime>{
      for (final d in datesByKey.values) _dailyService.getMonthlyDocumentId(d): d,
    };
    await Future.wait(
      monthsByKey.values.map(_dailyService.ensureScheduleMonthIndexExists),
    );

    final user = _resolveLogUser();
    final opId = _newJobId();
    final allDateKeys = datesByKey.keys.toList()..sort();

    return _firestore.runTransaction<T>((tx) async {
      // All reads must happen before any write.
      final refsByKey = <String, DocumentReference>{};
      final beforeByKey = <String, Map<String, dynamic>?>{};
      final jobsByKey = <String, List<Map<String, dynamic>>>{};

      for (final entry in datesByKey.entries) {
        refsByKey[entry.key] = _dailyService.getScheduleDailyDoc(entry.value);
      }
      // On web the day reads go out together: a 19-day allocation used to
      // pay 19 round trips one after another before it could commit. Native
      // platforms keep one read at a time, as before.
      final snapsByKey = <String, DocumentSnapshot>{};
      if (kIsWeb && refsByKey.length > 1) {
        final keys = refsByKey.keys.toList();
        final snaps =
            await Future.wait([for (final k in keys) tx.get(refsByKey[k]!)]);
        for (var i = 0; i < keys.length; i++) {
          snapsByKey[keys[i]] = snaps[i];
        }
      } else {
        for (final entry in refsByKey.entries) {
          snapsByKey[entry.key] = await tx.get(entry.value);
        }
      }

      for (final entry in datesByKey.entries) {
        final snap = snapsByKey[entry.key]!;
        final data = snap.exists && snap.data() != null
            ? deepCopyMap(snap.data() as Map)
            : null;
        beforeByKey[entry.key] = data;
        jobsByKey[entry.key] = data == null
            ? <Map<String, dynamic>>[]
            : (data['jobs'] as List? ?? const [])
                .map((e) => deepCopyMap(e as Map))
                .toList();
      }

      final ctx = ScheduleTxContext(
        jobsByDateKey: jobsByKey,
        beforeByDateKey: beforeByKey,
        dateKeyFor: _dailyService.getDailyDocumentId,
      );
      final result = mutate(ctx);

      // ── Enforce schedule invariants on the mutation result ──
      // Runs on EVERY schedule mutation, so add/update/delete/move/swap/
      // combine/reallocate all inherit the same protection. Guarantees, for
      // each affected day, that:
      //  1. every job's `date` field matches the day document it lives in
      //     (the key ↔ placement relationship — time-of-day is preserved);
      //  2. no job id is duplicated within a day (the freshest write wins);
      //  3. no job id spans two of the affected days (fail-closed guard
      //     that aborts the whole transaction rather than persist a split).
      _enforceScheduleInvariants(datesByKey, jobsByKey);

      for (final entry in datesByKey.entries) {
        final key = entry.key;
        final date = entry.value;
        final before = beforeByKey[key];
        final newJobs = jobsByKey[key]!;
        final fieldUpdates = ctx.dayFieldUpdates[key] ?? const {};

        final jobsChanged =
            !deepEquals((before?['jobs'] as List?) ?? const [], newJobs);
        if (!jobsChanged && fieldUpdates.isEmpty) continue;

        final after = <String, dynamic>{
          if (before != null)
            ...before
          else ...{
            'created': FieldValue.serverTimestamp(),
            'date': key,
            'timestamp': Timestamp.fromDate(scheduleCivilToInstant(date)),
          },
          'jobs': newJobs,
        };
        fieldUpdates.forEach((field, value) {
          if (value == null) {
            after.remove(field);
          } else {
            after[field] = value;
          }
        });

        tx.set(refsByKey[key]!, after);

        final monthId = _dailyService.getMonthlyDocumentId(date);
        final logRef = _firestore
            .collection('schedules')
            .doc(monthId)
            .collection('logs')
            .doc();
        // v2: only what changed (see scheduleDayLogDiff). v1 logs held the
        // whole day doc before and after.
        tx.set(logRef, {
          'schemaVersion': 2,
          'opId': opId,
          'action': action,
          'timestamp': FieldValue.serverTimestamp(),
          'userId': user.uid,
          'userEmail': user.email,
          'userName': user.name,
          'month': monthId,
          'dateKey': key,
          'affectedDates': allDateKeys,
          'affectedJobIds': affectedJobIds,
          'dayExisted': before != null,
          ...scheduleDayLogDiff(beforeDoc: before, afterDoc: after),
        });
      }

      // Writes that must commit with the schedule change, e.g. the Recycle
      // Bin copy of a deleted job.
      extraWrites?.call(tx, ctx);

      return result;
    });
  }

  /// Adds brand-new jobs WITHOUT reading their days: each job is appended to
  /// its day's `jobs` array with `arrayUnion`, and the day's audit log is
  /// written alongside, in ONE batched write — one round trip, and only the
  /// new jobs go over the wire. [addJobs] reads every affected day doc (all
  /// its jobs and polygons), then uploads it whole again.
  ///
  /// For jobs whose ids were just minted on this device ([newJobId]) only.
  /// Such an id can't be on any day yet, and each job's `date` is stamped
  /// to its day as [_runScheduleMutation]'s integrity pass would, so the
  /// schedule invariants hold without the read. A job that may already be
  /// stored must go through [addJob] / [addJobs], which replace it.
  ///
  /// Call it ONCE per add and, on a timeout, wait on the same future: the
  /// Firestore SDK keeps the write queued (offline too) until the server
  /// takes it. Sending a second append could land after a later edit of
  /// the job and put the old copy back beside it.
  ///
  /// Unlike a transaction, the write shows in the local cache at once, so
  /// the schedule streams carry the new jobs before the server confirms.
  Future<void> appendNewJobs(List<Job> jobs) async {
    if (jobs.isEmpty) return;
    if (jobs.any((j) => j.id.isEmpty)) {
      throw ArgumentError('appendNewJobs needs every job to carry its id');
    }

    // day key → (day, job id → stored map). Last copy of an id wins, as in
    // the integrity pass.
    final byKey = <String, (DateTime, Map<String, Map<String, dynamic>>)>{};
    for (final job in jobs) {
      final day = DateTime(job.date.year, job.date.month, job.date.day);
      final key = _dailyService.getDailyDocumentId(day);
      final map = job.toMap();
      _stampJobDate(map, day);
      (byKey[key] ??= (day, <String, Map<String, dynamic>>{})).$2[job.id] =
          map;
    }
    if (byKey.length > _maxMutationDates) {
      throw ArgumentError(
        'Adding jobs on ${byKey.length} days; '
        'maximum is $_maxMutationDates per operation',
      );
    }

    final monthsByKey = <String, DateTime>{
      for (final e in byKey.values) _dailyService.getMonthlyDocumentId(e.$1): e.$1,
    };
    await Future.wait(
      monthsByKey.values.map(_dailyService.ensureScheduleMonthIndexExists),
    );

    final user = _resolveLogUser();
    final opId = _newJobId();
    final action = jobs.length == 1 ? 'addJob' : 'addJobs';
    final allDateKeys = byKey.keys.toList()..sort();
    final allIds = [for (final e in byKey.values) ...e.$2.keys];

    final batch = _firestore.batch();
    for (final entry in byKey.entries) {
      final key = entry.key;
      final (day, maps) = entry.value;
      final added = maps.values.toList();
      // Merge: an existing day keeps its other jobs and fields; a missing
      // day is created. `date` / `timestamp` are what every day doc holds.
      batch.set(
        _dailyService.getScheduleDailyDoc(day),
        {
          'date': key,
          'timestamp': Timestamp.fromDate(scheduleCivilToInstant(day)),
          'jobs': FieldValue.arrayUnion(added),
        },
        SetOptions(merge: true),
      );
      final monthId = _dailyService.getMonthlyDocumentId(day);
      batch.set(
        _firestore.collection('schedules').doc(monthId).collection('logs').doc(),
        {
          'schemaVersion': 2,
          'opId': opId,
          'action': action,
          'timestamp': FieldValue.serverTimestamp(),
          'userId': user.uid,
          'userEmail': user.email,
          'userName': user.name,
          'month': monthId,
          'dateKey': key,
          'affectedDates': allDateKeys,
          'affectedJobIds': allIds,
          // The day was not read, so whether it existed is not known.
          'writeMode': 'append',
          'added': added,
          'removed': const [],
          'changed': const [],
          'fieldChanges': const {},
        },
      );
    }
    await batch.commit();
  }

  /// Post-mutation integrity pass — see the call site and rationale in
  /// [_runScheduleMutation]. Rewrites [jobsByKey] in place so the write step
  /// persists a normalized, de-duplicated, correctly-filed set of jobs.
  void _enforceScheduleInvariants(
    Map<String, DateTime> datesByKey,
    Map<String, List<Map<String, dynamic>>> jobsByKey,
  ) {
    // Tracks which affected day currently owns each id, to catch an id that
    // would straddle two of the days touched by this mutation.
    final idToDateKey = <String, String>{};

    for (final entry in datesByKey.entries) {
      final dateKey = entry.key;
      final dayDate = entry.value;
      final dayJobs = jobsByKey[dateKey];
      if (dayJobs == null) continue;

      final deduped = <Map<String, dynamic>>[];
      final indexById = <String, int>{};

      for (final job in dayJobs) {
        // (1) Key ↔ placement: stamp this day onto the job, keeping any
        //     time-of-day component so time-slotted jobs aren't flattened.
        _stampJobDate(job, dayDate);

        final id = job['id'];
        if (id is! String || id.isEmpty) {
          // No usable id — can't dedupe or track it; keep it verbatim.
          deduped.add(job);
          continue;
        }

        // (2) No duplication within a day: a repeated id keeps its position
        //     but takes the latest (freshest) content.
        final existingIdx = indexById[id];
        if (existingIdx != null) {
          deduped[existingIdx] = job;
          idToDateKey[id] = dateKey;
          continue;
        }
        indexById[id] = deduped.length;
        deduped.add(job);

        // (3) No duplication across the affected days: fail closed.
        final otherDay = idToDateKey[id];
        if (otherDay != null && otherDay != dateKey) {
          throw ScheduleIntegrityException(
            'job $id would exist on both $otherDay and $dateKey — '
            'aborting to prevent duplication',
          );
        }
        idToDateKey[id] = dateKey;
      }

      jobsByKey[dateKey] = deduped;
    }
  }

  /// Sets the y/m/d of a job map's `date` field to [dayDate] while preserving
  /// its time-of-day. No-op (and no spurious diff) when the job is already
  /// filed on the correct day.
  void _stampJobDate(Map<String, dynamic> job, DateTime dayDate) {
    final raw = job['date'];
    // Interpret the stored instant as a SAST civil date so the comparison and
    // the preserved time-of-day are both in the business timezone.
    final current = raw is Timestamp ? toScheduleCivil(raw.toDate()) : null;
    if (current != null &&
        current.year == dayDate.year &&
        current.month == dayDate.month &&
        current.day == dayDate.day) {
      return; // already on the correct day — leave it untouched
    }
    final corrected = DateTime(
      dayDate.year,
      dayDate.month,
      dayDate.day,
      current?.hour ?? 0,
      current?.minute ?? 0,
      current?.second ?? 0,
      current?.millisecond ?? 0,
      current?.microsecond ?? 0,
    );
    job['date'] = Timestamp.fromDate(scheduleCivilToInstant(corrected));
  }

  /// Removes every occurrence of [jobId] from all day arrays loaded in the
  /// transaction, regardless of which day each copy sits in. Returns true if
  /// at least one copy was removed. Used by reallocation so a move keys the
  /// removal off the job's real location, and so any stray duplicate of the
  /// id is swept up in the same pass.
  bool _removeJobFromLoadedDays(ScheduleTxContext ctx, String jobId) {
    var removed = false;
    for (final dayJobs in ctx.jobsByDateKey.values) {
      final before = dayJobs.length;
      dayJobs.removeWhere((j) => j['id'] == jobId);
      if (dayJobs.length != before) removed = true;
    }
    return removed;
  }

  // Root collection references (not daily)
  CollectionReference get _distributors =>
      _firestore.collection('distributors');
  CollectionReference get _workAreas => _firestore.collection('workAreas');

  /// Single document that holds all work suburb polygons as an array.
  DocumentReference get _workSuburbsDoc =>
      _firestore.collection('workSuburbs').doc('main');

  /// Lightweight existence check: does the month have any schedule data?
  ///
  /// Probes the monthly index document (created by the first write that
  /// touches the month). Tries Firestore cache first to avoid a billed read,
  /// then falls back to server. Returns true on ambiguous errors so the
  /// caller can fall back to its default behaviour (safe-by-default).
  Future<bool> hasScheduleDataForMonth(DateTime month) async {
    final indexDoc = _dailyService.getScheduleMonthlyIndexDoc(month);
    try {
      final cached = await indexDoc.get(
        const GetOptions(source: Source.cache),
      );
      if (cached.exists) return true;
    } catch (_) {
      // Cache miss or unavailable — fall through to server.
    }
    try {
      final server = await indexDoc.get(
        const GetOptions(source: Source.server),
      );
      return server.exists;
    } catch (_) {
      // On any server error, assume data may exist to preserve existing UX.
      return true;
    }
  }

  // DISTRIBUTOR OPERATIONS

  // Stream of all distributors (from root collection)
  Stream<List<Distributor>> streamDistributors([DateTime? date]) {
    // Date parameter is ignored for distributors since they're in root collection
    return _distributors.orderBy('index').snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        return Distributor.fromMap(
            doc.id, Map<String, dynamic>.from(doc.data() as Map));
      }).toList();
    });
  }

  /// One-shot fetch of distributors (cache-first). Use when a consumer
  /// only needs a snapshot rather than a live subscription.
  /// [fromServer] skips the local cache — for callers that act on fields
  /// which may have just changed (e.g. the dropsheet sync reading `role`).
  Future<List<Distributor>> fetchDistributorsOnce(
      {bool fromServer = false}) async {
    if (fromServer) {
      try {
        final snapshot = await _distributors
            .orderBy('index')
            .get(const GetOptions(source: Source.server));
        return snapshot.docs
            .map((doc) => Distributor.fromMap(
                doc.id, Map<String, dynamic>.from(doc.data() as Map)))
            .toList();
      } catch (e) {
        // Offline: the cached copy is better than failing the caller.
        debugPrint(
            'fetchDistributorsOnce: server read failed, using cache: $e');
      }
    }
    QuerySnapshot snapshot;
    try {
      snapshot = await _distributors
          .orderBy('index')
          .get(const GetOptions(source: Source.cache));
      if (snapshot.docs.isEmpty) {
        snapshot = await _distributors.orderBy('index').get();
      }
    } catch (_) {
      snapshot = await _distributors.orderBy('index').get();
    }
    return snapshot.docs.map((doc) {
      return Distributor.fromMap(
          doc.id, Map<String, dynamic>.from(doc.data() as Map));
    }).toList();
  }

  /// A document id for a distributor that hasn't been written yet.
  ///
  /// Minted locally so a staff member being added in the management screen
  /// has a stable id before the save — their photo upload needs one, and the
  /// create then goes out in the same batch as every other edit.
  String newDistributorId() => _distributors.doc().id;

  // Add a new distributor (to root collection)
  Future<String> addDistributor(String name, [DateTime? date]) async {
    // Date parameter is ignored for distributors since they're in root collection

    // Next index = how many there are. A count, not a download of them all.
    final nextIndex = (await _distributors.count().get()).count ?? 0;

    final docRef = await _distributors.add({
      'name': name,
      'index': nextIndex,
      'phone1': null,
      'phone2': null,
      'status': DistributorStatus.active.name,
    });
    return docRef.id;
  }

  // Update a distributor (in root collection)
  Future<void> updateDistributor(Distributor distributor, [DateTime? date]) {
    // Date parameter is ignored for distributors since they're in root collection
    return _distributors.doc(distributor.id).update(distributor.toMap());
  }

  // Smart update distributor with index management
  Future<void> updateDistributorWithSmartIndexing(
    Distributor updatedDistributor,
    int oldIndex,
  ) async {
    final batch = _firestore.batch();

    // Get all distributors to manage indices
    final snapshot = await _distributors.orderBy('index').get();
    final distributors = snapshot.docs.map((doc) {
      return Distributor.fromMap(
          doc.id, Map<String, dynamic>.from(doc.data() as Map));
    }).toList();

    final newIndex = updatedDistributor.index;

    // If index changed, we need to reindex other distributors
    if (oldIndex != newIndex) {
      // Smart indexing: only shift affected distributors
      if (oldIndex < newIndex) {
        // Moving down: shift distributors up
        for (final distributor in distributors) {
          if (distributor.id != updatedDistributor.id &&
              distributor.index > oldIndex &&
              distributor.index <= newIndex) {
            final docRef = _distributors.doc(distributor.id);
            final updatedData =
                distributor.copyWith(index: distributor.index - 1).toMap();
            batch.update(docRef, updatedData);
          }
        }
      } else {
        // Moving up: shift distributors down
        for (final distributor in distributors) {
          if (distributor.id != updatedDistributor.id &&
              distributor.index >= newIndex &&
              distributor.index < oldIndex) {
            final docRef = _distributors.doc(distributor.id);
            final updatedData =
                distributor.copyWith(index: distributor.index + 1).toMap();
            batch.update(docRef, updatedData);
          }
        }
      }
    }

    // Update the main distributor
    final docRef = _distributors.doc(updatedDistributor.id);
    batch.update(docRef, updatedDistributor.toMap());

    await batch.commit();
  }

  // Delete a distributor (from root collection)
  Future<void> deleteDistributor(String distributorId, [DateTime? date]) {
    // Date parameter is ignored for distributors since they're in root collection
    return _distributors.doc(distributorId).delete();
  }

  // Atomically apply all distributor changes (deletes + updates) in one batch.
  // 0 reads, 1 round-trip regardless of how many distributors changed.
  Future<void> batchSaveDistributors({
    required List<Distributor> toUpdate,
    required Set<String> toDelete,
    List<Distributor> toCreate = const [],
  }) async {
    if (toUpdate.isEmpty && toDelete.isEmpty && toCreate.isEmpty) return;

    final batch = _firestore.batch();

    // Deleted distributors go to the Recycle Bin in the same batch. Their
    // payroll, advances, savings and days off are keyed by the same id and
    // were never deleted, so restoring reconnects them all. Their docs are
    // read side by side, not one after another.
    final bin = RecycleBinWriter(_firestore);
    final deleteIds = toDelete.toList();
    final deleteSnaps = await Future.wait([
      for (final id in deleteIds)
        _firestore.collection('distributors').doc(id).get(),
    ]);
    for (var i = 0; i < deleteIds.length; i++) {
      final ref = _firestore.collection('distributors').doc(deleteIds[i]);
      final data = deleteSnaps[i].data();
      if (data != null) {
        bin.addToBatch(
          batch,
          RecycleBinRecord(
            type: RecycleBinType.distributor,
            label: binLabel(data, 'distributor'),
            originalPath: ref.path,
            payload: data,
          ),
        );
      }
      batch.delete(ref);
    }

    for (final distributor in toUpdate) {
      batch.update(_distributors.doc(distributor.id), distributor.toMap());
    }

    // Staff added in the management screen carry ids minted on this device
    // ([newDistributorId]), so a create is an ordinary set in the same batch:
    // the whole screenful of edits still commits (or fails) as one write.
    for (final distributor in toCreate) {
      batch.set(_distributors.doc(distributor.id), distributor.toMap());
    }

    await batch.commit();
  }

  // JOB OPERATIONS (DAILY STRUCTURE)

  /// Atomically remove and add multiple schedule jobs across affected daily
  /// documents in a single batch commit.
  ///
  /// Returns the added jobs with ensured IDs (generated when missing).
  Future<List<Job>> reallocateJobsAtomically({
    required List<Job> removeJobs,
    required List<Job> addJobs,
    String debugTag = 'schedule-reallocation',
  }) async {
    final sw = Stopwatch()..start();

    if (removeJobs.isEmpty && addJobs.isEmpty) {
      debugPrint('[$debugTag] atomic reallocation skipped (no changes)');
      return const <Job>[];
    }

    // Ensure every added job has a stable ID before writing.
    final resolvedAdds = addJobs
        .map((job) => job.id.isEmpty ? _jobWithId(job, _newJobId()) : job)
        .toList();

    final affectedDates = <DateTime>[];
    for (final j in removeJobs) {
      affectedDates.add(DateTime(j.date.year, j.date.month, j.date.day));
    }
    for (final j in resolvedAdds) {
      affectedDates.add(DateTime(j.date.year, j.date.month, j.date.day));
    }

    final uniqueDateKeys = <String, DateTime>{};
    for (final date in affectedDates) {
      uniqueDateKeys[_dailyService.getDailyDocumentId(date)] = date;
    }

    final uniqueDates = uniqueDateKeys.values.toList();
    debugPrint(
      '[$debugTag] atomic start: remove=${removeJobs.length}, add=${resolvedAdds.length}, docs=${uniqueDates.length}',
    );

    await _runScheduleMutation<void>(
      action: 'reallocateJobs',
      dates: uniqueDates,
      affectedJobIds: [
        ...removeJobs.map((j) => j.id),
        ...resolvedAdds.map((j) => j.id),
      ],
      mutate: (ctx) {
        // Remove every source job by id from WHEREVER it actually sits among
        // the loaded days — not just the day its (possibly stale) `date`
        // field points at. A miss throws instead of being silently swallowed,
        // so the add below can never duplicate a job the remove failed to
        // find. This is the fix for the reallocation-duplication bug.
        for (final job in removeJobs) {
          final removed = _removeJobFromLoadedDays(ctx, job.id);
          if (!removed) {
            throw JobNotFoundException(job.id);
          }
        }
        for (final job in resolvedAdds) {
          final key = ctx.dateKeyFor(job.date);
          final dayJobs = ctx.jobsByDateKey[key];
          if (dayJobs == null) {
            throw ScheduleIntegrityException(
              'reallocation add target day $key was not loaded',
            );
          }
          dayJobs.add(job.toMap());
        }
      },
    );

    sw.stop();
    debugPrint(
      '[$debugTag] atomic commit complete in ${sw.elapsedMilliseconds}ms',
    );

    return resolvedAdds;
  }

  /// One-time maintenance: rewrites every populated day document in [month]
  /// through the standard transactional path so [_enforceScheduleInvariants]
  /// heals legacy corruption — misfiled `date` fields and within-day duplicate
  /// job ids — atomically and with full audit logs. Every changed day writes a
  /// recoverable before/after log; clean days are left untouched (no write, no
  /// log). Distinct jobs that share a distributor-day are NEVER merged: they
  /// carry independent ids and real content, so they are preserved as-is and
  /// left for a human to reconcile in the grid.
  ///
  /// Returns the day dates that had data and were run through the repair.
  Future<List<DateTime>> repairScheduleMonth(DateTime month) async {
    final dayDates = await _listScheduleDaysWithData(month);
    if (dayDates.isEmpty) return const [];
    // A calendar month has ≤31 days; each changed day costs 2 writes
    // (doc + log), well under the 250-day / 500-write transaction cap.
    await _runScheduleMutation<void>(
      action: 'repairMonthIntegrity',
      dates: dayDates,
      // No structural edit here — the integrity pass that runs on every
      // mutation does all the healing (date re-stamping + duplicate collapse).
      mutate: (_) {},
    );
    return dayDates;
  }

  /// Dates of the day documents that actually exist for [month].
  Future<List<DateTime>> _listScheduleDaysWithData(DateTime month) async {
    final snap = await _dailyService.getScheduleMonthlyCollection(month).get();
    final dates = <DateTime>[];
    for (final doc in snap.docs) {
      final parsed = DateTime.tryParse(doc.id); // day ids are 'YYYY-MM-DD'
      if (parsed != null) {
        dates.add(DateTime(parsed.year, parsed.month, parsed.day));
      }
    }
    return dates;
  }

  /// Maintenance: within any distributor-day that holds more than one job,
  /// removes redundant jobs that carry NO work areas (empty `workingAreas`
  /// AND empty `workMaps`) — the residue of the shift/duplication bug that
  /// slipped fresh ids past the id-based dedupe:
  ///  • when a job WITH work areas shares the cell, every no-area job is
  ///    dropped as a duplicate/empty placeholder;
  ///  • when EVERY job in the cell is no-area, one is kept (the one with the
  ///    most clients) and the rest dropped.
  /// Jobs that carry real work areas are never touched, so genuinely distinct
  /// jobs are preserved. With [dryRun] true (default) nothing is written — it
  /// only logs and returns the ids it *would* delete.
  Future<List<String>> cleanNoAreaDuplicates(
    DateTime month, {
    bool dryRun = true,
  }) async {
    final monthId = _dailyService.getMonthlyDocumentId(month);
    final snap = await _dailyService.getScheduleMonthlyCollection(month).get();

    bool hasArea(Map m) {
      final wa = (m['workingAreas'] as List?) ?? const [];
      final wm = (m['workMaps'] as List?) ?? const [];
      return wa.isNotEmpty || wm.isNotEmpty;
    }

    // dateKey -> ids to delete on that day.
    final plan = <String, List<String>>{};
    final planDates = <String, DateTime>{};
    final deletedIds = <String>[];

    for (final doc in snap.docs) {
      final data = doc.data() as Map<String, dynamic>?;
      final jobsArray = (data?['jobs'] as List?) ?? const [];
      final byDist = <String, List<Map<String, dynamic>>>{};
      for (final j in jobsArray) {
        final m = Map<String, dynamic>.from(j as Map);
        (byDist[(m['distributorId'] as String?) ?? ''] ??= []).add(m);
      }
      for (final cellJobs in byDist.values) {
        if (cellJobs.length <= 1) continue;
        final withAreas = cellJobs.where(hasArea).toList();
        final noAreas = cellJobs.where((m) => !hasArea(m)).toList();
        final toDelete = <Map<String, dynamic>>[];
        if (withAreas.isNotEmpty) {
          toDelete.addAll(noAreas);
        } else {
          // All no-area: keep the one with the most clients, drop the rest.
          noAreas.sort((a, b) => ((b['clients'] as List?)?.length ?? 0)
              .compareTo(((a['clients'] as List?)?.length ?? 0)));
          toDelete.addAll(noAreas.skip(1));
        }
        for (final m in toDelete) {
          final id = m['id']?.toString() ?? '';
          if (id.isEmpty) continue;
          final clients = ((m['clients'] as List?) ?? const []).join(', ');
          debugPrint('🧹 ${dryRun ? "[DRY-RUN] would delete" : "deleting"} '
              '$monthId/${doc.id} dist=${m['distributorId']} '
              'job=$id clients="$clients"');
          (plan[doc.id] ??= []).add(id);
          deletedIds.add(id);
        }
        if (plan.containsKey(doc.id)) {
          final parsed = DateTime.tryParse(doc.id);
          if (parsed != null) {
            planDates[doc.id] = DateTime(parsed.year, parsed.month, parsed.day);
          }
        }
      }
    }

    if (dryRun || deletedIds.isEmpty) return deletedIds;

    await _runScheduleMutation<void>(
      action: 'cleanNoAreaDuplicates',
      dates: planDates.values.toList(),
      affectedJobIds: deletedIds,
      mutate: (ctx) {
        plan.forEach((dayKey, ids) {
          final dayJobs = ctx.jobsByDateKey[dayKey];
          if (dayJobs == null) return;
          for (final id in ids) {
            dayJobs.removeWhere((j) => j['id'] == id);
          }
        });
      },
    );
    return deletedIds;
  }

  String _newJobId() => _firestore.collection('dummy').doc().id;

  /// A fresh job id, made on the device (no network). Lets the provider show
  /// a new job before it is saved, and makes the save safe to retry: a
  /// second copy with the same id is folded into the first by the integrity
  /// pass in [_runScheduleMutation].
  String newJobId() => _newJobId();

  Job _jobWithId(Job job, String id) {
    return Job(
      id: id,
      clients: List<String>.from(job.clients),
      clientInstructions: List<String>.from(job.clientInstructions),
      workingAreas: List<String>.from(job.workingAreas),
      workMaps: List.from(job.workMaps),
      distributorId: job.distributorId,
      date: job.date,
      statusId: job.statusId,
      mapInstructions: job.mapInstructions,
      dropOffPoint: job.dropOffPoint,
      pickUpPoint: job.pickUpPoint,
      linkedMapId: job.linkedMapId,
      linkedMapMonthKey: job.linkedMapMonthKey,
      linkedMaps: List.from(job.linkedMaps),
      areaLinks: List.from(job.areaLinks),
      resolvedAreaNames: job.resolvedAreaNames,
      missingAreaLinkKeys: job.missingAreaLinkKeys,
    );
  }

  // Stream of all jobs for a specific date. Read-only: it used to create a
  // missing day doc first (a cache read, then a server read and a write per
  // empty day), but a missing day already reads as no jobs and the first
  // schedule write creates it.
  Stream<List<Job>> streamJobsForDate(DateTime date,
          {bool serverOnly = false}) =>
      watchJobsForDate(date, serverOnly: serverOnly);

  /// Live jobs for one day, read-only: unlike [streamJobsForDate] it never
  /// creates the day document, so watching a day can't write to the schedule.
  ///
  /// [serverOnly] drops snapshots served from the offline cache, which can
  /// be days old on a device that hasn't opened the day recently. Callers
  /// that derive and save other documents from the job list (the dropsheet
  /// sync) need this; a stale list makes them delete tasks for jobs it
  /// doesn't contain yet.
  Stream<List<Job>> watchJobsForDate(DateTime date, {bool serverOnly = false}) {
    return AreaLinkResolver.instance.hydrateStream(_dailyService
        .getScheduleDailyDoc(date)
        .snapshots(includeMetadataChanges: serverOnly)
        .where((snapshot) => !serverOnly || !snapshot.metadata.isFromCache)
        .map((snapshot) {
      if (!snapshot.exists || snapshot.data() == null) {
        return <Job>[];
      }

      final data = Map<String, dynamic>.from(snapshot.data() as Map);
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      return jobsArray.map((jobData) {
        final jobMap = Map<String, dynamic>.from(jobData as Map);
        return Job.fromArrayElement(jobMap);
      }).toList();
    }));
  }

  // Stream jobs for a date range (will combine multiple daily documents)
  Stream<List<Job>> streamJobsForDateRange(
      DateTime startDate, DateTime endDate) {
    final dates = _dailyService.getDateRange(startDate, endDate);

    // Use StreamController to combine multiple daily streams
    late StreamController<List<Job>> controller;
    final subscriptions = <StreamSubscription>[];
    Map<String, List<Job>> dailyJobs = {};

    controller = StreamController<List<Job>>(
      onListen: () {
        // Subscribe to each daily document
        for (final date in dates) {
          final dateKey = _dailyService.getDailyDocumentId(date);
          dailyJobs[dateKey] = [];

          final subscription = streamJobsForDate(date).listen((jobs) {
            dailyJobs[dateKey] = jobs;

            // Combine all daily jobs and emit
            final allJobs = <Job>[];
            for (final jobList in dailyJobs.values) {
              allJobs.addAll(jobList);
            }

            if (!controller.isClosed) {
              controller.add(allJobs);
            }
          });

          subscriptions.add(subscription);
        }
      },
      onCancel: () {
        for (final subscription in subscriptions) {
          subscription.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  // Stream all jobs for an entire month using a SINGLE collection listener.
  // This replaces 28-31 individual document listeners with 1 query listener.
  // Fires whenever ANY day document in the month changes.
  //
  // [resolveAreaLinks] false skips filling linked client-map areas in — for
  // readers that only need clients/dates and should not fetch client maps.
  Stream<List<Job>> streamJobsForMonth(DateTime month,
      {bool resolveAreaLinks = true}) {
    final monthlyId = _dailyService.getMonthlyDocumentId(month);

    final raw = _firestore
        .collection('schedules')
        .doc(monthlyId)
        .collection('days')
        .snapshots()
        .map((querySnapshot) {
      final allJobs = <Job>[];
      for (final doc in querySnapshot.docs) {
        final data = doc.data();
        final jobsArray = data['jobs'] as List<dynamic>?;
        if (jobsArray != null) {
          for (final jobData in jobsArray) {
            allJobs.add(Job.fromArrayElement(
                Map<String, dynamic>.from(jobData as Map)));
          }
        }
      }
      return allJobs;
    });
    return resolveAreaLinks
        ? AreaLinkResolver.instance.hydrateStream(raw)
        : raw;
  }

  // Stream of all jobs for current month (optimized for monthly view)
  // In debug mode: loads only this week's jobs for faster development
  // In release mode: uses single collection listener (1 instead of 28-31)
  Stream<List<Job>> streamJobs([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    // Single collection listener per month (optimized — 1 listener instead of 28-31)
    return streamJobsForMonth(targetDate);
  }

  // Stream jobs for optimized range (current month + next month only)
  // Uses 2 collection listeners instead of 56-62 individual ones.
  Stream<List<Job>> streamJobsExtendedRange([DateTime? date]) {
    final targetDate = date ?? DateTime.now();
    final currentMonth = DateTime(targetDate.year, targetDate.month);
    final nextMonth = DateTime(targetDate.year, targetDate.month + 1);

    // Combine two monthly collection streams
    late StreamController<List<Job>> controller;
    List<Job> currentMonthJobs = [];
    List<Job> nextMonthJobs = [];
    final subscriptions = <StreamSubscription>[];

    controller = StreamController<List<Job>>(
      onListen: () {
        subscriptions.add(streamJobsForMonth(currentMonth).listen((jobs) {
          currentMonthJobs = jobs;
          if (!controller.isClosed) {
            controller.add([...currentMonthJobs, ...nextMonthJobs]);
          }
        }));
        subscriptions.add(streamJobsForMonth(nextMonth).listen((jobs) {
          nextMonthJobs = jobs;
          if (!controller.isClosed) {
            controller.add([...currentMonthJobs, ...nextMonthJobs]);
          }
        }));
      },
      onCancel: () {
        for (final sub in subscriptions) {
          sub.cancel();
        }
        subscriptions.clear();
      },
    );

    return controller.stream;
  }

  // Fetch jobs for a specific date (one-time, not streaming). Read-only — a
  // missing day is simply no jobs; it no longer creates the day doc first.
  //
  // Errors are logged and read as no jobs, unless [rethrowErrors]: callers
  // that save something derived from the list (the dropsheet sync) must
  // not mistake "could not read" for "the day is empty".
  Future<List<Job>> fetchJobsForDate(DateTime date,
      {bool rethrowErrors = false}) async {
    try {
      final snapshot = await _dailyService.getScheduleDailyDoc(date).get();

      if (!snapshot.exists || snapshot.data() == null) {
        return <Job>[];
      }

      final data = Map<String, dynamic>.from(snapshot.data() as Map);
      final jobsArray = data['jobs'] as List<dynamic>?;

      if (jobsArray == null || jobsArray.isEmpty) {
        return <Job>[];
      }

      final jobs = jobsArray.map((jobData) {
        final jobMap = Map<String, dynamic>.from(jobData as Map);
        return Job.fromArrayElement(jobMap);
      }).toList();
      return await AreaLinkResolver.instance.hydrateAllLoaded(jobs);
    } catch (e) {
      if (rethrowErrors) rethrow;
      debugPrint('Error fetching jobs for date ${date.toIso8601String()}: $e');
      return <Job>[];
    }
  }

  // Fetch jobs for a specific month (one-time, not streaming). One query of
  // the month's day docs — it used to read the days one after another, 28
  // to 31 round trips.
  Future<List<Job>> fetchJobsForMonth(DateTime month) async {
    try {
      final snap =
          await _dailyService.getScheduleMonthlyCollection(month).get();
      final allJobs = <Job>[
        for (final doc in snap.docs)
          for (final jobData
              in ((doc.data() as Map?)?['jobs'] as List?) ?? const [])
            Job.fromArrayElement(Map<String, dynamic>.from(jobData as Map)),
      ];
      return await AreaLinkResolver.instance.hydrateAllLoaded(allJobs);
    } catch (e) {
      print('Error fetching jobs for month ${month.year}-${month.month}: $e');
      return <Job>[];
    }
  }

  // Add a new job
  Future<String> addJob(Job job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Generate a unique ID for the job if it doesn't have one
    final jobId = job.id.isEmpty ? _newJobId() : job.id;
    final updatedJob = job.id.isEmpty ? _jobWithId(job, jobId) : job;

    await _runScheduleMutation<void>(
      action: 'addJob',
      dates: [targetDate],
      affectedJobIds: [jobId],
      mutate: (ctx) {
        ctx.jobsByDateKey[ctx.dateKeyFor(targetDate)]!.add(updatedJob.toMap());
      },
    );

    return jobId;
  }

  /// [addJob] for several jobs in ONE transaction — a whole schedule
  /// allocation. Each job goes onto its own day; every day is read once and
  /// written once, instead of one transaction per job one after another.
  /// Jobs must carry their ids. A job already on its day (a retry after a
  /// lost reply) is replaced, not doubled, by the integrity pass.
  Future<void> addJobs(List<Job> jobs) async {
    if (jobs.isEmpty) return;
    if (jobs.any((j) => j.id.isEmpty)) {
      throw ArgumentError('addJobs needs every job to carry its id');
    }
    await _runScheduleMutation<void>(
      action: 'addJobs',
      dates: [for (final j in jobs) j.date],
      affectedJobIds: [for (final j in jobs) j.id],
      mutate: (ctx) {
        for (final job in jobs) {
          ctx.jobsByDateKey[ctx.dateKeyFor(job.date)]!.add(job.toMap());
        }
      },
    );
  }

  // Update a job. Throws [JobNotFoundException] when the job no longer
  // exists on the target day (deleted or moved by another user).
  Future<void> updateJob(Job job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    await _runScheduleMutation<void>(
      action: 'updateJob',
      dates: [targetDate],
      affectedJobIds: [job.id],
      mutate: (ctx) {
        final key = ctx.dateKeyFor(targetDate);
        final jobs = ctx.jobsByDateKey[key]!;
        final idx = jobs.indexWhere((j) => j['id'] == job.id);
        if (idx == -1) throw JobNotFoundException(job.id, key);
        jobs[idx] = job.toMap();
      },
    );
  }

  /// [updateJob] for several jobs in ONE transaction — e.g. distributors
  /// combined onto one drop point on the day planner. One read of the day
  /// docs instead of one per job. Throws [JobNotFoundException] when any job
  /// is no longer on its day; then none of them is saved.
  Future<void> updateJobs(List<Job> jobs) async {
    if (jobs.isEmpty) return;
    await _runScheduleMutation<void>(
      action: 'updateJobs',
      dates: [for (final j in jobs) j.date],
      affectedJobIds: [for (final j in jobs) j.id],
      mutate: (ctx) {
        for (final job in jobs) {
          final key = ctx.dateKeyFor(job.date);
          final dayJobs = ctx.jobsByDateKey[key]!;
          final idx = dayJobs.indexWhere((j) => j['id'] == job.id);
          if (idx == -1) throw JobNotFoundException(job.id, key);
          dayJobs[idx] = job.toMap();
        }
      },
    );
  }

  /// Adds and removes client-map area links on several schedule jobs in ONE
  /// transaction, so a move between distributors can never leave an area
  /// on both jobs or on neither. Only each job's `areaLinks` field is
  /// rewritten — plus, when a change converts a COPIED client-map area into
  /// a link, that copy in `workMaps` and its name in `workingAreas`.
  /// Everything else on the job is left exactly as stored, so a concurrent
  /// edit to the job's other fields is never overwritten.
  /// Throws [JobNotFoundException] when a job is no longer on its day.
  Future<void> applyAreaLinkChanges(
    List<AreaLinkChange> changes, {
    String action = 'allocateAreas',
  }) async {
    if (changes.isEmpty) return;
    await _runScheduleMutation<void>(
      action: action,
      dates: [for (final c in changes) c.date],
      affectedJobIds: [for (final c in changes) c.jobId],
      mutate: (ctx) {
        for (final change in changes) {
          final key = ctx.dateKeyFor(change.date);
          final jobs = ctx.jobsByDateKey[key]!;
          final idx = jobs.indexWhere((j) => j['id'] == change.jobId);
          if (idx == -1) throw JobNotFoundException(change.jobId, key);
          final raw = jobs[idx];
          final current = (raw['areaLinks'] as List? ?? const [])
              .map((e) =>
                  JobAreaLink.fromMap(Map<String, dynamic>.from(e as Map)))
              .toList();
          final next = change.applyTo(current);
          if (next.isEmpty) {
            raw.remove('areaLinks');
          } else {
            raw['areaLinks'] = next.map((l) => l.toMap()).toList();
          }
          if (change.removesCopies) _removeCopiedAreas(raw, change);
        }
      },
    );
  }

  /// Renames client [from] to [to] on each job in [jobs] (id → its date),
  /// in one schedule transaction. Only the client fields are rewritten, from
  /// the stored job — nothing else on it can be put back to an older copy.
  /// A job already carrying [to] just loses [from], with its instruction.
  /// Returns how many jobs changed.
  Future<int> renameClientOnJobs(
    Map<String, DateTime> jobs, {
    required String from,
    required String to,
  }) async {
    final fromKey = from.trim().toLowerCase();
    final toName = to.trim();
    if (jobs.isEmpty || fromKey.isEmpty || toName.isEmpty) return 0;
    if (fromKey == toName.toLowerCase()) return 0;
    var changed = 0;
    await _runScheduleMutation<void>(
      action: 'renameClient',
      dates: jobs.values.toList(),
      affectedJobIds: jobs.keys.toList(),
      mutate: (ctx) {
        changed = 0;
        for (final entry in jobs.entries) {
          final list = ctx.jobsByDateKey[ctx.dateKeyFor(entry.value)]!;
          final idx = list.indexWhere((j) => j['id'] == entry.key);
          // Moved or deleted since it was read — nothing of ours to rename.
          if (idx == -1) continue;
          final raw = list[idx];
          final clients = [
            for (final c in raw['clients'] as List? ?? const []) '$c',
          ];
          final instructions = [
            for (final c in raw['clientInstructions'] as List? ?? const [])
              '$c',
          ];
          final parallel = instructions.length == clients.length;
          final hasTo =
              clients.any((c) => c.trim().toLowerCase() == toName.toLowerCase());
          var touched = false;
          for (var i = clients.length - 1; i >= 0; i--) {
            if (clients[i].trim().toLowerCase() != fromKey) continue;
            touched = true;
            if (hasTo) {
              clients.removeAt(i);
              if (parallel) instructions.removeAt(i);
            } else {
              clients[i] = toName;
            }
          }
          if (!touched) continue;
          raw['clients'] = clients;
          if (parallel) raw['clientInstructions'] = instructions;
          // Legacy single-client field.
          raw['client'] = clients.isEmpty ? '' : clients.first;
          changed++;
        }
      },
    );
    return changed;
  }

  /// Takes the copies [change] names out of stored job [raw]'s `workMaps`,
  /// and their names out of `workingAreas` unless another work map that
  /// stays still carries the same name.
  static void _removeCopiedAreas(
      Map<String, dynamic> raw, AreaLinkChange change) {
    final rawMaps = raw['workMaps'] as List? ?? const [];
    final kept = <dynamic>[];
    final removedNames = <String>{};
    final keptNames = <String>{};
    for (final entry in rawMaps) {
      final polygon =
          CustomPolygon.fromMap(Map<String, dynamic>.from(entry as Map));
      if (change.removesCopy(polygon, polygonGeometryKey)) {
        removedNames.add(polygon.name.trim().toLowerCase());
      } else {
        kept.add(entry);
        keptNames.add(polygon.name.trim().toLowerCase());
      }
    }
    if (kept.length == rawMaps.length) return;
    raw['workMaps'] = kept;
    final gone = removedNames.difference(keptNames)..remove('');
    final areas = raw['workingAreas'];
    if (gone.isNotEmpty && areas is List) {
      raw['workingAreas'] = [
        for (final a in areas)
          if (!gone.contains('$a'.trim().toLowerCase())) a,
      ];
    }
  }

  /// Sets (or clears) the admin confirmation status for a schedule day.
  /// Confirmed stamps confirmedAt/confirmedBy; other statuses clear them so
  /// stale confirmation info doesn't linger once a day is reopened for edits.
  Future<void> setScheduleDayConfirmation(
    DateTime date,
    ScheduleConfirmationStatus status, {
    String? confirmedBy,
  }) async {
    final confirmed = status == ScheduleConfirmationStatus.confirmed;
    await _runScheduleMutation<void>(
      action: 'dayConfirmation',
      dates: [date],
      mutate: (ctx) {
        // Null values are removed from the day doc by the mutation helper.
        ctx.dayFieldUpdates[ctx.dateKeyFor(date)] = {
          'confirmationStatus': status.name,
          'confirmedAt': confirmed ? FieldValue.serverTimestamp() : null,
          'confirmedBy': confirmed ? confirmedBy : null,
        };
      },
    );
  }

  /// Streams the confirmation status for a schedule day.
  ///
  /// Metadata changes are included so the UI learns the moment a locally
  /// cached/pending value is acknowledged by the server — otherwise a client
  /// that wrote while offline keeps rendering its own optimistic value with no
  /// way to tell it apart from what everyone else sees.
  Stream<ScheduleDayConfirmation> streamScheduleDayConfirmation(
    DateTime date,
  ) {
    return _dailyService
        .getScheduleDailyDoc(date)
        .snapshots(includeMetadataChanges: true)
        .map(ScheduleDayConfirmation.fromSnapshot);
  }

  // Move a job between different dates (handles cross-day/cross-month moves)
  // as a single transaction — the job is never lost or duplicated.
  Future<void> moveJobBetweenDates(Job originalJob, Job updatedJob,
      DateTime originalDate, DateTime newDate) async {
    // If it's the same date, just do a regular update
    if (originalDate.year == newDate.year &&
        originalDate.month == newDate.month &&
        originalDate.day == newDate.day) {
      await updateJob(updatedJob, newDate);
      return;
    }

    await _runScheduleMutation<void>(
      action: 'moveJob',
      dates: [originalDate, newDate],
      affectedJobIds: [originalJob.id],
      mutate: (ctx) {
        final sourceKey = ctx.dateKeyFor(originalDate);
        final sourceJobs = ctx.jobsByDateKey[sourceKey]!;
        final beforeLength = sourceJobs.length;
        sourceJobs.removeWhere((j) => j['id'] == originalJob.id);
        // Missing on the source day means another user moved or deleted it;
        // aborting prevents duplicating the job on the destination day.
        if (sourceJobs.length == beforeLength) {
          throw JobNotFoundException(originalJob.id, sourceKey);
        }
        ctx.jobsByDateKey[ctx.dateKeyFor(newDate)]!.add(updatedJob.toMap());
      },
    );
  }

  /// Moves several jobs at once, atomically: each job in [moves] (original →
  /// moved) leaves its original day and lands on its new one. If any job is
  /// no longer where it was read, nothing is written.
  Future<void> moveJobsAtomically(List<(Job, Job)> moves) async {
    if (moves.isEmpty) return;
    await _runScheduleMutation<void>(
      action: 'moveJobs',
      dates: [
        for (final (original, moved) in moves) ...[original.date, moved.date],
      ],
      affectedJobIds: [for (final (original, _) in moves) original.id],
      mutate: (ctx) {
        for (final (original, _) in moves) {
          final key = ctx.dateKeyFor(original.date);
          final dayJobs = ctx.jobsByDateKey[key]!;
          final before = dayJobs.length;
          dayJobs.removeWhere((j) => j['id'] == original.id);
          if (dayJobs.length == before) {
            throw JobNotFoundException(original.id, key);
          }
        }
        for (final (_, moved) in moves) {
          ctx.jobsByDateKey[ctx.dateKeyFor(moved.date)]!.add(moved.toMap());
        }
      },
    );
  }

  /// Swap two jobs on the same date atomically.
  /// Each job gets the other's distributorId.
  Future<void> swapJobsOnSameDate(
      Job newJobA, Job newJobB, DateTime date) async {
    await _runScheduleMutation<void>(
      action: 'swapJobs',
      dates: [date],
      affectedJobIds: [newJobA.id, newJobB.id],
      mutate: (ctx) {
        final key = ctx.dateKeyFor(date);
        final jobs = ctx.jobsByDateKey[key]!;
        final idxA = jobs.indexWhere((j) => j['id'] == newJobA.id);
        if (idxA == -1) throw JobNotFoundException(newJobA.id, key);
        final idxB = jobs.indexWhere((j) => j['id'] == newJobB.id);
        if (idxB == -1) throw JobNotFoundException(newJobB.id, key);
        jobs[idxA] = newJobA.toMap();
        jobs[idxB] = newJobB.toMap();
      },
    );
  }

  /// Swap two jobs across different dates atomically.
  /// Job A moves from dateA to dateB, Job B moves from dateB to dateA.
  Future<void> swapJobsBetweenDates(Job originalJobA, Job newJobA,
      Job originalJobB, Job newJobB, DateTime dateA, DateTime dateB) async {
    await _runScheduleMutation<void>(
      action: 'swapJobs',
      dates: [dateA, dateB],
      affectedJobIds: [originalJobA.id, originalJobB.id],
      mutate: (ctx) {
        final keyA = ctx.dateKeyFor(dateA);
        final keyB = ctx.dateKeyFor(dateB);
        final jobsA = ctx.jobsByDateKey[keyA]!;
        final jobsB = ctx.jobsByDateKey[keyB]!;

        final lenA = jobsA.length;
        jobsA.removeWhere((j) => j['id'] == originalJobA.id);
        if (jobsA.length == lenA) {
          throw JobNotFoundException(originalJobA.id, keyA);
        }
        final lenB = jobsB.length;
        jobsB.removeWhere((j) => j['id'] == originalJobB.id);
        if (jobsB.length == lenB) {
          throw JobNotFoundException(originalJobB.id, keyB);
        }

        jobsA.add(newJobB.toMap());
        jobsB.add(newJobA.toMap());
      },
    );
  }

  /// Combine two jobs on the same date atomically:
  /// removes the source job and updates the target with combined data.
  Future<void> combineJobsOnSameDate(
      String removeJobId, Job combinedJob, DateTime date) async {
    await _runScheduleMutation<void>(
      action: 'combineJobs',
      dates: [date],
      affectedJobIds: [removeJobId, combinedJob.id],
      mutate: (ctx) {
        final key = ctx.dateKeyFor(date);
        final jobs = ctx.jobsByDateKey[key]!;
        final len = jobs.length;
        jobs.removeWhere((j) => j['id'] == removeJobId);
        if (jobs.length == len) {
          throw JobNotFoundException(removeJobId, key);
        }
        final idx = jobs.indexWhere((j) => j['id'] == combinedJob.id);
        if (idx == -1) throw JobNotFoundException(combinedJob.id, key);
        jobs[idx] = combinedJob.toMap();
      },
    );
  }

  /// Combine two jobs across different dates atomically:
  /// removes the source job from sourceDate, updates the target job at targetDate.
  Future<void> combineJobsBetweenDates(String removeJobId, Job combinedJob,
      DateTime sourceDate, DateTime targetDate) async {
    await _runScheduleMutation<void>(
      action: 'combineJobs',
      dates: [sourceDate, targetDate],
      affectedJobIds: [removeJobId, combinedJob.id],
      mutate: (ctx) {
        final sourceKey = ctx.dateKeyFor(sourceDate);
        final targetKey = ctx.dateKeyFor(targetDate);
        final sourceJobs = ctx.jobsByDateKey[sourceKey]!;
        final len = sourceJobs.length;
        sourceJobs.removeWhere((j) => j['id'] == removeJobId);
        if (sourceJobs.length == len) {
          throw JobNotFoundException(removeJobId, sourceKey);
        }
        final targetJobs = ctx.jobsByDateKey[targetKey]!;
        final idx = targetJobs.indexWhere((j) => j['id'] == combinedJob.id);
        if (idx == -1) throw JobNotFoundException(combinedJob.id, targetKey);
        targetJobs[idx] = combinedJob.toMap();
      },
    );
  }

  // Delete a job into the Recycle Bin and return the bin entry id. Deleting
  // a job that is already gone is a no-op (no write, no log entry, null).
  Future<String?> deleteJob(String jobId, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();
    final bin = RecycleBinWriter(_firestore);
    final binRef = bin.newEntryRef();
    Map<String, dynamic>? removed;

    await _runScheduleMutation<void>(
      action: 'deleteJob',
      dates: [targetDate],
      affectedJobIds: [jobId],
      mutate: (ctx) {
        removed = null;
        final list = ctx.jobsByDateKey[ctx.dateKeyFor(targetDate)]!;
        final i = list.indexWhere((j) => j['id'] == jobId);
        if (i < 0) return;
        removed = list[i];
        list.removeWhere((j) => j['id'] == jobId);
      },
      extraWrites: (tx, ctx) {
        final job = removed;
        if (job == null) return;
        bin.addToTxn(tx, _scheduleJobBinRecord(job, targetDate), ref: binRef);
      },
    );
    return removed == null ? null : binRef.id;
  }

  /// [deleteJob] for several jobs (id → its date) in ONE transaction: each
  /// leaves its day and gets its own Recycle Bin entry, all or nothing.
  /// Jobs already gone are skipped. Returns job id → bin entry id for the
  /// jobs it deleted.
  Future<Map<String, String>> deleteJobs(Map<String, DateTime> jobs) async {
    if (jobs.isEmpty) return const {};
    final dayKeys = {for (final d in jobs.values) _dailyService.getDailyDocumentId(d)};
    // A transaction holds 500 writes: a day doc + a log per day, a bin
    // entry per job.
    if (dayKeys.length * 2 + jobs.length > 500) {
      throw ArgumentError(
          'Deleting ${jobs.length} jobs over ${dayKeys.length} days is too '
          'many for one save — delete fewer at a time');
    }
    final bin = RecycleBinWriter(_firestore);
    // Made once, so a retried transaction writes the same entries.
    final binRefs = {for (final id in jobs.keys) id: bin.newEntryRef()};
    final removed = <String, (Map<String, dynamic>, DateTime)>{};

    await _runScheduleMutation<void>(
      action: jobs.length == 1 ? 'deleteJob' : 'deleteJobs',
      dates: jobs.values.toList(),
      affectedJobIds: jobs.keys.toList(),
      mutate: (ctx) {
        removed.clear();
        jobs.forEach((id, date) {
          final list = ctx.jobsByDateKey[ctx.dateKeyFor(date)]!;
          final i = list.indexWhere((j) => j['id'] == id);
          if (i < 0) return;
          removed[id] = (list[i], date);
          list.removeWhere((j) => j['id'] == id);
        });
      },
      extraWrites: (tx, ctx) {
        removed.forEach((id, r) => bin.addToTxn(
            tx, _scheduleJobBinRecord(r.$1, r.$2),
            ref: binRefs[id]));
      },
    );
    return {for (final id in removed.keys) id: binRefs[id]!.id};
  }

  /// Takes a job off the schedule that lives on elsewhere (dragged to the
  /// unfinished-work-areas panel) — no Recycle Bin copy.
  Future<void> removeJobMovedElsewhere(
      String jobId, DateTime date, String action) async {
    await _runScheduleMutation<void>(
      action: action,
      dates: [date],
      affectedJobIds: [jobId],
      mutate: (ctx) {
        ctx.jobsByDateKey[ctx.dateKeyFor(date)]!
            .removeWhere((j) => j['id'] == jobId);
      },
    );
  }

  RecycleBinRecord _scheduleJobBinRecord(
      Map<String, dynamic> job, DateTime date) {
    final clients = (job['clients'] as List?)?.cast<String>() ?? const [];
    final areas = (job['workingAreas'] as List?)?.cast<String>() ?? const [];
    final parts = [
      clients.where((c) => c.trim().isNotEmpty).join(', '),
      if (areas.isNotEmpty) areas.first,
      DateFormat('EEE d MMM yyyy').format(date),
    ].where((p) => p.isNotEmpty);
    return RecycleBinRecord(
      type: RecycleBinType.scheduleJob,
      label: parts.join(' · '),
      originalPath: _dailyService.getScheduleDailyDoc(date).path,
      payload: {
        'job': job,
        'dateKey': _dailyService.getDailyDocumentId(date),
      },
    );
  }

  /// Puts a schedule job deleted into the Recycle Bin back on its day, and
  /// marks [entryRef] restored in the same transaction. Throws
  /// [RestoreConflict] if a job with its id is on that day again.
  Future<DateTime> restoreScheduleJobFromBin(
    Map<String, dynamic> payload,
    DocumentReference<Map<String, dynamic>> entryRef,
    Map<String, dynamic> restoredFields,
  ) async {
    final job = Map<String, dynamic>.from(payload['job'] as Map);
    final date = DateTime.parse(payload['dateKey'] as String);
    final id = job['id'] as String;
    await _runScheduleMutation<void>(
      action: 'restoreJob',
      dates: [date],
      affectedJobIds: [id],
      mutate: (ctx) {
        final list = ctx.jobsByDateKey[ctx.dateKeyFor(date)]!;
        if (list.any((j) => j['id'] == id)) {
          throw const RestoreConflict('the job is already on the schedule');
        }
        list.add(deepCopyMap(job));
      },
      extraWrites: (tx, ctx) => tx.update(entryRef, restoredFields),
    );
    return date;
  }

  /// Undo / redo of a schedule step: replaces exactly [expected] (the jobs as
  /// the step left them) with [replacement], in one logged transaction.
  ///
  /// Throws [UndoConflict] — changing nothing — when any expected job is no
  /// longer as recorded (another user, a Job List cascade), or a job to put
  /// back is already there. A retry of a write that did commit finds
  /// [replacement] already in place and returns without writing.
  ///
  /// Jobs removed without a replacement go to the Recycle Bin when
  /// [binRemovals] (redoing a delete); their new entry ids are returned.
  /// [restoredBinIds] are marked restored (undoing a delete).
  Future<Map<String, String>> restoreScheduleJobs({
    required List<Job> expected,
    required List<Job> replacement,
    required String action,
    bool binRemovals = false,
    List<String> restoredBinIds = const [],
  }) async {
    final bin = RecycleBinWriter(_firestore);
    final binRefs = <String, DocumentReference<Map<String, dynamic>>>{};
    var result = const ScheduleRestoreResult();

    await _runScheduleMutation<void>(
      action: action,
      dates: [for (final j in [...expected, ...replacement]) j.date],
      affectedJobIds:
          {for (final j in [...expected, ...replacement]) j.id}.toList(),
      mutate: (ctx) => result = applyScheduleRestore(ctx,
          expected: expected, replacement: replacement),
      extraWrites: (tx, ctx) {
        binRefs.clear();
        if (result.alreadyApplied) return;
        if (binRemovals) {
          result.removed.forEach((id, removed) {
            binRefs[id] = bin.addToTxn(
                tx, _scheduleJobBinRecord(removed.$1, removed.$2));
          });
        }
        final user = FirebaseAuth.instance.currentUser;
        for (final id in restoredBinIds) {
          tx.update(_firestore.collection(kRecycleBinCollection).doc(id), {
            'restoredAt': FieldValue.serverTimestamp(),
            'restoredBy': {
              'uid': user?.uid ?? '',
              'name': user?.displayName ?? user?.email ?? '',
            },
          });
        }
      },
    );
    return {for (final e in binRefs.entries) e.key: e.value.id};
  }

  // Stream jobs for a specific distributor
  Stream<List<Job>> streamJobsForDistributor(String distributorId,
      [DateTime? date]) {
    final targetDate = date ?? DateTime.now();

    return streamJobsForDate(targetDate).map((jobs) {
      return jobs.where((job) => job.distributorId == distributorId).toList();
    });
  }

  // Stream jobs for a specific date range (within same month)
  Stream<List<Job>> streamJobsForDateRangeInMonth(DateTime start, DateTime end,
      [DateTime? monthContext]) {
    return streamJobsForDateRange(start, end);
  }

  // WORK AREA OPERATIONS

  // Stream of all work areas (from root collection)
  Stream<List<WorkArea>> streamWorkAreas([DateTime? date]) {
    // Date parameter is ignored for work areas since they're in root collection
    return _workAreas.snapshots().map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data() as Map);
        data['id'] = doc.id; // Add the document ID to the data
        return WorkArea.fromMap(data);
      }).toList();
    });
  }

  /// One-shot fetch of work areas. Tries Firestore cache first to avoid a
  /// billed read, falls back to server on cache miss. Use when a consumer
  /// needs a snapshot of work areas without subscribing to live updates.
  Future<List<WorkArea>> fetchWorkAreasOnce() async {
    QuerySnapshot snapshot;
    try {
      snapshot = await _workAreas.get(const GetOptions(source: Source.cache));
      if (snapshot.docs.isEmpty) {
        snapshot = await _workAreas.get();
      }
    } catch (_) {
      snapshot = await _workAreas.get();
    }
    return snapshot.docs.map((doc) {
      final data = Map<String, dynamic>.from(doc.data() as Map);
      data['id'] = doc.id;
      return WorkArea.fromMap(data);
    }).toList();
  }

  // Update a work area (in root collection)
  Future<void> updateWorkArea(WorkArea workArea, [DateTime? date]) {
    // Date parameter is ignored for work areas since they're in root collection
    return _workAreas.doc(workArea.id).update(workArea.toFirestore());
  }

  // Add a new work area (to root collection)
  Future<String> addWorkArea(WorkArea workArea, [DateTime? date]) async {
    // Date parameter is ignored for work areas since they're in root collection
    final docRef = await _workAreas.add(workArea.toFirestore());
    return docRef.id;
  }

  // Move a work area (from root collection) to the Recycle Bin
  Future<void> deleteWorkArea(String workAreaId, [DateTime? date]) async {
    // Date parameter is ignored for work areas since they're in root collection
    await RecycleBinWriter(_firestore).moveDocToBin(
      _firestore.collection('workAreas').doc(workAreaId),
      type: RecycleBinType.workArea,
      label: (d) => '${(d['name'] as String?)?.trim().isNotEmpty == true ? (d['name'] as String).trim() : 'Unnamed'} (work area)',
    );
  }

  // ── Work Suburbs (single-document pattern) ──────────────────────────

  /// Real-time stream of all suburb polygons from the single
  /// `workSuburbs/main` document.
  Stream<List<WorkSuburb>> streamWorkSuburbs() {
    return _workSuburbsDoc.snapshots().map((snap) {
      if (!snap.exists) return <WorkSuburb>[];
      final data = snap.data() as Map<String, dynamic>;
      final List<dynamic> raw = data['suburbs'] ?? [];
      return raw
          .map((e) => WorkSuburb.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList();
    });
  }

  /// Cache-first one-shot fetch of work suburbs.
  Future<List<WorkSuburb>> fetchWorkSuburbsOnce() async {
    DocumentSnapshot snap;
    try {
      snap = await _workSuburbsDoc.get(const GetOptions(source: Source.cache));
      if (!snap.exists) snap = await _workSuburbsDoc.get();
    } catch (_) {
      snap = await _workSuburbsDoc.get();
    }
    if (!snap.exists) return [];
    final data = snap.data() as Map<String, dynamic>;
    final List<dynamic> raw = data['suburbs'] ?? [];
    return raw
        .map((e) => WorkSuburb.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Overwrites the entire suburbs array in the single document.
  ///
  /// Deprecated: prefer [saveSuburbOverrides] when using [SuburbDataService].
  Future<void> saveWorkSuburbs(List<WorkSuburb> suburbs) {
    return _workSuburbsDoc.set({
      'suburbs': suburbs.map((s) => s.toMap()).toList(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // ── Work Suburbs — Cloud Storage meta / overrides ─────────────────────────

  DocumentReference get _suburbMetaDoc =>
      _firestore.collection('workSuburbs').doc('meta');

  DocumentReference get _suburbOverridesDoc =>
      _firestore.collection('workSuburbs').doc('overrides');

  /// Fetch the KML version metadata stored at `workSuburbs/meta`.
  ///
  /// Returns a map with at least `version` (String) and `storagePath` (String).
  Future<Map<String, dynamic>?> fetchSuburbMeta() async {
    try {
      final snap = await _suburbMetaDoc.get();
      if (!snap.exists) return null;
      return snap.data() as Map<String, dynamic>;
    } catch (e) {
      debugPrint('FirestoreService.fetchSuburbMeta: $e');
      return null;
    }
  }

  /// Fetch user-editable overrides for individual suburbs (letterBoxEstimate,
  /// description).  Returns a map keyed by suburb id.
  Future<Map<String, Map<String, dynamic>>> fetchSuburbOverrides() async {
    try {
      DocumentSnapshot snap;
      try {
        snap = await _suburbOverridesDoc
            .get(const GetOptions(source: Source.cache));
        if (!snap.exists) snap = await _suburbOverridesDoc.get();
      } catch (_) {
        snap = await _suburbOverridesDoc.get();
      }
      if (!snap.exists) return {};
      final data = snap.data() as Map<String, dynamic>;
      final rawList = data['overrides'] as List<dynamic>? ?? [];
      return {
        for (final o in rawList.cast<Map<String, dynamic>>())
          o['id'] as String: o,
      };
    } catch (e) {
      debugPrint('FirestoreService.fetchSuburbOverrides: $e');
      return {};
    }
  }

  /// Persist user-editable suburb fields.  Only [letterBoxEstimate] and
  /// [description] are saved — coordinates stay in the KML.
  Future<void> saveSuburbOverrides(List<WorkSuburb> suburbs) {
    final overrides = suburbs
        .where((s) => s.letterBoxEstimate != 0 || s.description.isNotEmpty)
        .map((s) => {
              'id': s.id,
              'letterBoxEstimate': s.letterBoxEstimate,
              'description': s.description,
            })
        .toList();

    return _suburbOverridesDoc.set({
      'overrides': overrides,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Write (or update) the KML version metadata at `workSuburbs/meta`.
  ///
  /// Typically called from the seeder script after uploading a new KML.
  Future<void> setSuburbMeta({
    required String version,
    required String storagePath,
  }) {
    return _suburbMetaDoc.set({
      'version': version,
      'storagePath': storagePath,
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  // UTILITY METHODS

  // Get available monthly documents for schedules (jobs only)
  Future<List<String>> getAvailableScheduleMonths() {
    return _dailyService.getAvailableScheduleMonths();
  }

  // Get current monthly document ID
  String getCurrentMonthlyDocumentId() {
    return _dailyService.getCurrentMonthlyDocumentId();
  }

  // Get current daily document ID
  String getCurrentDailyDocumentId() {
    return _dailyService.getCurrentDailyDocumentId();
  }

  // Get monthly document ID for a specific date
  String getMonthlyDocumentId(DateTime date) {
    return _dailyService.getMonthlyDocumentId(date);
  }

  // Get daily document ID for a specific date
  String getDailyDocumentId(DateTime date) {
    return _dailyService.getDailyDocumentId(date);
  }

  // COLLECTION JOB OPERATIONS (DAILY STRUCTURE)

  // Stream collection jobs for a specific date
  Stream<List<CollectionJob>> streamCollectionJobsForDate(DateTime date) {
    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(date);

    return dailyDoc.snapshots().map((snapshot) {
      if (!snapshot.exists) return <CollectionJob>[];

      final data = Map<String, dynamic>.from(snapshot.data() as Map);
      final jobsArray =
          List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

      return jobsArray.map((jobData) {
        final id = jobData['id'] as String;
        return CollectionJob.fromMap(id, jobData);
      }).toList();
    });
  }

  // Stream collection jobs for a month
  Stream<List<CollectionJob>> streamCollectionJobs(DateTime month) {
    final monthStart = DateTime(month.year, month.month, 1);
    final monthEnd = DateTime(month.year, month.month + 1, 0);

    return streamCollectionJobsForDateRange(monthStart, monthEnd);
  }

  // Stream collection jobs for a date range
  Stream<List<CollectionJob>> streamCollectionJobsForDateRange(
      DateTime startDate, DateTime endDate) async* {
    final dates = _dailyService.getDateRange(startDate, endDate);
    final allJobs = <CollectionJob>[];

    for (final date in dates) {
      final jobs = await fetchCollectionJobsForDate(date);
      allJobs.addAll(jobs);
    }
    yield allJobs;

    // Note: For a fully reactive stream, you'd need to combine multiple streams
    // This is a simplified version for demonstration
  }

  // Fetch collection jobs for a specific date (one-time fetch)
  Future<List<CollectionJob>> fetchCollectionJobsForDate(DateTime date) async {
    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(date);
    final snapshot = await dailyDoc.get();

    if (!snapshot.exists) return <CollectionJob>[];

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    return jobsArray.map((jobData) {
      final id = jobData['id'] as String;
      return CollectionJob.fromMap(id, jobData);
    }).toList();
  }

  // Fetch collection jobs for a specific month (one-time fetch)
  Future<List<CollectionJob>> fetchCollectionJobsForMonth(
      DateTime month) async {
    final monthStart = DateTime(month.year, month.month, 1);
    final monthEnd = DateTime(month.year, month.month + 1, 0);

    final allJobs = <CollectionJob>[];
    final dates = _dailyService.getDateRange(monthStart, monthEnd);

    for (final date in dates) {
      final jobs = await fetchCollectionJobsForDate(date);
      allJobs.addAll(jobs);
    }

    return allJobs;
  }

  // Add a collection job
  Future<String> addCollectionJob(CollectionJob job, DateTime date) async {
    final targetDate = date;

    // Ensure daily document exists
    await _dailyService.ensureCollectionScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(targetDate);

    // Generate a unique ID for the job
    final jobId = _firestore.collection('temp').doc().id;
    final jobWithId = job.copyWith();
    final jobMap = jobWithId.toMap();
    jobMap['id'] = jobId; // Ensure ID is set in the map

    // Add to the jobs array
    await dailyDoc.update({
      'collectionJobs': FieldValue.arrayUnion([jobMap])
    });

    return jobId;
  }

  // Update a collection job
  Future<void> updateCollectionJob(CollectionJob job, [DateTime? date]) async {
    final targetDate = date ?? job.date;

    // Ensure daily document exists
    await _dailyService.ensureCollectionScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(targetDate);

    // Get current document data
    final snapshot = await dailyDoc.get();
    if (!snapshot.exists) return;

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    // Find and update the job in the array
    final jobIndex = jobsArray.indexWhere((jobData) => jobData['id'] == job.id);
    if (jobIndex != -1) {
      jobsArray[jobIndex] = job.toMap();

      // Update the document with the modified array
      await dailyDoc.update({'collectionJobs': jobsArray});
    }
  }

  // Delete a collection job
  Future<void> deleteCollectionJob(String jobId, [DateTime? date]) async {
    final targetDate = date ?? DateTime.now();

    // Ensure daily document exists
    await _dailyService.ensureCollectionScheduleDailyDocExists(targetDate);

    final dailyDoc = _dailyService.getCollectionScheduleDailyDoc(targetDate);

    // Get current document data
    final snapshot = await dailyDoc.get();
    if (!snapshot.exists) return;

    final data = Map<String, dynamic>.from(snapshot.data() as Map);
    final jobsArray =
        List<Map<String, dynamic>>.from(data['collectionJobs'] ?? []);

    // Remove the job from the array
    jobsArray.removeWhere((jobData) => jobData['id'] == jobId);

    // Update the document with the modified array
    await dailyDoc.update({'collectionJobs': jobsArray});
  }

  // Get available schedule months for collection jobs
  Future<List<String>> getAvailableCollectionScheduleMonths() async {
    return await _dailyService.getAvailableCollectionScheduleMonths();
  }
}
