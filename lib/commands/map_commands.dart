import '../models/command.dart';
import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../services/firestore_service.dart';

/// Command for adding a polygon to a job's work map
class AddPolygonToJobCommand extends EntityCommand<CustomPolygon> {
  final FirestoreService _service;
  final String jobId;
  final DateTime targetDate;

  AddPolygonToJobCommand({
    required FirestoreService service,
    required this.jobId,
    required CustomPolygon polygon,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.add,
          modifiedEntity: polygon,
          context: {
            'jobId': jobId,
            'targetDate': targetDate,
          },
        );

  @override
  Future<void> execute() async {
    if (modifiedEntity == null) {
      throw Exception('Cannot add null polygon');
    }

    await _updateJobWithPolygon(jobId, (job) {
      final updatedWorkMaps = List<CustomPolygon>.from(job.workMaps);
      updatedWorkMaps.add(modifiedEntity!);
      return job.copyWith(workMaps: updatedWorkMaps);
    });
  }

  @override
  Future<void> undo() async {
    if (modifiedEntity == null) {
      throw Exception('Cannot undo: no polygon recorded');
    }

    await _updateJobWithPolygon(jobId, (job) {
      final updatedWorkMaps = job.workMaps
          .where((polygon) => polygon.name != modifiedEntity!.name)
          .toList();
      return job.copyWith(workMaps: updatedWorkMaps);
    });
  }

  Future<void> _updateJobWithPolygon(
      String jobId, Job Function(Job) updater) async {
    final jobs = await _service.fetchJobsForMonth(targetDate);
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedJob = updater(job);
    await _service.updateJob(updatedJob, targetDate);
  }

  @override
  String get description =>
      'Add polygon "${modifiedEntity?.name ?? 'unnamed'}"';
}

/// Command for editing a polygon in a job's work map
class EditPolygonInJobCommand extends EntityCommand<CustomPolygon> {
  final FirestoreService _service;
  final String jobId;
  final DateTime targetDate;

  EditPolygonInJobCommand({
    required FirestoreService service,
    required this.jobId,
    required CustomPolygon originalPolygon,
    required CustomPolygon modifiedPolygon,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          originalEntity: originalPolygon,
          modifiedEntity: modifiedPolygon,
          context: {
            'jobId': jobId,
            'targetDate': targetDate,
          },
        );

  @override
  Future<void> execute() async {
    if (modifiedEntity == null || originalEntity == null) {
      throw Exception('Cannot edit polygon: missing data');
    }

    await _updateJobPolygon(originalEntity!, modifiedEntity!);
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null || modifiedEntity == null) {
      throw Exception('Cannot undo: missing polygon data');
    }

    await _updateJobPolygon(modifiedEntity!, originalEntity!);
  }

  Future<void> _updateJobPolygon(
      CustomPolygon oldPolygon, CustomPolygon newPolygon) async {
    final jobs = await _service.fetchJobsForMonth(targetDate);
    final job = jobs.firstWhere((j) => j.id == jobId);

    final updatedWorkMaps = job.workMaps.map((polygon) {
      if (polygon.name == oldPolygon.name) {
        return newPolygon;
      }
      return polygon;
    }).toList();

    final updatedJob = job.copyWith(workMaps: updatedWorkMaps);
    await _service.updateJob(updatedJob, targetDate);
  }

  @override
  String get description =>
      'Edit polygon "${originalEntity?.name ?? 'unnamed'}"';
}

/// Command for deleting a polygon from a job's work map
class DeletePolygonFromJobCommand extends EntityCommand<CustomPolygon> {
  final FirestoreService _service;
  final String jobId;
  final DateTime targetDate;

