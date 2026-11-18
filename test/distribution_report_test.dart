import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/distribution_report.dart';
import 'package:clmschedule/models/distribution_report_draft.dart';
import 'package:clmschedule/models/distribution_report_template.dart';
import 'package:clmschedule/services/compiled_tracks_parser.dart';
import 'package:clmschedule/services/distribution_report_service.dart';
import 'package:clmschedule/shareable_maps/models/map_layer.dart';
import 'package:clmschedule/utils/gmail_compose.dart';
import 'package:clmschedule/utils/schedule_time.dart';

/// Guards the distribution report.
///
/// The report is the last thing a client sees about a job, and two of its
/// four facts — the date and the quantity — are derived rather than entered.
/// A wrong figure here is not a broken screen; it is a wrong statement made
/// to a customer in writing. Everything below is about those derivations.

Uint8List _bytes(Object json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

/// Milliseconds for a given SAST wall-clock moment.
int _sastMillis(int y, int m, int d, [int hour = 0, int minute = 0]) =>
    scheduleCivilToInstant(DateTime(y, m, d, hour, minute))
        .millisecondsSinceEpoch;

MapLayer _layer({
  required String id,
  required String name,
  List<String> polygonNames = const [],
}) {
  final now = DateTime(2026, 8, 1);
  return MapLayer(
    id: id,
    name: name,
    order: 0,
    defaultColor: Colors.blue,
    createdAt: now,
    updatedAt: now,
    polygons: polygonNames
        .map((n) => CustomPolygon(
              name: n,
              description: '',
              points: const [LatLng(-33.9, 18.4), LatLng(-33.8, 18.5)],
              color: Colors.blue,
            ))
        .toList(),
  );
}

DistributionReportFolder _folder({
  String path = 'Distribution/2026/Aug 2026/Seeff/Round 1',
  int waypointCount = 0,
  DateTime? earliestStart,
  DateTime? compiledAt,
  DistributionDateSource dateSource = DistributionDateSource.trackTimes,
  String? error,
}) {
  return DistributionReportFolder(
    path: path,
    waypointCount: waypointCount,
    earliestStart: earliestStart,
    compiledAt: compiledAt,
    dateSource: dateSource,
    error: error,
  );
}

DistributionReport _report({
  List<DistributionReportFolder> folders = const [],
  DateTime? jobDate,
}) {
  return DistributionReport(
    jobId: 'job-1',
    client: 'Seeff',
    jobDate: jobDate ?? DateTime(2026, 8, 20),
    folders: folders,
  );
}

void main() {
  group('parseCompiledTracksSummary', () {
    test('reads the header count and the earliest track start', () {
      final bytes = _bytes({
        'version': 1,
        'compiledAt': '2026-08-15T09:00:00.000Z',
        'fileCount': 3,
        'trackCount': 2,
        'waypointCount': 12500,
        'tracks': [
          {
            'startTime': _sastMillis(2026, 8, 14, 9),
            'endTime': _sastMillis(2026, 8, 14, 15)
          },
          {
            'startTime': _sastMillis(2026, 8, 12, 8),
            'endTime': _sastMillis(2026, 8, 12, 16)
          },
        ],
      });

      final summary = parseCompiledTracksSummary(bytes);

      expect(summary.waypointCount, 12500);
      expect(summary.trackCount, 2);
      expect(summary.fileCount, 3);
      expect(toScheduleCivil(summary.earliestStart!).day, 12);
      expect(toScheduleCivil(summary.latestEnd!).day, 14);
    });

    test('the waypoint count comes from the tracks file, not the huge one', () {
      // The whole reason the report reads _compiled_tracks.json: it carries
      // the letterbox total as well, so the multi-MB waypoints file is never
      // downloaded on the happy path.
      final bytes = _bytes({'waypointCount': 843, 'tracks': []});
      expect(parseCompiledTracksSummary(bytes).waypointCount, 843);
    });

    test('tracks with no timestamps yield no date rather than a wrong one', () {
      final bytes = _bytes({
        'waypointCount': 100,
        'tracks': [
          {'name': 'Route 1'},
          {'name': 'Route 2'},
        ],
      });

      final summary = parseCompiledTracksSummary(bytes);
      expect(summary.earliestStart, isNull);
      expect(summary.waypointCount, 100);
    });

    test('falls back to the array length when the header count is absent', () {
      final bytes = _bytes({
        'tracks': [
          {'startTime': _sastMillis(2026, 8, 12)},
        ],
      });
      expect(parseCompiledTracksSummary(bytes).trackCount, 1);
    });
  });

  group('parseCompiledWaypointCount', () {
    test('prefers the header count', () {
      expect(
        parseCompiledWaypointCount(_bytes({
          'waypointCount': 42,
          'waypoints': [1, 2, 3],
        })),
        42,
      );
    });

    test('falls back to the array length', () {
      expect(
        parseCompiledWaypointCount(_bytes({
          'waypoints': [1, 2, 3],
        })),
        3,
      );
    });
  });

  group('parseGpxFileNameDate', () {
    test('reads the date out of a real track filename', () {
      final date = parseGpxFileNameDate(
        'Track   09 Mar 2026   Nolan   Seeff   1204 fulltrack.gpx',
      );
      final civil = toScheduleCivil(date!);
      expect(civil.year, 2026);
      expect(civil.month, 3);
      expect(civil.day, 9);
    });

    test('survives the round trip to a SAST calendar day', () {
      // The filename records a calendar day, not an instant. It must come back
      // as the same day, not the one before it.
      final date = parseGpxFileNameDate('Track   01 Jan 2026   X   Y   1.gpx');
      expect(toScheduleCivil(date!).day, 1);
      expect(toScheduleCivil(date).month, 1);
    });

    test('returns null for a name with no date', () {
      expect(parseGpxFileNameDate('_compiled_tracks.json'), isNull);
      expect(parseGpxFileNameDate('Track Seeff fulltrack.gpx'), isNull);
    });
  });

  group('parseReportAddresses', () {
    test('splits on commas, semicolons and newlines', () {
      expect(
        parseReportAddresses('a@x.com, b@x.com; c@x.com\nd@x.com'),
        ['a@x.com', 'b@x.com', 'c@x.com', 'd@x.com'],
      );
    });

    test('drops prose and de-duplicates', () {
      expect(
        parseReportAddresses('Nicola, nicola@x.com, nicola@x.com'),
        ['nicola@x.com'],
      );
    });

    test('an empty column is not an error', () {
      expect(parseReportAddresses(''), isEmpty);
    });
  });

  group('isSystemMapLayer', () {
    test('keeps client-visible work area layers', () {
      expect(isSystemMapLayer(_layer(id: 'l1', name: 'Target Areas')), isFalse);
      expect(isSystemMapLayer(_layer(id: 'l2', name: 'Suburbs')), isFalse);
    });

    test('drops the injected gap-areas overlay', () {
      expect(
        isSystemMapLayer(
            _layer(id: 'unfinished_work_areas_layer', name: 'Unfinished')),
        isTrue,
      );
    });

    test('drops cloud overlay layers by id and by generated name', () {
      expect(
          isSystemMapLayer(_layer(id: 'cloud_tracks_ab12', name: 'x')), isTrue);
      expect(
        isSystemMapLayer(
            _layer(id: 'l3', name: 'Movements of the Distributors')),
        isTrue,
      );
      // Month-prefixed, which is what the editor actually generates.
      expect(isSystemMapLayer(_layer(id: 'l4', name: 'Apr 2025 Movements')),
          isTrue);
      expect(
        isSystemMapLayer(_layer(id: 'l5', name: 'Aug 2026 Letter Boxes')),
        isTrue,
      );
    });
  });

  group('DistributionReport.totalsFor', () {
    test('sums the selected folders and takes the earliest date', () {
      final report = _report(folders: [
        _folder(
          path: 'a',
          waypointCount: 1000,
          earliestStart: scheduleCivilToInstant(DateTime(2026, 8, 14)),
        ),
        _folder(
          path: 'b',
          waypointCount: 500,
          earliestStart: scheduleCivilToInstant(DateTime(2026, 8, 12)),
        ),
      ]);

      final totals = report.totalsFor({'a', 'b'});
      expect(totals.quantityDistributed, 1500);
      expect(totals.startDate!.day, 12);
      expect(totals.dateSource, DistributionDateSource.trackTimes);
    });

    test('an unticked folder contributes neither count nor date', () {
      final report = _report(folders: [
        _folder(
          path: 'a',
          waypointCount: 1000,
          earliestStart: scheduleCivilToInstant(DateTime(2026, 8, 14)),
        ),
        // A leftover round from an earlier job on a reused map.
        _folder(
          path: 'old',
          waypointCount: 9999,
          earliestStart: scheduleCivilToInstant(DateTime(2026, 3, 1)),
        ),
      ]);

      final totals = report.totalsFor({'a'});
      expect(totals.quantityDistributed, 1000);
      expect(totals.startDate!.month, 8);
    });

    test('a folder that failed to read is skipped even when selected', () {
      final report = _report(folders: [
        _folder(
            path: 'a',
            waypointCount: 1000,
            earliestStart: scheduleCivilToInstant(DateTime(2026, 8, 14))),
        _folder(path: 'bad', waypointCount: 500, error: 'not compiled'),
      ]);

      expect(report.totalsFor({'a', 'bad'}).quantityDistributed, 1000);
    });

    test('reports the source of the folder that supplied the date', () {
      final report = _report(folders: [
        _folder(
          path: 'a',
          earliestStart: scheduleCivilToInstant(DateTime(2026, 8, 14)),
          dateSource: DistributionDateSource.trackTimes,
        ),
        _folder(
          path: 'b',
          compiledAt: scheduleCivilToInstant(DateTime(2026, 8, 12)),
          dateSource: DistributionDateSource.compiledAt,
        ),
      ]);

      // The earliest date came from the inferred folder, so that is what is
      // reported — flagging the date actually shown, not the best available.
      final totals = report.totalsFor({'a', 'b'});
      expect(totals.startDate!.day, 12);
      expect(totals.dateSource, DistributionDateSource.compiledAt);
      expect(totals.dateSource.isMeasured, isFalse);
    });

    test('falls back to the job date when nothing carries one', () {
      final report = _report(
        folders: [_folder(path: 'a', waypointCount: 10)],
        jobDate: DateTime(2026, 8, 20),
      );

      final totals = report.totalsFor({'a'});
      expect(totals.startDate, DateTime(2026, 8, 20));
      expect(totals.dateSource, DistributionDateSource.jobDate);
    });

    test('a UTC-morning track resolves to the SAST calendar day', () {
      // 22:30 UTC on the 11th is 00:30 SAST on the 12th. Reading it in the
      // browser's own zone would put a client-facing report on the wrong day.
      final instant = DateTime.utc(2026, 8, 11, 22, 30);
      final report = _report(folders: [
        _folder(path: 'a', waypointCount: 1, earliestStart: instant),
      ]);

      expect(report.totalsFor({'a'}).startDate!.day, 12);
    });
  });

  group('DistributionReportFormat.areaList', () {
    test('reads as prose, not as a list', () {
      expect(DistributionReportFormat.areaList([]), '');
      expect(DistributionReportFormat.areaList(['Claremont']), 'Claremont');
      expect(
        DistributionReportFormat.areaList(['Claremont', 'Newlands']),
        'Claremont and Newlands',
      );
      expect(
        DistributionReportFormat.areaList(
            ['Claremont', 'Newlands', 'Rondebosch']),
        'Claremont, Newlands and Rondebosch',
      );
    });
  });

  group('template rendering', () {
    const values = DistributionReportValues(
      greetingName: 'Nicola',
      startDate: '12 August 2026',
      quantityDistributed: '12,500',
      distributionAreas: 'Claremont and Newlands',
      mapLink: 'https://clm-maps.web.app/map/x7Kp2mQ1',
      client: 'Seeff',
    );

    test('substitutes every token in the supplied template', () {
      final body = DistributionReportTemplate.fallback.render(values);

      expect(body, contains('Hi Nicola,'));
      expect(
          body,
          contains('From 12 August 2026, we distributed 12,500 of '
              'your flyers in Claremont and Newlands.'));
      expect(body, contains('https://clm-maps.web.app/map/x7Kp2mQ1'));
      // Nothing left unexpanded.
      expect(body, isNot(contains('{')));
    });

    test('an unpaid invoice keeps the attached line', () {
      final body = DistributionReportTemplate.fallback.render(
        const DistributionReportValues(
          greetingName: 'Nicola',
          includeInvoiceLine: true,
        ),
      );
      expect(
          body,
          contains('Please let me know if you have any questions. '
              'Your invoice is attached.'));
    });

    test('a paid invoice drops the line and leaves no gap behind it', () {
      final body = DistributionReportTemplate.fallback.render(values);

      expect(body, isNot(contains('Your invoice is attached')));
      expect(body, contains('Please let me know if you have any questions.'));
      // The dropped sentence must not leave a trailing space or a double one.
      expect(body, isNot(contains('questions. \n')));
      expect(body, isNot(contains('questions.  ')));
    });

    test('keeps the map-reading instructions the client depends on', () {
      // The prose names a real control in the map viewer. If either drifts the
      // report tells the client to click something that is not there.
      final body = DistributionReportTemplate.fallback.render(values);
      expect(body, contains('Tap to load waypoints'));
      expect(body, contains('coloured blocks'));
      expect(body, contains('Blue lines'));
    });

    test('unknown placeholders are left visible rather than deleted', () {
      const template = DistributionReportTemplate(
        id: 't',
        name: 'custom',
        body: 'Hi {greeting_name}, ref {not_a_token}.',
      );
      expect(template.render(values), 'Hi Nicola, ref {not_a_token}.');
    });

    test('tidy collapses a blank line left by an empty token', () {
      expect(
        DistributionReportTemplate.tidy('one\n\n\n\ntwo'),
        'one\n\ntwo',
      );
      expect(DistributionReportTemplate.tidy('trailing   \n'), 'trailing');
    });
  });

  group('Flyers & Posters template', () {
    const template = DistributionReportTemplate.flyersAndPosters;
    const people = [
      DistributionReportPerson(name: 'Francis Kabetsha', idNumber: 'MA 210093'),
      DistributionReportPerson(name: 'Petros Muvimbi', idNumber: 'FN 186040'),
    ];
    DistributionReportValues values({
      bool leaflets = true,
      bool posters = true,
      bool invoice = false,
    }) =>
        DistributionReportValues(
          greetingName: 'Nikita',
          heading: 'MyCiTi Phase 2A',
          leafletName: 'Construction Update',
          leafletQuantity: '5,000',
          leafletDate: '21 October 2026',
          suburb: 'Claremont',
          leafletDistributorCount: 'two distributors',
          posterQuantity: '41',
          posterDate: '22 October 2026',
          posterDistributorCount: 'two distributors',
          mapLink: 'https://maps.communitylifemedia.co.za/map/LEAF1',
          posterMapLink: 'https://maps.communitylifemedia.co.za/map/POST1',
          posterPhotosLink:
              'https://maps.communitylifemedia.co.za/photos/POST1',
          people: people,
          hasLeaflets: leaflets,
          hasPosters: posters,
          includeInvoiceLine: invoice,
        );

    test('is offered as a Flyers & Posters template; the standard is not', () {
      expect(template.usesFlyersAndPosters, isTrue);
      expect(DistributionReportTemplate.fallback.usesFlyersAndPosters, isFalse);
    });

    test('both jobs: one opening sentence covering both, both sections', () {
      final body = template.render(values());
      expect(
          body,
          contains('On 21 October 2026 we distributed 5,000 Construction '
              'Update leaflets in the Claremont area and we put up 41 '
              'posters across the same area.'));
      expect(body, contains('Leaflets\n'));
      expect(body, contains('Posters\n'));
      expect(body, contains('by two distributors on 22 October 2026.'));
      expect(body, contains('/photos/POST1'));
      expect(body, contains('/map/POST1'));
      expect(body, contains('Francis Kabetsha — ID / Passport: MA 210093'));
      // The table appears once, under Leaflets.
      expect('ID / Passport: MA 210093'.allMatches(body).length, 1);
      expect(body, isNot(contains('[[')));
      expect(body, isNot(contains('**')));
      expect(body, isNot(contains('{')));
      expect(body, isNot(contains('\n\n\n')));
    });

    test('leaflets only: no poster wording at all', () {
      final body = template.render(values(posters: false));
      expect(
          body,
          contains('we distributed 5,000 Construction Update leaflets in the '
              'Claremont area.'));
      expect(body, isNot(contains('poster')));
      expect(body, isNot(contains('Posters')));
      expect(body, contains('Francis Kabetsha'));
    });

    test('posters only: poster opening and the table under Posters', () {
      final body = template.render(values(leaflets: false));
      expect(body,
          contains('On 22 October 2026 we put up 41 posters in the Claremont area.'));
      expect(body, isNot(contains('leaflets')));
      expect(body, isNot(contains('/map/LEAF1')));
      expect('ID / Passport: MA 210093'.allMatches(body).length, 1);
      expect(body.indexOf('Petros Muvimbi'),
          greaterThan(body.indexOf('Posters\n')));
    });

    test('invoice line follows the paid state like the standard report', () {
      expect(template.render(values(invoice: true)),
          contains('opportunity. Your invoice is attached.'));
      expect(template.render(values()),
          isNot(contains('Your invoice is attached')));
    });

    test('HTML: real table, bold headings, links, escaped text', () {
      final html = template.renderHtml(DistributionReportValues(
        greetingName: 'Nikita <script>',
        heading: 'A & B',
        leafletName: 'X',
        leafletQuantity: '1',
        mapLink: 'https://maps.communitylifemedia.co.za/map/LEAF1',
        people: people,
        hasLeaflets: true,
      ));
      expect(html, contains('<table'));
      expect(html, contains('<td style="border:1px solid #999;padding:4px 10px;'
          'text-align:left">MA 210093</td>'));
      expect(html, contains('<b>A &amp; B</b>'));
      expect(html, contains('<b>Leaflets</b>'));
      expect(html, contains('Nikita &lt;script&gt;'));
      expect(
          html,
          contains('<a href="https://maps.communitylifemedia.co.za/map/LEAF1">'
              'https://maps.communitylifemedia.co.za/map/LEAF1</a>'));
      expect(html, isNot(contains('\u0000')));
    });

    test('a trailing full stop is not swallowed into a link', () {
      const t = DistributionReportTemplate(
          id: 't', name: 't', body: 'See {map_link}.');
      expect(
          t.renderHtml(const DistributionReportValues(
              mapLink: 'https://example.com/map/a')),
          contains('<a href="https://example.com/map/a">'
              'https://example.com/map/a</a>.'));
    });

    test('countOf reads as words up to ten', () {
      expect(DistributionReportFormat.countOf(1, 'distributor'),
          'one distributor');
      expect(DistributionReportFormat.countOf(2, 'distributor'),
          'two distributors');
      expect(DistributionReportFormat.countOf(12, 'distributor'),
          '12 distributors');
    });
  });

  group('workerNameFromFileName', () {
    test('Track Editor GPX: the third field', () {
      expect(
          workerNameFromFileName(
              'Track   22 Oct 2026   Petros   Chand   Claremont   41 fulltrack.gpx'),
          'Petros');
      expect(
          workerNameFromFileName(
              'Waypoints   21 Oct 2026   Francis Kabetsha   Chand   12 fulltrack.gpx'),
          'Francis Kabetsha');
    });

    test('clmgpx photos: the text before the first underscore', () {
      expect(
          workerNameFromFileName('Petros_Poster 501_2026-10-22_12-37-26.jpg'),
          'Petros');
      expect(
          workerNameFromFileName('Unknown_Posters_2026-10-22_12-37-26.jpg'),
          isNull);
    });

    test('ignores compiled indexes and free-form names', () {
      expect(workerNameFromFileName('_compiled_tracks.json'), isNull);
      expect(workerNameFromFileName('IMG_2041.jpg'), isNull);
      expect(workerNameFromFileName('claremont.gpx'), isNull);
    });

    test('de-duplicates across spellings case-insensitively', () {
      expect(
          workerNamesFromFileNames([
            'Petros_Poster 1_2026-10-22_12-00-00.jpg',
            'PETROS_Poster 2_2026-10-22_12-05-00.jpg',
            'Track   22 Oct 2026   Francis   Chand   3 fulltrack.gpx',
          ]),
          ['Petros', 'Francis']);
    });
  });

  group('DistributionReport.totalsFor — people and photos', () {
    test('merges worker names and photo counts over selected folders only', () {
      final report = DistributionReport(
        jobId: 'j',
        client: 'Chand',
        jobDate: DateTime(2026, 10, 22),
        folders: const [
          DistributionReportFolder(
              path: 'a', workerNames: ['Petros'], photoCount: 20),
          DistributionReportFolder(
              path: 'b', workerNames: ['petros', 'Francis'], photoCount: 21),
          DistributionReportFolder(
              path: 'c', workerNames: ['Someone'], photoCount: 99),
        ],
      );
      final totals = report.totalsFor({'a', 'b'});
      expect(totals.workerNames, ['Petros', 'Francis']);
      expect(totals.photoCount, 41);
    });
  });

  group('DistributionReportDraft', () {
    test('round-trips everything the user decided', () {
      const draft = DistributionReportDraft(
        jobId: 'j1',
        templateId: '_flyers_posters',
        greeting: 'Nikita',
        subject: 'Report',
        heading: 'MyCiTi',
        leafletName: 'Update',
        suburb: 'Claremont',
        suburbTouched: true,
        clickedIsPoster: true,
        otherJobId: 'j2',
        unselectedFolders: ['b', 'a'],
        otherUnselectedFolders: ['c'],
        includeInvoiceLine: false,
        writeBackQuantity: true,
        pickedDistributor: {'petros': 'd1'},
        typedIds: {'d2': 'MA 210093'},
        removedPeople: ['name:someone'],
        invoiceChoices: {'inv-1': false, 'inv-2': true},
        invoicesWithPersonnel: ['inv-2'],
      );
      final back =
          DistributionReportDraft.fromMap('j1', draft.toContentMap());
      expect(back.toContentMap(), draft.toContentMap());
      // Sorted, so the same choice made in another order is not a change.
      expect(draft.toContentMap()['unselectedFolders'], ['a', 'b']);
    });

    test('a missing or malformed field reads as its default', () {
      final draft = DistributionReportDraft.fromMap('j1', {
        'greeting': 42,
        'typedIds': {'d1': 7},
        'unselectedFolders': 'nope',
      });
      expect(draft.greeting, '');
      expect(draft.typedIds, isEmpty);
      expect(draft.unselectedFolders, isEmpty);
      expect(draft.includeInvoiceLine, isNull);
    });
  });

  group('buildGmailComposeUrl', () {
    test('carries recipients, subject and body', () {
      final url = buildGmailComposeUrl(
        to: ['a@x.com', 'b@x.com'],
        subject: 'Distribution Report',
        body: 'Hi Nicola,',
      );

      expect(url.bodyIncluded, isTrue);
      expect(url.uri.queryParameters['to'], 'a@x.com,b@x.com');
      expect(url.uri.queryParameters['su'], 'Distribution Report');
      expect(url.uri.queryParameters['body'], 'Hi Nicola,');
      expect(url.uri.toString(), startsWith('https://mail.google.com/mail/'));
    });

    test('the real template fits comfortably inside the limit', () {
      final body = DistributionReportTemplate.fallback.render(
        const DistributionReportValues(
          greetingName: 'Nicola',
          startDate: '12 August 2026',
          quantityDistributed: '12,500',
          distributionAreas: 'Claremont, Newlands and Rondebosch',
          mapLink: 'https://clm-maps.web.app/map/x7Kp2mQ1',
          includeInvoiceLine: true,
        ),
      );

      final url = buildGmailComposeUrl(
        to: ['someone@example.com'],
        subject: 'Distribution Report — Seeff — 12 August 2026',
        body: body,
      );

      expect(url.bodyIncluded, isTrue);
      expect(url.uri.toString().length, lessThan(kGmailComposeUrlLimit));
    });

    test('the Flyers & Posters report fills the draft too', () {
      final body = DistributionReportTemplate.flyersAndPosters.render(
        const DistributionReportValues(
          greetingName: 'Nikita',
          heading: 'MyCiTi Phase 2A — Claremont construction update',
          leafletName: 'Construction Update',
          leafletQuantity: '5,000',
          leafletDate: '21 October 2026',
          suburb: 'Claremont, Newlands and Rondebosch',
          leafletDistributorCount: 'four distributors',
          posterQuantity: '41',
          posterDate: '22 October 2026',
          posterDistributorCount: 'two distributors',
          mapLink: 'https://maps.communitylifemedia.co.za/map/x7Kp2mQ1',
          posterMapLink: 'https://maps.communitylifemedia.co.za/map/p9Lq3nR2',
          posterPhotosLink:
              'https://maps.communitylifemedia.co.za/photos/p9Lq3nR2',
          people: [
            DistributionReportPerson(
                name: 'Francis Kabetsha', idNumber: 'MA 210093'),
            DistributionReportPerson(
                name: 'Petros Muvimbi', idNumber: 'FN 186040'),
            DistributionReportPerson(
                name: 'Tichaona Moyo', idNumber: '8501015800087'),
            DistributionReportPerson(name: 'Dickson Banda', idNumber: 'FN 1'),
          ],
          hasLeaflets: true,
          hasPosters: true,
          includeInvoiceLine: true,
        ),
      );

      final url = buildGmailComposeUrl(
        to: ['nikita@chand.co.za'],
        subject: kDefaultReportSubject,
        body: body,
      );

      expect(url.bodyIncluded, isTrue);
      expect(url.uri.queryParameters['body'],
          contains('Petros Muvimbi — ID / Passport: FN 186040'));
    });

    test('an over-long body is dropped rather than silently truncated', () {
      final url = buildGmailComposeUrl(
        to: ['a@x.com'],
        subject: 'Report',
        body: 'x' * (kGmailComposeUrlLimit + 1),
      );

      expect(url.bodyIncluded, isFalse);
      expect(url.uri.queryParameters.containsKey('body'), isFalse);
      // The draft is still addressed — only the body needs pasting.
      expect(url.uri.queryParameters['to'], 'a@x.com');
      expect(url.uri.queryParameters['su'], 'Report');
    });

    test('no recipients simply opens an empty draft', () {
      final url = buildGmailComposeUrl(to: [], subject: 'R', body: 'b');
      expect(url.uri.queryParameters.containsKey('to'), isFalse);
    });
  });
}
