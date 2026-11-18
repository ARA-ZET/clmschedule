// After a folder scan the Report panel lists shifts by DATE, oldest first,
// each date with its own "Add photos" button and every distributor's shift
// beneath it.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/providers/te_report_provider.dart';
import 'package:clmschedule/track_editor/widgets/te_report_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TEPromoterDay _day(String id, String name, DateTime date) => TEPromoterDay(
      distributor: Distributor(id: id, name: name, index: 0),
      date: date,
      tracks: const [],
      waypoints: const [],
      sourcePaths: const [],
    );

void main() {
  testWidgets(
      'shifts are grouped by date, oldest first, one photo button '
      'per date', (tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final container = ProviderContainer();
    addTearDown(container.dispose);
    // Scan order deliberately out of date order and by name.
    container.read(teReportRiverpod).seedDaysForTest([
      _day('d1', 'Zola', DateTime(2026, 9, 12)),
      _day('d2', 'Amahle', DateTime(2026, 9, 11)),
      _day('d1', 'Zola', DateTime(2026, 9, 11)),
    ]);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: TEReportPanel())),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Dates in order, as their own headings.
    final fri = tester.getTopLeft(find.text('Fri 11 Sep 2026').first).dy;
    final sat = tester.getTopLeft(find.text('Sat 12 Sep 2026').first).dy;
    expect(fri, lessThan(sat));

    // Both distributors sit under the 11th, A–Z, above the 12th.
    final amahle = tester.getTopLeft(find.text('Amahle')).dy;
    final zolas = find.text('Zola');
    expect(zolas, findsNWidgets(2));
    final zolaFirst = tester.getTopLeft(zolas.at(0)).dy;
    expect(fri, lessThan(amahle));
    expect(amahle, lessThan(zolaFirst));
    expect(zolaFirst, lessThan(sat));

    expect(find.widgetWithText(TextButton, 'Add photos'), findsNWidgets(2));

    // Unticking a date unticks every shift on it and nothing else.
    await tester.tap(find.byType(Checkbox).first);
    await tester.pump();
    final report = container.read(teReportRiverpod);
    expect(report.selectedDays, hasLength(1));
    expect(report.selectedDays.single.date, DateTime(2026, 9, 12));
  });
}
