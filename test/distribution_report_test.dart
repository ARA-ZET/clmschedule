import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart' show Colors;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/models/distribution_report.dart';
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
