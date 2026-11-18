// The "Check where worked" step before the report PDF: a shift whose
// location didn't come back is flagged, typing over it is kept in the
// report provider, and undo goes back to the looked-up names.
import 'package:clmschedule/models/distributor.dart';
import 'package:clmschedule/track_editor/models/te_promoter_day.dart';
import 'package:clmschedule/track_editor/providers/te_report_provider.dart';
import 'package:clmschedule/track_editor/services/te_place_names.dart';
import 'package:clmschedule/track_editor/services/te_report_map_links.dart';
import 'package:clmschedule/track_editor/widgets/te_where_worked_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

TEPromoterDay _day(String id, String name) => TEPromoterDay(
      distributor: Distributor(id: id, name: name, index: 0),
      date: DateTime(2026, 5, 11),
      tracks: const [],
      waypoints: const [],
      sourcePaths: const [],
    );

void main() {
  testWidgets('flags a missing location, keeps typed text, undo restores',
      (tester) async {
    final report = TEReportProvider();
    final days = [_day('d1', 'Nolan'), _day('d2', 'Thandiwe')];
    report.seedDaysForTest(days);
    Map<String, TEPlaceName>? result;

    await tester.pumpWidget(ProviderScope(
      overrides: [teReportRiverpod.overrideWith((ref) => report)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showWhereWorkedDialog(context,
                    days: days, places: const {});
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Check the report'), findsOneWidget);
    expect(find.textContaining('2 of 2 shifts have no intersection'),
        findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'Main Rd & Church St');
    await tester.pump();
    expect(report.whereOverrideFor(days[0]), 'Main Rd & Church St');
    expect(find.textContaining('1 of 2 shifts have no intersection'),
        findsOneWidget);
    expect(find.text('Typed by hand'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.undo));
    await tester.pump();
    expect(report.whereOverrideFor(days[0]), isNull);

    // No handout points means nothing for Retry to ask about.
    expect(find.text('Nothing to retry'), findsOneWidget);

    await tester.enterText(find.byType(TextField).last, 'Durban Rd');
    await tester.tap(find.text('Build PDF'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(report.whereOverrides, {days[1].key: 'Durban Rd'});
  });

  testWidgets('the client map link found can be replaced by hand',
      (tester) async {
    final report = TEReportProvider();
    final days = [_day('d1', 'Nolan'), _day('d2', 'Thandiwe')];
    report.seedDaysForTest(days);
    const found = 'https://maps.communitylifemedia.co.za/map/abc123';

    await tester.pumpWidget(ProviderScope(
      overrides: [teReportRiverpod.overrideWith((ref) => report)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showWhereWorkedDialog(context,
                  days: days,
                  places: const {},
                  linkGroups: [
                    TEMapLinkGroup(
                        key: 'job1', label: 'Jo Lombard', days: days, url: found),
                  ]),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Client map link'), findsOneWidget);
    expect(find.text(found), findsOneWidget);

    await tester.enterText(find.text(found), 'not a link');
    await tester.pump();
    expect(find.textContaining('starting with https://'), findsOneWidget);

    const pasted = 'https://maps.communitylifemedia.co.za/map/xyz789';
    await tester.enterText(find.byType(TextField).first, pasted);
    await tester.pump();
    expect(report.mapLinkOverrideFor(days[0]), pasted);
    expect(report.mapLinkOverrideFor(days[1]), pasted);

    // Typing the found link back in is the same as not editing.
    await tester.enterText(find.byType(TextField).first, found);
    await tester.pump();
    expect(report.mapLinkOverrideFor(days[0]), isNull);
  });
}
