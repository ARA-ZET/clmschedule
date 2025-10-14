import '../models/command.dart';
import '../models/job.dart';
import '../services/firestore_service.dart';

/// Command for adding a job to the schedule
class AddJobCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final DateTime targetDate;
  String? _addedJobId;

  AddJobCommand({
    required FirestoreService service,
    required Job job,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.add,
          modifiedEntity: job,
          context: {'targetDate': targetDate},
        );

  @override
  Future<void> execute() async {
    if (modifiedEntity == null) {
      throw Exception('Cannot add null job');
    }

    _addedJobId = await _service.addJob(modifiedEntity!, targetDate);
  }

  @override
  Future<void> undo() async {
    if (_addedJobId == null) {
      throw Exception('Cannot undo: no job ID recorded');
    }

    await _service.deleteJob(_addedJobId!, targetDate);
  }

  @override
  String get description =>
      'Add job for ${modifiedEntity?.clients.join(', ') ?? 'client'}';
}

/// Command for editing a job in the schedule
class EditJobCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final DateTime targetDate;

  EditJobCommand({
    required FirestoreService service,
    required Job originalJob,
    required Job modifiedJob,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          originalEntity: originalJob,
          modifiedEntity: modifiedJob,
          context: {'targetDate': targetDate},
        );

  @override
  Future<void> execute() async {
    if (modifiedEntity == null) {
      throw Exception('Cannot update with null job');
    }

    await _service.updateJob(modifiedEntity!, targetDate);
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null) {
      throw Exception('Cannot undo: no original job recorded');
    }

    await _service.updateJob(originalEntity!, targetDate);
  }

  @override
  String get description =>
      'Edit job for ${originalEntity?.clients.join(', ') ?? 'client'}';
}

/// Command for deleting a job from the schedule
class DeleteJobCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final DateTime targetDate;

  DeleteJobCommand({
    required FirestoreService service,
    required Job job,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.delete,
          originalEntity: job,
          context: {'targetDate': targetDate},
        );

  @override
  Future<void> execute() async {
    if (originalEntity == null || originalEntity!.id.isEmpty) {
      throw Exception('Cannot delete job: invalid ID');
    }

    await _service.deleteJob(originalEntity!.id, targetDate);
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null) {
      throw Exception('Cannot undo: no original job recorded');
    }

    // Re-add the deleted job
    await _service.addJob(originalEntity!, targetDate);
  }

  @override
  String get description =>
      'Delete job for ${originalEntity?.clients.join(', ') ?? 'client'}';
}

/// Command for updating job status only
class UpdateJobStatusCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final String jobId;
  final String newStatusId;
  final String originalStatusId;
  final DateTime targetDate;

  UpdateJobStatusCommand({
    required FirestoreService service,
    required this.jobId,
    required this.newStatusId,
    required this.originalStatusId,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          context: {
            'jobId': jobId,
            'newStatusId': newStatusId,
            'originalStatusId': originalStatusId,
            'targetDate': targetDate,
          },
        );

  @override
  Future<void> execute() async {
    // We need to get the current job, update its status, and save it
    // This is a simplified approach - in practice you might want a dedicated method
    await _updateJobStatus(jobId, newStatusId);
  }

  @override
  Future<void> undo() async {
    await _updateJobStatus(jobId, originalStatusId);
  }

  Future<void> _updateJobStatus(String jobId, String statusId) async {
    // Get current jobs to find the one to update
    final jobs = await _service.fetchJobsForMonth(targetDate);
    final job = jobs.firstWhere((j) => j.id == jobId);

    // Create updated job with new status
    final updatedJob = Job(
      id: job.id,
      clients: job.clients,
      workingAreas: job.workingAreas,
      workMaps: job.workMaps,
      distributorId: job.distributorId,
      date: job.date,
      statusId: statusId,
    );

    await _service.updateJob(updatedJob, targetDate);
  }

  @override
  String get description => 'Change job status';
}

