import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late BuildContext ctx;

  // Lets the entry/exit animations finish without running out the toasts'
  // countdowns, which pumpAndSettle would.
  Future<void> showIn(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  Widget app({bool withHost = true}) => ProviderScope(
        child: MaterialApp(
          builder: withHost ? AppToastHost.builder : null,
          home: Scaffold(
            body: Builder(builder: (c) {
              ctx = c;
              return const SizedBox.expand();
            }),
          ),
        ),
      );

  void toast(String text, {SnackBarAction? action, Duration? duration}) {
    ScaffoldMessenger.of(ctx).showToast(SnackBar(
      content: Text(text),
      action: action,
      duration: duration ?? const Duration(milliseconds: 4000),
    ));
  }

  testWidgets('a toast with an action still times out', (tester) async {
    await tester.pumpWidget(app());
    toast('Moved', action: SnackBarAction(label: 'Undo', onPressed: () {}));
    await showIn(tester);
    expect(find.text('Moved'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);

    await tester.pump(const Duration(seconds: 7));
    await tester.pumpAndSettle();
    expect(find.text('Moved'), findsNothing);
  });

  testWidgets('toasts show together instead of queueing', (tester) async {
    await tester.pumpWidget(app());
    toast('One');
    toast('Two');
    toast('Three');
    await showIn(tester);
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    expect(find.text('Three'), findsOneWidget);

    // A fourth pushes the oldest out.
    toast('Four');
    await showIn(tester);
    expect(find.text('One'), findsNothing);
    expect(find.text('Four'), findsOneWidget);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    expect(find.text('Four'), findsNothing);
  });

  testWidgets('an over-long duration is capped', (tester) async {
    await tester.pumpWidget(app());
    toast('Looking up…', duration: const Duration(seconds: 30));
    await showIn(tester);
    await tester.pump(const Duration(seconds: 11));
    await tester.pumpAndSettle();
    expect(find.text('Looking up…'), findsNothing);
  });

  testWidgets('a repeated message replaces the visible copy', (tester) async {
    await tester.pumpWidget(app());
    toast('Saved');
    toast('Saved');
    await showIn(tester);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('close button and hideCurrentToast dismiss', (tester) async {
    await tester.pumpWidget(app());
    toast('A');
    toast('B');
    await showIn(tester);
    ScaffoldMessenger.of(ctx).hideCurrentToast();
    await showIn(tester);
    expect(find.text('B'), findsNothing);
    expect(find.text('A'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await showIn(tester);
    expect(find.text('A'), findsNothing);
  });

  testWidgets('tapping the action runs it and closes the toast',
      (tester) async {
    var undone = false;
    await tester.pumpWidget(app());
    toast('Moved',
        action: SnackBarAction(label: 'Undo', onPressed: () => undone = true));
    await showIn(tester);
    await tester.tap(find.text('Undo'));
    await showIn(tester);
    expect(undone, isTrue);
    expect(find.text('Moved'), findsNothing);
  });

  Color cardColor(WidgetTester tester, String text) => tester
      .widget<Material>(find
          .ancestor(of: find.text(text), matching: find.byType(Material))
          .first)
      .color!;

  testWidgets('warnings are red and successes green, with a badge',
      (tester) async {
    await tester.pumpWidget(app());
    final m = ScaffoldMessenger.of(ctx);
    m.showToast(const SnackBar(
        content: Text('Partly done'), backgroundColor: Colors.orange));
    m.showToast(
        const SnackBar(content: Text('Saved'), backgroundColor: Colors.green));
    m.showToast(const SnackBar(content: Text('Error: offline')));
    await showIn(tester);

    expect(cardColor(tester, 'Partly done'), Colors.red.shade700);
    expect(cardColor(tester, 'Error: offline'), Colors.red.shade700);
    expect(cardColor(tester, 'Saved'), Colors.green.shade700);
    expect(find.byIcon(Icons.priority_high_rounded), findsNWidgets(2));
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });

  testWidgets('plain and info toasts stay neutral, no badge', (tester) async {
    await tester.pumpWidget(app());
    final m = ScaffoldMessenger.of(ctx);
    m.showToast(const SnackBar(content: Text('Copied link')));
    m.showToast(
        const SnackBar(content: Text('Syncing'), backgroundColor: Colors.blue));
    await showIn(tester);

    expect(cardColor(tester, 'Syncing'), Colors.blue);
    expect(find.byIcon(Icons.priority_high_rounded), findsNothing);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
  });

  testWidgets('falls back to a snackbar without a host', (tester) async {
    await tester.pumpWidget(app(withHost: false));
    toast('Plain');
    await showIn(tester);
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
