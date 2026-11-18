// The Job List's flyer handout report: its email template, the dates it
// names, and the choices its draft keeps.
import 'package:clmschedule/models/distribution_report_draft.dart';
import 'package:clmschedule/models/distribution_report_template.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const template = DistributionReportTemplate.flyerHandouts;

  test('is a built-in, and the only one that builds a PDF', () {
    expect(DistributionReportTemplate.builtIns, contains(template));
    expect(DistributionReportTemplate.alwaysOffered, contains(template));
    expect(template.usesFlyerHandouts, isTrue);
    expect(template.usesFlyersAndPosters, isFalse);
    expect(DistributionReportTemplate.fallback.usesFlyerHandouts, isFalse);
    expect(DistributionReportTemplate.flyersAndPosters.usesFlyerHandouts,
        isFalse);
  });

  test('renders in the words asked for, invoice line and all', () {
    final text = template.render(const DistributionReportValues(
      greetingName: 'Thabo',
      handoutDates: '22 October 2026',
      includeInvoiceLine: true,
    ));
    expect(
        text,
        'Hi Thabo,\n\n'
        'Please find attached the report on the handing out of your flyers '
        'on 22 October 2026.\n\n'
        'Let me know if you have any questions.\n\n'
        'Your invoice is attached.\n\n'
        'Thank you!');
  });

  test('a paid invoice drops its line without leaving a gap', () {
    final text = template.render(const DistributionReportValues(
      greetingName: 'Thabo',
      handoutDates: '22 October 2026',
    ));
    expect(text, isNot(contains('invoice')));
    expect(text, contains('any questions.\n\nThank you!'));
    expect(template.renderBlocks(const DistributionReportValues()).length, 4);
  });

  test('dates are named once per month and year', () {
    String list(List<DateTime> d) => DistributionReportFormat.dateList(d);
    expect(list([DateTime(2026, 10, 22)]), '22 October 2026');
    expect(list([DateTime(2026, 10, 22, 15), DateTime(2026, 10, 22, 9)]),
        '22 October 2026');
    expect(list([DateTime(2026, 10, 22), DateTime(2026, 10, 20)]),
        '20 and 22 October 2026');
    expect(
        list([
          DateTime(2026, 10, 20),
          DateTime(2026, 10, 21),
          DateTime(2026, 10, 22)
        ]),
        '20, 21 and 22 October 2026');
    expect(list([DateTime(2026, 9, 30), DateTime(2026, 10, 1)]),
        '30 September and 1 October 2026');
    expect(list([DateTime(2026, 12, 30), DateTime(2027, 1, 2)]),
        '30 December 2026 and 2 January 2027');
    expect(list([]), '');
  });

  test('the draft keeps the handout choices, encoded the same every time', () {
    const draft = DistributionReportDraft(
      jobId: 'j1',
      handoutUnselectedDays: ['d2|2026-10-22', 'd1|2026-10-22'],
      handoutWhere: {'d2|2026-10-22': 'Main Rd', 'd1|2026-10-22': 'Kloof St'},
      handoutLinks: {'d1|2026-10-22': 'https://example.com/map/ABC'},
      handoutChosenPhotos: ['job/b.jpg', 'job/a.jpg'],
      handoutPhotoDates: {'job/x.jpg': '2026-10-22'},
    );
    final map = draft.toContentMap();
    expect(map['handoutUnselectedDays'], ['d1|2026-10-22', 'd2|2026-10-22']);
    expect((map['handoutWhere'] as Map).keys.first, 'd1|2026-10-22');

    final back = DistributionReportDraft.fromMap('j1', map);
    expect(back.handoutUnselectedDays.toSet(), draft.handoutUnselectedDays.toSet());
    expect(back.handoutWhere, draft.handoutWhere);
    expect(back.handoutLinks, draft.handoutLinks);
    expect(back.handoutChosenPhotos.toSet(), draft.handoutChosenPhotos.toSet());
    expect(back.handoutPhotoDates, draft.handoutPhotoDates);
  });
}
