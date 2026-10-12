import 'package:clmschedule/erf_property/models/erf_task.dart';
import 'package:flutter_test/flutter_test.dart';

ErfTask _task({int done = 0, int? total, DateTime? startedAt}) => ErfTask(
      title: 'Downloading Constantia',
      startedAt: startedAt,
      done: done,
      total: total,
      stages: const [
        ErfStage(label: 'Fetch parcels'),
        ErfStage(label: 'Pack into a file'),
        ErfStage(label: 'Upload'),
      ],
    );

void main() {
  group('ErfTask stages', () {
    test('activating a stage completes the ones before it', () {
      final t = _task().activateStage(2);

      expect(t.stages[0].status, ErfStageStatus.done);
      expect(t.stages[1].status, ErfStageStatus.done);
      expect(t.stages[2].status, ErfStageStatus.active);
      expect(t.stepNumber, 3);
    });

    test('activating past the last stage marks everything done', () {
      final t = _task().activateStage(0).activateStage(3);

      expect(t.stages.every((s) => s.status == ErfStageStatus.done), isTrue);
      expect(t.activeStageIndex, -1);
      expect(t.stepNumber, isNull);
    });

    test('detail updates only the active stage', () {
      final t = _task().activateStage(1).withDetail('3 000 of 9 954');

      expect(t.stages[1].detail, '3 000 of 9 954');
      expect(t.stages[0].detail, isNull);
      expect(t.stages[2].detail, isNull);
    });

    test('a failed stage keeps earlier ones marked done', () {
      final t = _task().activateStage(2).failActiveStage('upload rejected');

      expect(t.stages[0].status, ErfStageStatus.done);
      expect(t.stages[2].status, ErfStageStatus.failed);
      expect(t.stages[2].detail, 'upload rejected');
    });

    test('failing with nothing active is a no-op', () {
      final t = _task();
      expect(
          t.failActiveStage('x').stages,
          everyElement(isA<ErfStage>()
              .having((s) => s.status, 'status', ErfStageStatus.pending)));
    });
  });

  group('ErfTask progress', () {
    test('reports a fraction only when the total is known', () {
      expect(_task(done: 500).fraction, isNull);
      expect(_task(done: 500, total: 1000).fraction, 0.5);
    });

    test('clamps an overshoot rather than exceeding 100%', () {
      // The register can return slightly more than the pre-flight count.
      expect(_task(done: 1100, total: 1000).fraction, 1.0);
    });

    test('treats a zero total as unknown instead of dividing by zero', () {
      expect(_task(done: 0, total: 0).fraction, isNull);
    });

    test('estimates remaining time from the rate so far', () {
      // 40% done after 60s implies roughly 90s left.
      final t = _task(
        done: 400,
        total: 1000,
        startedAt: DateTime.now().subtract(const Duration(seconds: 60)),
      );

      final remaining = t.estimatedRemaining;
      expect(remaining, isNotNull);
      expect(remaining!.inSeconds, closeTo(90, 3));
    });

    test('withholds an estimate until there is enough signal', () {
      final justStarted = _task(
        done: 10,
        total: 10000,
        startedAt: DateTime.now().subtract(const Duration(seconds: 30)),
      );
      expect(justStarted.estimatedRemaining, isNull,
          reason: 'an ETA from 0.1% is noise');

      final finished = _task(
        done: 1000,
        total: 1000,
        startedAt: DateTime.now().subtract(const Duration(seconds: 30)),
      );
      expect(finished.estimatedRemaining, isNull);
    });
  });

  group('ErfTask.formatDuration', () {
    test('formats seconds, minutes and hours', () {
      expect(ErfTask.formatDuration(const Duration(seconds: 45)), '45s');
      expect(ErfTask.formatDuration(const Duration(seconds: 80)), '1m 20s');
      expect(ErfTask.formatDuration(const Duration(minutes: 65)), '1h 5m');
    });
  });
}
