// The Staff screen (app bar → Staff): master/detail, everything editable in
// place. These pump the real widget over an in-memory Firestore and drive it
// the way a user does, so a layout overflow, a stale editor after switching
// person, or an edit that never reaches the save all fail here.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/providers/schedule_provider.dart';
import 'package:clmschedule/services/firestore_service.dart';
import 'package:clmschedule/widgets/app_toast.dart';
import 'package:clmschedule/widgets/distributor_management_dialog.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:flutter_test/flutter_test.dart';

Future<ScheduleProvider> _provider(FakeFirebaseFirestore db) async {
  for (final (i, name) in ['Barrie', 'Sipho', 'Thandi'].indexed) {
    await db.collection('distributors').doc(name.toLowerCase()).set(
          Distributor(
            id: name.toLowerCase(),
            name: name,
            index: i,
            phone1: '082000000$i',
          ).toMap(),
        );
  }
  final provider = ScheduleProvider(firestoreService: FirestoreService(firestore: db));
  await provider.initForTrackEditor();
  return provider;
}

Future<void> _pump(
  WidgetTester tester,
  ScheduleProvider provider, {
  Size size = const Size(1400, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    riverpod.ProviderScope(
      overrides: [scheduleRiverpod.overrideWith((ref) => provider)],
      child: MaterialApp(
        // The real app wraps every navigator in the toast host; without it
        // toasts fall back to a SnackBar and need a Scaffold.
        builder: AppToastHost.builder,
        home: const DistributorManagementDialog(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Lets a toast's entry animation finish without running out its countdown,
/// which `pumpAndSettle` would.
Future<void> _showToast(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  // One more frame so the editor's cross-fade can drop its outgoing child.
  await tester.pump(const Duration(milliseconds: 50));
}

/// The name field in the detail pane, told apart from the list rows.
Finder get _nameField => find.widgetWithText(TextField, 'Name on the schedule');

void main() {
  testWidgets('shows the roster and the first person\'s details side by side',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    expect(find.text('Staff'), findsOneWidget);
    expect(find.text('3 on the roster · 3 active'), findsOneWidget);

    // Every name is on the list without expanding anything.
    for (final name in ['Barrie', 'Sipho', 'Thandi']) {
      expect(find.text(name), findsWidgets);
    }

    // The first person is already open for editing — no extra click.
    expect(_nameField, findsOneWidget);
    expect(tester.widget<TextField>(_nameField).controller!.text, 'Barrie');
    expect(find.text('Position 1'), findsOneWidget);
    // Status and role are segmented pickers in the open, not inside a menu.
    expect(find.text('On Leave'), findsOneWidget);
    expect(find.text('Team Leader'), findsOneWidget);
    expect(find.text('On the schedule'), findsWidgets);
    // Nothing to save yet, so no save bar.
    expect(find.text('Save changes'), findsNothing);
  });

  testWidgets('one click switches person and the editor follows',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.tap(find.text('Thandi'));
    await tester.pumpAndSettle();

    expect(tester.widget<TextField>(_nameField).controller!.text, 'Thandi');
    expect(find.text('Position 3'), findsOneWidget);
  });

  testWidgets('typing a name updates the list row and arms the save bar',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.enterText(_nameField, 'Barrie B');
    await tester.pumpAndSettle();

    expect(find.text('Unsaved'), findsOneWidget);
    // The list row renamed itself as it was typed.
    expect(find.text('Barrie B'), findsWidgets);
    expect(find.widgetWithText(FilledButton, 'Save changes'), findsOneWidget);
  });

  testWidgets('status chips move somebody to the end of the roster',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    // Barrie (position 1) goes inactive and drops behind the active two.
    await tester.tap(find.text('Inactive'));
    await tester.pumpAndSettle();

    expect(find.text('Position 3'), findsOneWidget);
    expect(find.text('3 on the roster · 2 active'), findsOneWidget);
    // The roster now shows both blocks.
    expect(find.text('NOT ON THE SCHEDULE'), findsOneWidget);
  });

  testWidgets('adding a staff member saves them to Firestore',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.tap(find.text('Add staff'));
    await tester.pumpAndSettle();

    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('A name is required'), findsOneWidget);

    // A blank name is refused rather than written.
    await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
    await _showToast(tester);
    expect(find.text('Every staff member needs a name'), findsOneWidget);
    expect((await db.collection('distributors').get()).docs, hasLength(3));

    await tester.enterText(_nameField, 'Nomsa');
    await tester.enterText(
        find.widgetWithText(TextField, 'Phone 1 (primary)'), '0730000000');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
    await tester.pumpAndSettle();

    final written = (await db.collection('distributors').get())
        .docs
        .map((d) => d.data())
        .where((d) => d['name'] == 'Nomsa')
        .toList();
    expect(written, hasLength(1));
    expect(written.first['phone1'], '0730000000');
    expect(written.first['index'], 3);
  });

  testWidgets('remove takes effect at once and Undo brings them back',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.tap(find.text('Sipho'));
    await tester.pumpAndSettle();
    final remove = find.widgetWithText(TextButton, 'Remove from staff');
    await tester.ensureVisible(remove);
    await tester.pumpAndSettle();
    await tester.tap(remove);
    await _showToast(tester);

    expect(find.text('Sipho'), findsNothing);
    expect(find.text('Unsaved changes · 1 removed'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await _showToast(tester);

    expect(find.text('Sipho'), findsWidgets);
  });

  testWidgets('dragging a row renumbers the roster and saves the new order',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    // Thandi (3rd) is dragged by her handle up past the other two.
    final handle = find.byIcon(Icons.drag_indicator).last;
    final gesture = await tester.startGesture(tester.getCenter(handle));
    await tester.pump(const Duration(milliseconds: 200));
    for (var i = 0; i < 14; i++) {
      await gesture.moveBy(const Offset(0, -12));
      await tester.pump(const Duration(milliseconds: 16));
    }
    await gesture.up();
    await tester.pumpAndSettle();

    await tester.tap(find.text('Thandi'));
    await tester.pumpAndSettle();
    expect(find.text('Position 1'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
    await tester.pumpAndSettle();

    final stored = <String, int>{};
    for (final doc in (await db.collection('distributors').get()).docs) {
      stored[doc.data()['name'] as String] = doc.data()['index'] as int;
    }
    expect(stored, {'Thandi': 0, 'Barrie': 1, 'Sipho': 2});
  });

  testWidgets('the position stepper moves somebody without a drag',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.tap(find.text('Sipho'));
    await tester.pumpAndSettle();
    expect(find.text('Position 2'), findsOneWidget);

    await tester.tap(find.byTooltip('Move up'));
    await tester.pumpAndSettle();
    expect(find.text('Position 1'), findsOneWidget);

    // Already first — up is spent, down is still live.
    IconButton stepper(IconData icon) =>
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));
    expect(stepper(Icons.keyboard_arrow_up).onPressed, isNull);
    expect(stepper(Icons.keyboard_arrow_down).onPressed, isNotNull);
  });

  testWidgets('search narrows the list and parks reordering', (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.enterText(
        find.widgetWithText(TextField, 'Search name, phone, ID…'), 'thandi');
    await tester.pumpAndSettle();

    expect(find.text('Sipho'), findsNothing);
    expect(find.text('Thandi'), findsWidgets);
    expect(find.text('Clear the search or filter to drag-reorder'),
        findsOneWidget);
  });

  testWidgets('a phone number cleared in the editor is cleared on save',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.enterText(
        find.widgetWithText(TextField, 'Phone 1 (primary)'), '');
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save changes'));
    await tester.pumpAndSettle();

    final stored =
        (await db.collection('distributors').doc('barrie').get()).data();
    expect(stored!['phone1'], isNull);
  });

  testWidgets('Ctrl+S saves from anywhere on the screen', (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db));

    await tester.enterText(_nameField, 'Barrie B');
    await tester.pumpAndSettle();
    expect(find.text('Save changes'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.text('Save changes'), findsNothing);
    final stored =
        (await db.collection('distributors').doc('barrie').get()).data();
    expect(stored!['name'], 'Barrie B');
  });

  testWidgets('on a phone it is one pane with a way back', (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, await _provider(db), size: const Size(420, 820));

    // The list fills the screen; nothing is selected yet.
    expect(_nameField, findsNothing);
    expect(find.text('Barrie'), findsWidgets);

    await tester.tap(find.text('Barrie'));
    await tester.pumpAndSettle();
    expect(_nameField, findsOneWidget);

    await tester.tap(find.byTooltip('Back to the list'));
    await tester.pumpAndSettle();
    expect(_nameField, findsNothing);
  });
}
