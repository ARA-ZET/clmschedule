import 'package:clmschedule/services/sync_status.dart';
import 'package:clmschedule/widgets/sync_status_banner.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [1280.0, 360.0]) {
    testWidgets('slow-loading banner reads clearly at ${width.toInt()} px wide',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final status = SyncStatus.forTest();
      await tester.pumpWidget(MaterialApp(
        home: SyncStatusBanner(
            status: status, child: const Scaffold(body: Text('page'))),
      ));
      // Nothing is shown for a normal short wait.
      expect(find.textContaining('Slow connection'), findsNothing);

      // It has never reached a server, so after the threshold it reports a
      // slow first load.
      await tester.pump(SyncStatus.slowAfter + const Duration(seconds: 1));
      expect(status.problem, SyncProblem.slowConnection);
      expect(find.text('Slow connection — still loading the latest data'),
          findsOneWidget);
      expect(find.textContaining("Don't mark payments"), findsOneWidget);
      expect(find.text('Waiting for the server to answer…'), findsOneWidget);
      expect(find.text('Check now'), findsOneWidget);
      expect(find.text('page'), findsOneWidget);

      // The status line ticks without errors.
      await tester.pump(const Duration(seconds: 2));
      expect(tester.takeException(), isNull);

      // Recovers: green "back online", then nothing.
      status.debugSetFromCache(false);
      await tester.pump(SyncStatus.clearAfter + const Duration(seconds: 1));
      expect(find.text('Back online — everything is up to date.'),
          findsOneWidget);
      await tester.pump(const Duration(seconds: 10));
      expect(find.textContaining('Slow connection'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
