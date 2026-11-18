import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/models/job.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/job_assignment_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeSchedule extends Fake implements ScheduleProvider {
  _FakeSchedule(this.distributors, this.jobs);

  @override
  final List<Distributor> distributors;
  @override
  final List<Job> jobs;

  @override
  List<Job> getJobsForDate(DateTime date) => jobs
      .where((j) =>
          j.date.year == date.year &&
          j.date.month == date.month &&
          j.date.day == date.day)
      .toList();
}

void main() {
  final day = DateTime(2026, 10, 7);
  final distributors = [
    Distributor(id: 'a', name: 'Anna', index: 0),
    Distributor(id: 'b', name: 'Ben', index: 1),
    Distributor(
        id: 'c', name: 'Cara', index: 2, status: DistributorStatus.inactive),
  ];
  Job busy(String id) => Job(
        id: 'job-$id',
        clients: const ['Existing'],
        workingAreas: const ['Area'],
        workMaps: const [],
        distributorId: id,
        date: day,
        statusId: 'logged',
      );

  test('busy distributors are skipped unless double-booking is allowed', () {
    final service =
        JobAssignmentService(_FakeSchedule(distributors, [busy('a')]));

    expect(service.candidatesFor(day).map((c) => c.distributor.id), ['b']);

    final all = service.candidatesFor(day, allowOccupied: true);
    // Free first, then busy; inactive never offered.
    expect(all.map((c) => c.distributor.id), ['b', 'a']);
    expect(all.map((c) => c.hasJobThatDay), [false, true]);
  });

  test('double-booking keeps the booked date instead of spilling', () {
    final service = JobAssignmentService(
        _FakeSchedule(distributors, [busy('a'), busy('b')]));

    final spilled = service.calculateJobAssignments(
        client: 'X', manDays: 1, startDate: day);
    expect(spilled.single.date, DateTime(2026, 10, 8));

    final kept = service.calculateJobAssignments(
        client: 'X', manDays: 1, startDate: day, allowOccupied: true);
    expect(kept.single.date, day);
    expect(kept.single.distributorId, 'a');
  });

  test('nobody eligible returns empty instead of looping forever', () {
    final service = JobAssignmentService(_FakeSchedule(const [], const []));
    expect(
        service.calculateJobAssignments(
            client: 'X', manDays: 2, startDate: day),
        isEmpty);
  });
}
