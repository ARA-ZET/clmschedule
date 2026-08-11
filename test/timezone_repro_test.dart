import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:clmschedule/models/job.dart';

/// Reproduction of the Ireland day-shift bug, exercised through the real Job
/// model. Run under Irish time to mirror the colleague's environment:
///   TZ=Europe/Dublin flutter test test/timezone_repro_test.dart
void main() {
  // Grid column bucket key, copied from ScheduleProvider._lookupMap.
  String bucketKey(Job job) =>
      '${job.distributorId}:${job.date.year}-'
      '${job.date.month.toString().padLeft(2, '0')}-'
      '${job.date.day.toString().padLeft(2, '0')}';

  Job makeJob(DateTime date) => Job(
        id: 'j1',
        clients: const ['ACME'],
        workingAreas: const ['Area 1'],
        workMaps: const [],
        distributorId: 'dist1',
        date: date,
        statusId: 'scheduled',
      );

  test('prints the running timezone (sanity)', () {
    final now = DateTime.now();
    // ignore: avoid_print
    print('Running under: ${now.timeZoneName} offset=${now.timeZoneOffset}');
  });

  test('a job scheduled for Jul 20 stays on Jul 20 when read in Ireland', () {
    // App creates the job for the Jul 20 column (a civil calendar day).
    final created = makeJob(DateTime(2026, 7, 20));

    // Persist exactly as the app does, then read it back exactly as the app
    // does (fromMap runs the +2 anchor, independent of the reader's timezone).
    final stored = created.toMap();
    final readBack = Job.fromMap('j1', stored);

    expect(readBack.date.year, 2026);
    expect(readBack.date.month, 7);
    expect(readBack.date.day, 20, reason: 'must not slip to Jul 19 in Ireland');
    expect(bucketKey(readBack), 'dist1:2026-07-20');
  });

  test('legacy SAST record (raw 22:00Z Jul 19 Timestamp) reads as Jul 20', () {
    // A job written before the fix by a SAST client: local midnight Jul 20 was
    // stored as 2026-07-19T22:00:00Z.
    final legacy = <String, dynamic>{
      'id': 'j1',
      'clients': ['ACME'],
      'workingAreas': ['Area 1'],
      'distributorId': 'dist1',
      'statusId': 'scheduled',
      'date': Timestamp.fromDate(DateTime.utc(2026, 7, 19, 22, 0, 0)),
    };

    final job = Job.fromMap('j1', legacy);
    expect(job.date.day, 20, reason: 'old data must also resolve to Jul 20');
    expect(bucketKey(job), 'dist1:2026-07-20');
  });
}