/// Command for optimized job operations (when multiple jobs are affected)
class OptimizedJobCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final List<Job> currentJobs;
  final DateTime targetDate;
  final Job? jobToUpdate;
  final String? jobIdToDelete;

  OptimizedJobCommand({
    required FirestoreService service,
    required this.currentJobs,
    required this.targetDate,
    Job? originalJob,
    Job? modifiedJob,
    this.jobToUpdate,
    this.jobIdToDelete,
    super.operation = OperationType.edit,
  })  : _service = service,
        super(
          originalEntity: originalJob,
          modifiedEntity: modifiedJob,
          context: {
            'targetDate': targetDate,
            'currentJobs': currentJobs,
          },
        );

  @override
  Future<void> execute() async {
    if (operation == OperationType.edit && jobToUpdate != null) {
      await _service.updateJobOptimized(jobToUpdate!, currentJobs, targetDate);
    } else if (operation == OperationType.delete && jobIdToDelete != null) {
      await _service.deleteJobOptimized(
          jobIdToDelete!, currentJobs, targetDate);
    } else {
      throw Exception('Invalid optimized job command configuration');
    }
  }

  @override
  Future<void> undo() async {
    // For optimized operations, we need to restore the original state
    if (operation == OperationType.edit && originalEntity != null) {
      await _service.updateJobOptimized(
          originalEntity!, currentJobs, targetDate);
    } else if (operation == OperationType.delete && originalEntity != null) {
      // Re-add the deleted job
      await _service.addJob(originalEntity!, targetDate);
    }
  }

  @override
  String get description => operation == OperationType.edit
      ? 'Edit job (optimized)'
      : 'Delete job (optimized)';
}

/// Command for swapping two jobs
class SwapJobsCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final Job draggedJob;
  final Job targetJob;
  final DateTime targetDate;

  SwapJobsCommand({
    required FirestoreService service,
    required this.draggedJob,
    required this.targetJob,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          originalEntity: draggedJob,
          modifiedEntity: targetJob,
          context: {
            'targetDate': targetDate,
            'operation': 'swap',
          },
        );

  @override
  Future<void> execute() async {
    // Swap positions: update dragged job to target position
    final updatedDraggedJob = draggedJob.copyWith(
      distributorId: targetJob.distributorId,
      date: targetJob.date,
    );

    // Update target job to dragged job's original position
    final updatedTargetJob = targetJob.copyWith(
      distributorId: draggedJob.distributorId,
      date: draggedJob.date,
    );

    // Execute both updates
    await _service.updateJob(updatedDraggedJob, targetDate);
    await _service.updateJob(updatedTargetJob, targetDate);
  }

  @override
  Future<void> undo() async {
    // Restore original positions
    await _service.updateJob(draggedJob, targetDate);
    await _service.updateJob(targetJob, targetDate);
  }

  @override
  String get description =>
      'Swap jobs: ${draggedJob.clientsDisplay} ↔ ${targetJob.clientsDisplay}';
}

/// Command for combining two jobs
class CombineJobsCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final Job draggedJob;
  final Job targetJob;
  final Job combinedJob;
  final DateTime targetDate;

  CombineJobsCommand({
    required FirestoreService service,
    required this.draggedJob,
    required this.targetJob,
    required this.combinedJob,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          originalEntity: targetJob,
          modifiedEntity: combinedJob,
          context: {
            'targetDate': targetDate,
            'operation': 'combine',
            'deletedJob': draggedJob,
          },
        );

  @override
  Future<void> execute() async {
    // Update target job with combined data
    await _service.updateJob(combinedJob, targetDate);
    // Delete the dragged job
    await _service.deleteJob(draggedJob.id, targetDate);
  }

  @override
  Future<void> undo() async {
    // Restore original target job
    await _service.updateJob(targetJob, targetDate);
    // Restore the deleted dragged job
    await _service.addJob(draggedJob, targetDate);
  }

  @override
  String get description =>
      'Combine jobs: ${draggedJob.clientsDisplay} → ${targetJob.clientsDisplay}';
}

/// Command for copying and combining jobs (preserves source)
class CopyAndCombineJobsCommand extends EntityCommand<Job> {
  final FirestoreService _service;
  final Job targetJob;
  final Job combinedJob;
  final DateTime targetDate;

  CopyAndCombineJobsCommand({
    required FirestoreService service,
    required this.targetJob,
    required this.combinedJob,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          originalEntity: targetJob,
          modifiedEntity: combinedJob,
          context: {
            'targetDate': targetDate,
            'operation': 'copy_combine',
          },
        );

  @override
  Future<void> execute() async {
    // Update target job with combined data (source job remains unchanged)
    await _service.updateJob(combinedJob, targetDate);
  }

  @override
  Future<void> undo() async {
    // Restore original target job
    await _service.updateJob(targetJob, targetDate);
  }

  @override
  String get description => 'Copy & combine to: ${targetJob.clientsDisplay}';
}
