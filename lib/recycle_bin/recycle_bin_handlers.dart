// recycle_bin/recycle_bin_handlers.dart
//
// Which handler restores which type of deleted item. A type without a
// handler can sit in the bin and be purged, but not restored.
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../providers/schedule_provider.dart';
import '../services/gpx_storage_service.dart';
import '../services/reference_cache_service.dart';
import 'recycle_bin_entry.dart';
import 'recycle_bin_service.dart';

Map<RecycleBinType, RecycleBinHandler> buildRecycleBinHandlers(
    riverpod.Ref ref) {
  return {
    // Share links come back with it (as related docs) when their codes are
    // still free, so links already sent to clients work again.
    RecycleBinType.shareableMap: DocRestoreHandler(noun: 'map'),
    RecycleBinType.clientArea: DocRestoreHandler(noun: 'client area'),
    RecycleBinType.workArea: DocRestoreHandler(noun: 'work area'),
    RecycleBinType.scheduleJob: _ScheduleJobHandler(ref),
    // The job's invoice indexes and Happy Sun project come back in the same
    // transaction, so the Job List listener finds the project already there
    // and doesn't create a fresh one over it.
    RecycleBinType.jobListItem: DocRestoreHandler(noun: 'job'),
    RecycleBinType.cloudFile: _CloudFilesHandler(),
    RecycleBinType.cloudFolder: _CloudFilesHandler(),
    RecycleBinType.regularClient: DocRestoreHandler(noun: 'regular client'),
    // Payroll, advances, savings and days off were keyed by the same id and
    // never deleted, so they reconnect on their own.
    RecycleBinType.distributor: DocRestoreHandler(noun: 'distributor'),
    RecycleBinType.driver: DocRestoreHandler(noun: 'driver'),
    RecycleBinType.unfinishedWorkArea:
        DocRestoreHandler(noun: 'unfinished work area'),
    for (final t in const [
      RecycleBinType.jobType,
      RecycleBinType.jobStatus,
      RecycleBinType.jobListStatus,
      RecycleBinType.invoiceStatus,
      RecycleBinType.mapInstruction,
    ])
      t: DocRestoreHandler(
        noun: 'setting',
        afterRestore: _bumpReferenceCache,
      ),
  };
}

/// Settings lists are cached per session; bump the collection's version so
/// every open app reloads it with the restored entry.
Future<void> _bumpReferenceCache(RecycleBinEntry entry) =>
    ReferenceCacheService.bumpVersion(entry.originalPath.split('/').first);

/// Copies deleted Cloud Files back; the Storage triggers then recompile and
/// re-index the folders as for any upload.
class _CloudFilesHandler implements RecycleBinHandler {
  @override
  Future<void> restore(RecycleBinEntry entry, RestoreContext ctx) async {
    await GpxStorageService().restoreFromBin(entry.id);
    await ctx.markRestored();
  }
}

/// Puts a deleted job back on its day through the Schedule's write queue, so
/// it shows at once and is logged like any schedule change.
class _ScheduleJobHandler implements RecycleBinHandler {
  final riverpod.Ref ref;
  _ScheduleJobHandler(this.ref);

  @override
  Future<void> restore(RecycleBinEntry entry, RestoreContext ctx) => ref
      .read(scheduleRiverpod)
      .restoreJobFromBin(entry.payload, ctx.entryRef, ctx.restoredFields);
}
