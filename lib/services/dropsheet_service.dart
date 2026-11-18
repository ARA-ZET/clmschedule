import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/dropsheet_day.dart';

/// CRUD for the dropsheet day document.
///
/// **Current (new) storage layout** — mirrors the schedule's hierarchy:
///   `/dropsheet/{YYYY}/{MMM YYYY}/{YYYY-MM-DD}`
///   e.g. `/dropsheet/2026/May 2026/2026-05-21`
///
/// **Legacy layout** (kept readable for backwards compatibility until a
/// migration is performed):
///   `/dropsheet/daily/days/{YYYY-MM-DD}`
///
/// Reads transparently fall back to the legacy doc when the new path has
/// no data, so existing days remain visible. All writes go to the new
/// path only — once a day is saved under the new layout, the legacy doc
/// becomes obsolete for that date and can be cleaned up by a migration.
class DropsheetService {
  final FirebaseFirestore _firestore;

  DropsheetService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  /// Month-collection id, e.g. `May 2026` (matches `DailyService`).
  String _monthId(DateTime date) =>
      '${_monthNames[date.month - 1]} ${date.year}';

  /// Year-document id, e.g. `2026`.
  String _yearId(DateTime date) => date.year.toString().padLeft(4, '0');

  /// New-layout day doc: `/dropsheet/{YYYY}/{MMM YYYY}/{YYYY-MM-DD}`.
  DocumentReference<Map<String, dynamic>> _dayDoc(DateTime date) {
    final dayId = DropsheetDay.docIdFor(date);
    return _firestore
        .collection('dropsheet')
        .doc(_yearId(date))
        .collection(_monthId(date))
        .doc(dayId);
  }

  /// Legacy-layout day doc: `/dropsheet/daily/days/{YYYY-MM-DD}`.
  DocumentReference<Map<String, dynamic>> _legacyDayDoc(DateTime date) {
    final dayId = DropsheetDay.docIdFor(date);
    return _firestore
        .collection('dropsheet')
        .doc('daily')
        .collection('days')
        .doc(dayId);
  }

  /// Streams the day, preferring the new layout but falling back to the
  /// legacy doc whenever the new doc is missing/empty. Re-checks the
  /// legacy doc on every empty snapshot, so a legacy-only day will still
  /// surface on subscribe.
  Stream<DropsheetDay> streamDay(DateTime date) async* {
    final id = DropsheetDay.docIdFor(date);
    final newDoc = _dayDoc(date);

    await for (final snap in newDoc.snapshots()) {
      if (snap.exists && snap.data() != null) {
        yield DropsheetDay.fromMap(id, snap.data()!);
        continue;
      }

      // New-layout doc absent — try legacy.
      try {
        final legacy = await _legacyDayDoc(date).get();
        if (legacy.exists && legacy.data() != null) {
          yield DropsheetDay.fromMap(id, legacy.data()!);
          continue;
        }
      } catch (_) {
        // Ignore legacy fetch errors — fall through to empty day.
      }

      yield DropsheetDay(date: date);
    }
  }

  /// [streamDay] plus whether each snapshot came from the local cache.
  ///
  /// A device that hasn't opened a day for a while holds an old copy in its
  /// offline cache, and that copy is delivered first. The provider must not
  /// auto-sync (and save) against it — on 2026-10-13 a stale cached copy of
  /// the day, re-synced and written back with `set`, wiped the drivers'
  /// allocations an hour after the sheet was printed. Metadata changes are
  /// included so the cache → server flip is always delivered, even when the
  /// server copy is identical to the cached one.
  Stream<({DropsheetDay day, bool fromCache})> streamDayWithSource(
      DateTime date) async* {
    final id = DropsheetDay.docIdFor(date);
    final newDoc = _dayDoc(date);

    await for (final snap in newDoc.snapshots(includeMetadataChanges: true)) {
      final fromCache = snap.metadata.isFromCache;
      if (snap.exists && snap.data() != null) {
        yield (day: DropsheetDay.fromMap(id, snap.data()!), fromCache: fromCache);
        continue;
      }

      try {
        final legacy = await _legacyDayDoc(date).get();
        if (legacy.exists && legacy.data() != null) {
          yield (
            day: DropsheetDay.fromMap(id, legacy.data()!),
            fromCache: fromCache || legacy.metadata.isFromCache,
          );
          continue;
        }
      } catch (_) {
        // Ignore legacy fetch errors — fall through to empty day.
      }

      yield (day: DropsheetDay(date: date), fromCache: fromCache);
    }
  }

  /// Read-modify-write of a saved day in one transaction, so a patch made
  /// for a sheet nobody has open never lands on a stale cached copy (see
  /// [streamDayWithSource]) or over a concurrent edit. [mutate] returns null
  /// to leave the day as it is. Days not saved under the new layout are
  /// skipped. Returns whether anything was written.
  Future<bool> updateDayTxn(
      DateTime date, DropsheetDay? Function(DropsheetDay day) mutate) {
    final ref = _dayDoc(date);
    return _firestore.runTransaction((txn) async {
      final snap = await txn.get(ref);
      final data = snap.data();
      if (!snap.exists || data == null) return false;
      final next = mutate(DropsheetDay.fromMap(DropsheetDay.docIdFor(date), data));
      if (next == null) return false;
      txn.set(ref, next.toMap());
      return true;
    });
  }

  /// One-shot fetch with the same new-then-legacy fallback as [streamDay].
  Future<DropsheetDay> getDay(DateTime date) async {
    final id = DropsheetDay.docIdFor(date);

    final newSnap = await _dayDoc(date).get();
    if (newSnap.exists && newSnap.data() != null) {
      return DropsheetDay.fromMap(id, newSnap.data()!);
    }

    final legacy = await _legacyDayDoc(date).get();
    if (legacy.exists && legacy.data() != null) {
      return DropsheetDay.fromMap(id, legacy.data()!);
    }

    return DropsheetDay(date: date);
  }

  /// Writes the day to the **new** layout only. Legacy docs are left
  /// untouched here — migration tooling is responsible for cleanup.
  Future<void> saveDay(DropsheetDay day) async {
    await _dayDoc(day.date).set(day.toMap(), SetOptions(merge: false));
  }
}
