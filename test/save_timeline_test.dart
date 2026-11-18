// The step-by-step timing printed to the console when a job is added.
import 'dart:async';

import 'package:clmschedule/utils/save_timeline.dart';
import 'package:flutter_test/flutter_test.dart';

/// A clock the test moves by hand.
class _Clock {
  Duration now = Duration.zero;
  void advance(int ms) => now += Duration(milliseconds: ms);
}

void main() {
  test('times steps in order and prints once everything has settled',
      () async {
    final clock = _Clock();
    final printed = <String>[];
    final tl = SaveTimeline('Add job "Timbuild"',
        elapsed: () => clock.now, printer: printed.add);

    await tl.step('duplicate-name check', () async => clock.advance(120));
    await tl.userStep('allocation preview', () async => clock.advance(9000));

    final scheduleWrite = Completer<void>();
    final jobListWrite = Completer<void>();
    tl.background('save 8 schedule jobs (1 transaction)', scheduleWrite.future);
    tl.background('Job List job saved on the server', jobListWrite.future);
    clock.advance(30);
    tl.markClosed();

    // The dialog is closed but two saves are still running: nothing yet.
    expect(printed, isEmpty);

    clock.advance(1500);
    jobListWrite.complete();
    await pumpEventQueue();
    expect(printed, isEmpty);

    clock.advance(1000);
    scheduleWrite.complete();
    await pumpEventQueue();

    expect(printed, hasLength(1));
    final report = printed.single;
    // Waited = until the dialog closed, less the 9 s spent in the preview.
    expect(tl.userWaited, const Duration(milliseconds: 150));
    expect(tl.allDone, const Duration(milliseconds: 11650));
    expect(report, contains('you waited 0.15 s'));
    expect(report, contains('everything saved 11.7 s'));
    expect(report, contains('allocation preview  (you)'));
    expect(report, contains('save 8 schedule jobs (1 transaction)  background'));
    expect(SaveTimeline.lastReport, report);

    final lines = report.split('\n');
    expect(lines[2], contains('duplicate-name check'));
    expect(lines[3], contains('allocation preview'));
    expect(lines[6], contains('dialog closed'));
  });

  test('a failed background step is marked, never thrown', () async {
    final clock = _Clock();
    final printed = <String>[];
    final tl = SaveTimeline('Add job', elapsed: () => clock.now,
        printer: printed.add);

    final write = Completer<void>();
    tl.background('Job List job saved on the server', write.future);
    tl.markClosed();
    write.completeError(StateError('permission-denied'));
    await pumpEventQueue();

    expect(printed.single, contains('1 failed'));
    expect(printed.single, contains('FAILED: Bad state: permission-denied'));
  });

  test('a step that fails is recorded and its error reaches the caller',
      () async {
    final tl = SaveTimeline('Add job', printer: (_) {});
    await expectLater(
        tl.step('duplicate-name check', () async => throw StateError('x')),
        throwsStateError);
    expect(tl.entries.single.error, 'Bad state: x');
  });

  testWidgets('a save that never settles is still reported, as running',
      (tester) async {
    final printed = <String>[];
    final tl = SaveTimeline('Add job',
        printer: printed.add, giveUpAfter: const Duration(seconds: 30));
    tl.background('stuck', Completer<void>().future);
    tl.markClosed();
    await tester.pump(const Duration(seconds: 31));
    expect(printed.single, contains('still saving'));
    expect(printed.single, contains('running'));
  });
}
