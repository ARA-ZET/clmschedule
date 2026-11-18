import 'package:clmschedule/widgets/slow_action_hint.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('SlowActionHint', () {
    testWidgets('quick saves show nothing', (tester) async {
      await tester.pumpWidget(
          _host(const SlowActionHint(busy: true, action: 'Saving')));
      await tester.pump(const Duration(seconds: 2));
      expect(find.textContaining('slow'), findsNothing);

      await tester.pumpWidget(
          _host(const SlowActionHint(busy: false, action: 'Saving')));
      await tester.pump(const Duration(seconds: 10));
      expect(find.textContaining('slow'), findsNothing);
    });

    testWidgets('a slow save says so, then escalates', (tester) async {
      await tester.pumpWidget(_host(const SlowActionHint(
          busy: true, action: 'Creating the invoice in Zoho')));
      await tester.pump(const Duration(seconds: 5));
      expect(find.textContaining("don't press again"), findsOneWidget);
      expect(find.textContaining('very slow'), findsNothing);

      await tester.pump(const Duration(seconds: 11));
      expect(find.textContaining('very slow'), findsOneWidget);

      // Done: the hint goes away.
      await tester.pumpWidget(_host(const SlowActionHint(
          busy: false, action: 'Creating the invoice in Zoho')));
      await tester.pump();
      expect(find.textContaining('slow'), findsNothing);
    });

    testWidgets('restarts its clock for the next save', (tester) async {
      await tester.pumpWidget(_host(const SlowActionHint(busy: true)));
      await tester.pump(const Duration(seconds: 20));
      await tester.pumpWidget(_host(const SlowActionHint(busy: false)));
      await tester.pump();
      await tester.pumpWidget(_host(const SlowActionHint(busy: true)));
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('slow'), findsNothing);
    });
  });

  group('PendingSavesChip', () {
    testWidgets('hidden for quick saves, shown when slow, gone when saved',
        (tester) async {
      final pending = ValueNotifier<int>(0);
      await tester.pumpWidget(_host(PendingSavesChip(pending: pending)));
      expect(find.textContaining('Saving'), findsNothing);

      pending.value = 2;
      await tester.pump(const Duration(seconds: 1));
      expect(find.textContaining('Saving'), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      expect(find.text('Saving 2 changes…'), findsOneWidget);

      await tester.pump(const Duration(seconds: 12));
      expect(find.text('Slow connection · Saving 2 changes…'), findsOneWidget);

      pending.value = 0;
      await tester.pump();
      expect(find.textContaining('Saving'), findsNothing);
      pending.dispose();
    });
  });
}
