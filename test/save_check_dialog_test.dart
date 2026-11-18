import 'package:clmschedule/utils/save_file_types.dart';
import 'package:clmschedule/utils/save_with_picker.dart';
import 'package:clmschedule/widgets/save_check_dialog.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _open(WidgetTester tester, {bool afterFailure = false}) async {
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () =>
            showSaveCheckDialog(context, afterFailure: afterFailure),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  tearDown(() => debugSavePicker = null);

  testWidgets('Windows: a full-screen Save dialog shows the fix steps',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    debugSavePicker = (_) async => const SavePick(
        SavePickStatus.closedByBrowser,
        error: chromeClosedCoveredReason);

    await _open(tester);
    expect(find.text('To fix it'), findsNothing,
        reason: 'no fix steps before the test has shown a problem');

    await tester.tap(find.text('Test the Save dialog'));
    await tester.pumpAndSettle();
    expect(find.textContaining('still opening full screen'), findsOneWidget);
    expect(find.text('To fix it'), findsOneWidget);
    expect(find.textContaining('Ctrl+S'), findsOneWidget);

    // After the fix: the dialog stays open and the user presses Cancel.
    debugSavePicker = (_) async => const SavePick(SavePickStatus.cancelled);
    await tester.tap(find.text('Test again'));
    await tester.pumpAndSettle();
    expect(find.textContaining('works on this computer'), findsOneWidget);
    expect(find.text('To fix it'), findsNothing);
    expect(find.text('Done'), findsOneWidget);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('from the toast the steps show straight away', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await _open(tester, afterFailure: true);
    expect(find.text('Fix the Save dialog on this computer'), findsOneWidget);
    expect(find.text('To fix it'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Close shuts only the dialog', (tester) async {
    await _open(tester);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byType(SaveCheckDialog), findsNothing);
    expect(find.text('open'), findsOneWidget);
  });

  test('the toast only offers "How to fix" when it can open the guide', () {
    // No app Navigator in a plain unit test → no dead button.
    const result = SaveResult(SaveOutcome.downloaded, 'x',
        isWarning: true, chromeClosedDialog: true);
    expect(result.snackBar!.action, isNull);
  });
}
