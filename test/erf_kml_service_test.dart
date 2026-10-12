import 'package:clmschedule/erf_property/models/erf_list_entry.dart';
import 'package:clmschedule/erf_property/models/erf_property.dart';
import 'package:clmschedule/erf_property/services/erf_kml_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:xml/xml.dart';

ErfProperty _erf({
  String id = 'C01600070000123400000',
  String tag = '1234',
  String? address,
  List<LatLng>? polygon,
}) {
  return ErfProperty(
    id: id,
    erfNumber: 1234,
    tagValue: tag,
    lpiCode: id,
    majRegion: 'CAPE TOWN RD',
    majCode: 'C0160',
    minRegion: 'KENSINGTON',
    minCode: 'C0160007',
    province: 'WESTERN CAPE',
    area: 496.5,
    polygon: polygon ??
        const [
          LatLng(-33.905, 18.510),
          LatLng(-33.905, 18.511),
          LatLng(-33.906, 18.511),
          LatLng(-33.906, 18.510),
        ],
    centroid: const LatLng(-33.9055, 18.5105),
    streetAddress: address,
    suburb: 'Kensington',
  );
}

void main() {
  group('ErfKmlService', () {
    test('produces a parseable KML document with one placemark per parcel', () {
      final kml = ErfKmlService.buildKml(
        documentName: 'Kensington list',
        selected: [_erf(), _erf(id: 'B', tag: '1235')],
      );

      final doc = XmlDocument.parse(kml);
      expect(doc.rootElement.name.local, 'kml');
      expect(doc.findAllElements('Placemark'), hasLength(2));
      expect(
        doc.findAllElements('Document').first.getElement('name')!.innerText,
        'Kensington list',
      );
    });

    test('closes the polygon ring and writes lng,lat,alt order', () {
      final kml = ErfKmlService.buildKml(
        documentName: 'x',
        selected: [_erf()],
      );
      final coords =
          XmlDocument.parse(kml).findAllElements('coordinates').first.innerText;
      final points = coords.split(' ');

      expect(points.first, '18.51,-33.905,0');
      expect(points.last, points.first, reason: 'ring must close');
      expect(points, hasLength(5));
    });

    test('carries cadastral attributes as ExtendedData', () {
      final kml = ErfKmlService.buildKml(
        documentName: 'x',
        selected: [_erf(address: '12 Main Road')],
      );
      final data = {
        for (final d in XmlDocument.parse(kml).findAllElements('Data'))
          d.getAttribute('name')!: d.getElement('value')!.innerText,
      };

      expect(data['erfNumber'], '1234');
      expect(data['lpiCode'], 'C01600070000123400000');
      expect(data['streetAddress'], '12 Main Road');
      expect(data['minCode'], 'C0160007');
      expect(data['areaSqm'], '496.5');
    });

    test('separates selected and surrounding parcels into folders', () {
      final kml = ErfKmlService.buildKml(
        documentName: 'x',
        selected: [_erf()],
        context: [_erf(id: 'ctx', tag: '99')],
      );
      final folders = XmlDocument.parse(kml)
          .findAllElements('Folder')
          .map((f) => f.getElement('name')!.innerText)
          .toList();

      expect(folders, ['Selected ERFs', 'Surrounding ERFs']);
    });

    test('records unmatched pasted lines rather than dropping them', () {
      final kml = ErfKmlService.buildKml(
        documentName: 'x',
        selected: [_erf()],
        unmatched: const [
          ErfListEntry(lineNumber: 4, rawLine: '99 Nowhere Street'),
        ],
      );

      expect(kml, contains('Unmatched entries'));
      expect(kml, contains('Line 4: 99 Nowhere Street'));
    });

    test('falls back to a point when a parcel has no usable geometry', () {
      final kml = ErfKmlService.buildKml(
        documentName: 'x',
        selected: [
          _erf(polygon: const [LatLng(-33.9, 18.5)])
        ],
      );
      final doc = XmlDocument.parse(kml);

      expect(doc.findAllElements('Polygon'), isEmpty);
      // The pin sits on the parcel's stored centroid, not the stray point.
      expect(
          doc
              .findAllElements('Point')
              .first
              .getElement('coordinates')!
              .innerText,
          '18.5105,-33.9055,0');
    });

    test('writes KML AABBGGRR colours', () {
      final kml = ErfKmlService.buildKml(documentName: 'x', selected: [_erf()]);
      final style = XmlDocument.parse(kml)
          .findAllElements('Style')
          .firstWhere((s) => s.getAttribute('id') == 'erfSelected');

      // highlightColor is 0xFFFF6D00 → BBGGRR is 006dff.
      expect(style.getElement('LineStyle')!.getElement('color')!.innerText,
          'ff006dff');
      expect(style.getElement('PolyStyle')!.getElement('color')!.innerText,
          '80006dff');
    });

    test('builds a dated, filesystem-safe file name', () {
      final name = ErfKmlService.fileNameFor('Kensington — Job 42/A');
      expect(name,
          matches(RegExp(r'^kensington_job_42_a_\d{4}-\d{2}-\d{2}\.kml$')));
    });
  });
}
