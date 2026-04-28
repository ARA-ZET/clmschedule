// providers/cloud_transfer_provider.dart
//
// Background queue for long-running Cloud Storage transfers (copy / move).
//
// Why a singleton?
//   The user can kick off a multi-file move and then navigate away from the
//   Cloud File Manager — the transfers must keep running. Holding the jobs
//   in a top-level `ChangeNotifierProvider` keeps them alive across page
//   changes and lets any UI surface (a mini-banner, a progress list) watch
//   the same state.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../services/gpx_storage_service.dart';

/// Riverpod hook for the singleton transfer queue.
final cloudTransferRiverpod =
    riverpod.ChangeNotifierProvider<CloudTransferProvider>(
  (ref) => CloudTransferProvider(),
);

enum CloudTransferOp { copy, move }

enum CloudTransferStatus { pending, running, done, error }

class CloudTransferJob {
  final String id;
  final CloudTransferOp op;
  final List<StorageFileItem> files;
  final String destinationFolder;

  int completed = 0;
  int failed = 0;
  CloudTransferStatus status = CloudTransferStatus.pending;
  String? error;
  DateTime? startedAt;
  DateTime? finishedAt;

  /// Names of the files that failed, with error text (for a detail view).
  final List<({String fileName, String message})> failures = [];

  /// Name of the file currently in flight (for live status display).
  String? currentFileName;

  CloudTransferJob({
    required this.id,
    required this.op,
    required this.files,
    required this.destinationFolder,
  });

  int get total => files.length;
  double get progress => total == 0 ? 0 : completed / total;
  bool get isTerminal =>
      status == CloudTransferStatus.done || status == CloudTransferStatus.error;

  String get label => op == CloudTransferOp.copy ? 'Copying' : 'Moving';
}

class CloudTransferProvider extends ChangeNotifier {
  final GpxStorageService _storage = GpxStorageService();
  final List<CloudTransferJob> _jobs = [];

  List<CloudTransferJob> get jobs => List.unmodifiable(_jobs);
  List<CloudTransferJob> get activeJobs => _jobs
      .where(
        (j) =>
            j.status == CloudTransferStatus.running ||
            j.status == CloudTransferStatus.pending,
      )
      .toList(growable: false);

  bool get hasActive => activeJobs.isNotEmpty;

  /// Folder paths to refresh once each job completes. Surfaces to the UI so
  /// the cloud file manager can reload the current folder when the transfer
  /// happens to land in (or out of) it.
  final Set<String> _dirtyFolders = {};
  Set<String> consumeDirtyFolders() {
    final snap = Set<String>.from(_dirtyFolders);
    _dirtyFolders.clear();
    return snap;
  }

  /// Enqueue a copy or move. Runs immediately on the event loop.
  CloudTransferJob enqueue({
    required CloudTransferOp op,
    required List<StorageFileItem> files,
    required String destinationFolder,
  }) {
    final job = CloudTransferJob(
      id: '${DateTime.now().microsecondsSinceEpoch}_${_jobs.length}',
      op: op,
      files: List.unmodifiable(files),
      destinationFolder: destinationFolder,
    );
    _jobs.add(job);
    notifyListeners();
    // Fire & forget — never await, so the caller can unmount.
    // ignore: unawaited_futures
    _run(job);
    return job;
  }

  Future<void> _run(CloudTransferJob job) async {
    job.status = CloudTransferStatus.running;
    job.startedAt = DateTime.now();
    notifyListeners();

    final affectedFolders = <String>{job.destinationFolder};

    for (final file in job.files) {
      job.currentFileName = file.name;
      notifyListeners();
      final dst = '${job.destinationFolder}/${file.name}';
      if (dst == file.fullPath) {
        // Skip no-op (copy to same folder) but count as completed so the
        // progress bar reaches 100% instead of stalling.
        job.completed++;
        notifyListeners();
        continue;
      }
      try {
        if (job.op == CloudTransferOp.copy) {
          await _storage.copyFile(file.fullPath, dst);
        } else {
          await _storage.moveFile(file.fullPath, dst);
          final slash = file.fullPath.lastIndexOf('/');
          if (slash > 0) {
            final srcFolder = file.fullPath.substring(0, slash);
            affectedFolders.add(srcFolder);
            // Publish incrementally so any open folder view refreshes as
            // soon as a file leaves/arrives instead of waiting for the
            // whole batch to finish.
            _dirtyFolders.add(srcFolder);
          }
        }
        _dirtyFolders.add(job.destinationFolder);
        job.completed++;
      } catch (e) {
        job.failed++;
        job.failures.add((fileName: file.name, message: e.toString()));
        debugPrint('CloudTransfer: ${job.op.name} failed ${file.fullPath} → '
            '$dst: $e');
      }
      notifyListeners();
    }

    job.currentFileName = null;

    // Rebuild compiled waypoints for any folder touched by the job.
    for (final folder in affectedFolders) {
      if (folder.isEmpty) continue;
      try {
        await _storage.regenerateCompiledWaypoints(folder);
      } catch (e) {
        debugPrint('CloudTransfer: rebuild compiled($folder) failed: $e');
      }
    }

    _dirtyFolders.addAll(affectedFolders);

    if (job.failed == 0) {
      job.status = CloudTransferStatus.done;
    } else if (job.completed == 0) {
      job.status = CloudTransferStatus.error;
      job.error = 'All ${job.total} file(s) failed.';
    } else {
      // Partial success — still mark done with error text.
      job.status = CloudTransferStatus.done;
      job.error = '${job.failed} of ${job.total} file(s) failed.';
    }
    job.finishedAt = DateTime.now();
    notifyListeners();
  }

  /// Remove a finished job from the list. Does nothing for running jobs.
  void dismiss(CloudTransferJob job) {
    if (!job.isTerminal) return;
    _jobs.remove(job);
    notifyListeners();
  }

  void dismissAllDone() {
    _jobs.removeWhere((j) => j.isTerminal);
    notifyListeners();
  }
}