  DeletePolygonFromJobCommand({
    required FirestoreService service,
    required this.jobId,
    required CustomPolygon polygon,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.delete,
          originalEntity: polygon,
          context: {
            'jobId': jobId,
            'targetDate': targetDate,
          },
        );

  @override
  Future<void> execute() async {
    if (originalEntity == null) {
      throw Exception('Cannot delete null polygon');
    }

    await _updateJobWithPolygon(jobId, (job) {
      final updatedWorkMaps = job.workMaps
          .where((polygon) => polygon.name != originalEntity!.name)
          .toList();
      return job.copyWith(workMaps: updatedWorkMaps);
    });
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null) {
      throw Exception('Cannot undo: no polygon recorded');
    }

    await _updateJobWithPolygon(jobId, (job) {
      final updatedWorkMaps = List<CustomPolygon>.from(job.workMaps);
      updatedWorkMaps.add(originalEntity!);
      return job.copyWith(workMaps: updatedWorkMaps);
    });
  }

  Future<void> _updateJobWithPolygon(
      String jobId, Job Function(Job) updater) async {
    final jobs = await _service.fetchJobsForMonth(targetDate);
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedJob = updater(job);
    await _service.updateJob(updatedJob, targetDate);
  }

  @override
  String get description =>
      'Delete polygon "${originalEntity?.name ?? 'unnamed'}"';
}

/// Command for moving/reordering polygons within a job's work map
class MovePolygonInJobCommand extends EntityCommand<CustomPolygon> {
  final FirestoreService _service;
  final String jobId;
  final DateTime targetDate;
  final int fromIndex;
  final int toIndex;

  MovePolygonInJobCommand({
    required FirestoreService service,
    required this.jobId,
    required CustomPolygon polygon,
    required this.fromIndex,
    required this.toIndex,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.move,
          originalEntity: polygon,
          context: {
            'jobId': jobId,
            'fromIndex': fromIndex,
            'toIndex': toIndex,
            'targetDate': targetDate,
          },
        );

  @override
  Future<void> execute() async {
    await _movePolygon(fromIndex, toIndex);
  }

  @override
  Future<void> undo() async {
    await _movePolygon(toIndex, fromIndex);
  }

  Future<void> _movePolygon(int from, int to) async {
    final jobs = await _service.fetchJobsForMonth(targetDate);
    final job = jobs.firstWhere((j) => j.id == jobId);

    final updatedWorkMaps = List<CustomPolygon>.from(job.workMaps);
    final polygon = updatedWorkMaps.removeAt(from);
    updatedWorkMaps.insert(to, polygon);

    final updatedJob = job.copyWith(workMaps: updatedWorkMaps);
    await _service.updateJob(updatedJob, targetDate);
  }

  @override
  String get description =>
      'Move polygon "${originalEntity?.name ?? 'unnamed'}" from position $fromIndex to $toIndex';
}

/// Command for batch polygon operations (when multiple polygons are affected)
class BatchPolygonCommand extends EntityCommand<List<CustomPolygon>> {
  final FirestoreService _service;
  final String jobId;
  final DateTime targetDate;
  final List<CustomPolygon> newPolygons;

  BatchPolygonCommand({
    required FirestoreService service,
    required this.jobId,
    required List<CustomPolygon> originalPolygons,
    required this.newPolygons,
    required this.targetDate,
  })  : _service = service,
        super(
          operation: OperationType.edit,
          originalEntity: originalPolygons,
          modifiedEntity: newPolygons,
          context: {
            'jobId': jobId,
            'targetDate': targetDate,
          },
        );

  @override
  Future<void> execute() async {
    await _updateJobPolygons(newPolygons);
  }

  @override
  Future<void> undo() async {
    if (originalEntity == null) {
      throw Exception('Cannot undo: no original polygons recorded');
    }

    await _updateJobPolygons(originalEntity!);
  }

  Future<void> _updateJobPolygons(List<CustomPolygon> polygons) async {
    final jobs = await _service.fetchJobsForMonth(targetDate);
    final job = jobs.firstWhere((j) => j.id == jobId);
    final updatedJob = job.copyWith(workMaps: polygons);
    await _service.updateJob(updatedJob, targetDate);
  }

  @override
  String get description => 'Update ${newPolygons.length} polygons';
}
