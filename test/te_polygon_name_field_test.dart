import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/track_editor/widgets/te_polygon_name_field.dart';

// Naming a drawn polygon used to be a dropdown of the areas already allocated
// to the distributor, so an area the schedule didn't know about yet could not
// be named at all. The field must now take a typed name, while keeping the
// allocated names one tap away.
Future<TextEditingController> pumpField(
  WidgetTester tester, {
  required List<String> suggestions,
  String initial = '',
}) async {
  final controller = TextEditingController(text: initial);
  addTearDown(controller.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: TEPolygonNameField(
          controller: controller,
          suggestions: suggestions,
          onChanged: () {},
        ),
      ),
    ),
  ));
  return controller;
}

void main() {
  testWidgets('a name can be typed even when suggestions exist',
      (tester) async {
    final controller =
        await pumpField(tester, suggestions: ['Idas Valley', 'Cloetesville']);

    await tester.enterText(find.byType(TextField), 'New infill block');

    expect(controller.text, 'New infill block');
  });

  testWidgets('tapping a suggestion fills the field', (tester) async {
    final controller =
        await pumpField(tester, suggestions: ['Idas Valley', 'Cloetesville']);

    await tester.tap(find.text('Cloetesville'));
    await tester.pump();

    expect(controller.text, 'Cloetesville');
    // The chip shows as chosen, so it is clear which name will be saved.
    final chip = tester.widget<ChoiceChip>(
      find.ancestor(
          of: find.text('Cloetesville'), matching: find.byType(ChoiceChip)),
    );
    expect(chip.selected, isTrue);
  });

  testWidgets('un-picking a suggestion clears the field for a typed name',
      (tester) async {
    final controller = await pumpField(tester,
        suggestions: ['Idas Valley'], initial: 'Idas Valley');

    await tester.tap(find.byType(ChoiceChip));
    await tester.pump();

    expect(controller.text, '');
  });

  testWidgets('a pre-filled single suggestion is still editable',
      (tester) async {
    final controller = await pumpField(tester,
        suggestions: ['Idas Valley'], initial: 'Idas Valley');

    await tester.enterText(find.byType(TextField), 'Idas Valley Ext 3');

    expect(controller.text, 'Idas Valley Ext 3');
  });

  testWidgets('the clear button empties a pre-filled name', (tester) async {
    final controller = await pumpField(tester,
        suggestions: ['Idas Valley'], initial: 'Idas Valley');

    await tester.tap(find.byTooltip('Clear name'));
    await tester.pump();

    expect(controller.text, '');
    // Nothing to clear now, so the button goes away.
    expect(find.byTooltip('Clear name'), findsNothing);
  });

  testWidgets('with no suggestions it is a plain name field', (tester) async {
    await pumpField(tester, suggestions: []);

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('Suggested names'), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
  });

  testWidgets('a long work-area list goes behind a menu, not chips',
      (tester) async {
    final many = [for (var i = 0; i < 40; i++) 'Area $i'];
    final controller = await pumpField(tester, suggestions: many);

    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.text('Pick from 40 work areas'), findsOneWidget);

    await tester.tap(find.text('Pick from 40 work areas'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Area 3').last);
    await tester.pumpAndSettle();

    expect(controller.text, 'Area 3');
  });
}
