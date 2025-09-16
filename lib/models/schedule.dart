import 'distributor.dart';
import 'job.dart';

class Schedule {
  final List<Distributor> distributors;
  final List<Job> jobs;

  Schedule({required this.distributors, required this.jobs});

  // Helper method to get jobs for a specific distributor and date
  List<Job> getJobsForDistributorAndDate(String distributorId, DateTime date) {
    return jobs
        .where(
          (job) =>
              job.distributorId == distributorId &&
              job.date.year == date.year &&
              job.date.month == date.month &&
              job.date.day == date.day,
        )
        .toList();
  }

  // Helper method to get all jobs for a specific distributor
  List<Job> getJobsForDistributor(String distributorId) {
    return jobs.where((job) => job.distributorId == distributorId).toList();
  }

  // Helper method to get all jobs for a specific date
  List<Job> getJobsForDate(DateTime date) {
    return jobs
        .where(
          (job) =>
              job.date.year == date.year &&
              job.date.month == date.month &&
              job.date.day == date.day,
        )
        .toList();
  }

  // Helper method to find a distributor by id
  Distributor? findDistributor(String id) {
    try {
      return distributors.firstWhere((d) => d.id == id);
    } catch (_) {
      return null;
    }
  }

  // Helper method to find a job by id
  Job? findJob(String id) {
    try {
      return jobs.firstWhere((j) => j.id == id);
    } catch (_) {
      return null;
    }
  }

  // Create a copy of schedule with updated jobs and/or distributors
  Schedule copyWith({List<Distributor>? distributors, List<Job>? jobs}) {
    return Schedule(
      distributors: distributors ?? this.distributors,
      jobs: jobs ?? this.jobs,
    );
  }
}
