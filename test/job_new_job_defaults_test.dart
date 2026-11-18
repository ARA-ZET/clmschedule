// Two Add/Edit Job rules from 2026-11-10:
//  * "Needs flyer collection" starts ticked on a new or copied job.
//  * When adding or copying a job, Date and Collection Date can't be in the
//    past. A job copied from May with its date left alone landed back in
//    May. Editing an existing job is never checked (user rule).
import 'package:clmschedule/models/job_list_item.dart';
import 'package:clmschedule/utils/job_lifecycle_rules.dart';
import 'package:flutter_test/flutter_test.dart';

JobListItem _job({bool needsFlyerCollection = false}) => JobListItem(
      id: 'jl-1',
      invoice: '',
      amount: 0,
      client: 'Spar Bellville',
      jobStatusId: 'standby',
      jobTypeId: 'flyerDistribution',
      area: 'Bellville',
      quantity: 5000,
      manDays: 1,
      date: DateTime(2026, 5, 12),
      collectionAddress: '',
      collectionDate: DateTime(2000, 1, 1),
      needsFlyerCollection: needsFlyerCollection,
      specialInstructions: '',
      quantityDistributed: 0,
      invoiceDetails: '',
      reportAddresses: '',
      whoToInvoice: '',
    );

void main() {
  group('Needs flyer collection starts', () {
    test('ticked on a new job', () {
      expect(initialNeedsFlyerCollection(null, isCopy: false), isTrue);
    });

    test('ticked on a copy, whatever the old job had', () {
      expect(initialNeedsFlyerCollection(_job(), isCopy: true), isTrue);
      expect(
          initialNeedsFlyerCollection(_job(needsFlyerCollection: true),
              isCopy: true),
          isTrue);
    });

    test('as it was on an existing job, so an untick is not undone', () {
      expect(initialNeedsFlyerCollection(_job(), isCopy: false), isFalse);
      expect(
          initialNeedsFlyerCollection(_job(needsFlyerCollection: true),
              isCopy: false),
          isTrue);
    });

    test('older jobs saved before the tick read as unticked', () {
      final old = _job().toMap()..remove('needsFlyerCollection');
      expect(JobListItem.fromMap('jl-1', old).needsFlyerCollection, isFalse);
    });
  });

  group('adding or copying a job, the date', () {
    final today = DateTime(2026, 11, 10);
    String? problem(DateTime? d, {DateTime? now}) =>
        pastJobDateProblem(d, isNewOrCopy: true, today: now ?? today);

    test('copied from May is refused', () {
      expect(problem(DateTime(2026, 5, 12)), isNotNull);
    });

    test('yesterday is refused', () {
      expect(problem(DateTime(2026, 11, 9)), isNotNull);
    });

    test('today, at any time of day, is fine', () {
      expect(problem(DateTime(2026, 11, 10)), isNull);
      expect(problem(DateTime(2026, 11, 10, 8, 30)), isNull);
      // "today" may carry the clock time too.
      expect(problem(DateTime(2026, 11, 10), now: DateTime(2026, 11, 10, 17)),
          isNull);
    });

    test('a later day is fine', () {
      expect(problem(DateTime(2026, 11, 11)), isNull);
      expect(problem(DateTime(2027, 1, 4)), isNull);
    });

    test('no date is left to the "required" check', () {
      expect(problem(null), isNull);
    });
  });

  group('editing an existing job, the date', () {
    test('is not checked: a past date stays or can be picked', () {
      final today = DateTime(2026, 11, 10);
      expect(
          pastJobDateProblem(DateTime(2026, 5, 12),
              isNewOrCopy: false, today: today),
          isNull);
      expect(
          pastJobDateProblem(DateTime(2026, 11, 9),
              isNewOrCopy: false, today: today),
          isNull);
    });
  });

  group('the date picker goes back', () {
    final today = DateTime(2026, 11, 10, 15, 20);

    test('only to today when adding or copying a job', () {
      expect(earliestPickableJobDate(isNewOrCopy: true, today: today),
          DateTime(2026, 11, 10));
    });

    test('to 2020 when editing, as before', () {
      expect(earliestPickableJobDate(isNewOrCopy: false, today: today),
          DateTime(2020));
    });
  });
}
