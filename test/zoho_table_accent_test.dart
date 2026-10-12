import 'package:clmschedule/widgets/zoho/zoho_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final width in [1200.0, 500.0]) {
    testWidgets('rows with a status accent do not overflow at $width px',
        (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        // Same as the invoices view: an opaque page colour over the
        // Scaffold's Material, which used to hide every row's fill.
        home: Scaffold(
          body: ColoredBox(
            color: ZohoPalette.pageBackground,
            child: ZohoTable(
              columns: const [
                ZohoColumn(label: 'Date', width: 110),
                ZohoColumn(label: 'Customer', width: 200, flexible: true),
                ZohoColumn(label: 'Amount', width: 120),
              ],
              rowCount: 3,
              rowAccent: (i) => [Colors.green, Colors.red, null][i],
              rowBuilder: (_, i) => [
                Text('d$i'),
                Text('c$i'),
                Text('a$i'),
              ],
            ),
          ),
        ),
      ));

      expect(tester.takeException(), isNull);
      expect(find.text('c2'), findsOneWidget);

      // The row's colour must be painted by a Material *inside* the page
      // background, not by the Scaffold's Material underneath it.
      Color rowColour(String text) => tester
          .widget<Material>(find
              .ancestor(of: find.text(text), matching: find.byType(Material))
              .first)
          .color!;
      expect(
          find.ancestor(of: find.text('c0'), matching: find.byType(ColoredBox)),
          findsWidgets);
      expect(
          rowColour('c0'),
          Color.alphaBlend(
              Colors.green.withValues(alpha: 0.12), ZohoPalette.surface));
      expect(
          rowColour('c1'),
          Color.alphaBlend(
              Colors.red.withValues(alpha: 0.12), ZohoPalette.surface));
      expect(rowColour('c2'), ZohoPalette.surface);
      // And that Material is below the ColoredBox, i.e. painted above it.
      final row0Material = find
          .ancestor(of: find.text('c0'), matching: find.byType(Material))
          .first;
      expect(find.ancestor(of: row0Material, matching: find.byType(ColoredBox)),
          findsWidgets);
    });
  }
}
