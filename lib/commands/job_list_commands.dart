import '../models/command.dart';
import '../models/job_list_item.dart';
import '../services/job_list_service.dart';

/// Command for adding a job list item
class AddJobListItemCommand extends EntityCommand<JobListItem> {
  final JobListService _service;
  final DateTime targetDate;
  String? _addedItemId;

  AddJobListItemCommand({
    required JobListService service,
    required JobListItem jobListItem,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.add,
          modifiedEntity: jobListItem,
          context: {'targetDate': targetDate},
        );

  @override
  Future<void> execute() async {
    if (modifiedEntity == null) {
      throw Exception('Cannot add null job list item');
    }

    _addedItemId = await _service.addJobListItem(modifiedEntity!, targetDate);
  }

  @override
  Future<void> undo() async {
    if (_addedItemId == null) {
      throw Exception('Cannot undo: no item ID recorded');
    }

    await _service.deleteJobListItem(_addedItemId!, targetDate);
  }

  @override
  String get description =>
      'Add ${modifiedEntity?.jobType.displayName ?? 'job'}';
}

/// Command for editing a job list item
class EditJobListItemCommand extends EntityCommand<JobListItem> {
  final JobListService _service;
  final DateTime targetDate;

  EditJobListItemCommand({
    required JobListService service,
    required JobListItem originalItem,
    required JobListItem modifiedItem,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          originalEntity: originalItem,
          modifiedEntity: modifiedItem,
          context: {'targetDate': targetDate},
        );

  @override
  Future<void> execute() async {
    if (modifiedEntity == null) {
      throw Exception('Cannot update with null job list item');
    }

    await _service.updateJobListItem(modifiedEntity!, targetDate);
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null) {
      throw Exception('Cannot undo: no original item recorded');
    }

    await _service.updateJobListItem(originalEntity!, targetDate);
  }

  @override
  String get description =>
      'Edit ${originalEntity?.jobType.displayName ?? 'job'}';
}

/// Command for deleting a job list item
class DeleteJobListItemCommand extends EntityCommand<JobListItem> {
  final JobListService _service;
  final DateTime targetDate;

  DeleteJobListItemCommand({
    required JobListService service,
    required JobListItem jobListItem,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.delete,
          originalEntity: jobListItem,
          context: {'targetDate': targetDate},
        );

  @override
  Future<void> execute() async {
    if (originalEntity == null || originalEntity!.id.isEmpty) {
      throw Exception('Cannot delete job list item: invalid ID');
    }

    await _service.deleteJobListItem(originalEntity!.id, targetDate);
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null) {
      throw Exception('Cannot undo: no original item recorded');
    }

    // Re-add the deleted item
    await _service.addJobListItem(originalEntity!, targetDate);
  }

  @override
  String get description =>
      'Delete ${originalEntity?.jobType.displayName ?? 'job'}';
}

/// Command for updating job status only
class UpdateJobStatusCommand extends EntityCommand<JobListItem> {
  final JobListService _service;
  final String jobId;
  final JobListStatus newStatus;
  final JobListStatus originalStatus;
  final DateTime targetDate;

  UpdateJobStatusCommand({
    required JobListService service,
    required this.jobId,
    required this.newStatus,
    required this.originalStatus,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          context: {
            'jobId': jobId,
            'newStatus': newStatus,
            'originalStatus': originalStatus,
            'targetDate': targetDate,
          },
        );

  @override
  Future<void> execute() async {
    await _service.updateJobStatus(jobId, newStatus, targetDate);
  }

  @override
  Future<void> undo() async {
    await _service.updateJobStatus(jobId, originalStatus, targetDate);
  }

  @override
  String get description => 'Change status to ${newStatus.displayName}';
}

/// Command for moving a job list item to a different month
class MoveJobListItemCommand extends EntityCommand<JobListItem> {
  final JobListService _service;
  final DateTime fromDate;
  final DateTime toDate;

  MoveJobListItemCommand({
    required JobListService service,
    required JobListItem jobListItem,
    required this.fromDate,
    required this.toDate,
  })  : _service = service,
        super(
          operation: OperationType.move,
          originalEntity: jobListItem,
          modifiedEntity: jobListItem.copyWith(date: toDate),
          context: {
            'fromDate': fromDate,
            'toDate': toDate,
          },
        );

  @override
  Future<void> execute() async {
    if (originalEntity == null) {
      throw Exception('Cannot move null job list item');
    }

    await _service.moveJobListItemToMonth(originalEntity!, fromDate, toDate);
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null) {
      throw Exception('Cannot undo: no original item recorded');
    }

    await _service.moveJobListItemToMonth(originalEntity!, toDate, fromDate);
  }

  @override
  String get description =>
      'Move ${originalEntity?.jobType.displayName ?? 'job'} to ${toDate.month}/${toDate.year}';
}
