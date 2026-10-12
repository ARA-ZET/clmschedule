import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:clmschedule/erf_property/models/erf_property.dart';
import 'package:clmschedule/erf_property/services/erf_area_codec.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

ErfProperty _erf(int n, {int vertices = 40}) => ErfProperty(
      id: 'C016001100000${n.toString().padLeft(4, '0')}00000',
      erfNumber: n,
      tagValue: '$n',
      lpiCode: 'C016001100000${n.toString().padLeft(4, '0')}00000',
      majRegion: 'CAPE',
      majCode: 'C0160000',
      minRegion: 'CONSTANTIA',
      minCode: 'C0160011',
      province: 'WESTERN CAPE',
      area: 496.53,
      centroid: LatLng(-33.9 - n * 1e-5, 18.4 + n * 1e-5),
      polygon: [
        for (var i = 0; i < vertices; i++)
          LatLng(-33.9 - n * 1e-5 + i * 1e-6, 18.4 + n * 1e-5 + i * 1e-6),
      ],
    );

void main() {
  group('ErfAreaCodec', () {
    test('round-trips a parcel with all its cadastral fields', () {
      final original = _erf(1234).copyWith(
        streetAddress: '12 Main Road',
        suburb: 'Constantia',
      );

      final decoded = ErfAreaCodec.decode(
        ErfAreaCodec.encode(
            areaId: 'region_C0160011',
            name: 'CONSTANTIA',
            properties: [original]),
      );

      expect(decoded, hasLength(1));
      final p = decoded.single;
      expect(p.id, original.id);
      expect(p.erfNumber, 1234);
      expect(p.tagValue, '1234');
      expect(p.lpiCode, original.lpiCode);
      expect(p.minRegion, 'CONSTANTIA');
      expect(p.minCode, 'C0160011');
      expect(p.majRegion, 'CAPE');
      expect(p.majCode, 'C0160000');
      expect(p.province, 'WESTERN CAPE');
      expect(p.area, closeTo(496.53, 0.01));
      expect(p.streetAddress, '12 Main Road');
      expect(p.suburb, 'Constantia');
      expect(p.polygon, hasLength(original.polygon.length));
    });

    test('stamps the area id onto every decoded parcel', () {
      final bytes = ErfAreaCodec.encode(
          areaId: 'region_C0160011', name: 'X', properties: [_erf(1), _erf(2)]);
      final decoded = ErfAreaCodec.decode(bytes);
      expect(decoded.map((p) => p.areaId), everyElement('region_C0160011'));
    });

    test('keeps coordinates accurate to well under a metre', () {
      final original = _erf(7);
      final decoded = ErfAreaCodec.decode(
          ErfAreaCodec.encode(areaId: 'a', name: 'n', properties: [original]));

      for (var i = 0; i < original.polygon.length; i++) {
        // 1e-6 degrees ≈ 11 cm.
        expect(decoded.single.polygon[i].latitude,
            closeTo(original.polygon[i].latitude, 1e-6));
        expect(decoded.single.polygon[i].longitude,
            closeTo(original.polygon[i].longitude, 1e-6));
      }
      expect(decoded.single.centroid.latitude,
          closeTo(original.centroid.latitude, 1e-6));
    });

    test('handles an empty area and parcels without geometry', () {
      expect(
        ErfAreaCodec.decode(
            ErfAreaCodec.encode(areaId: 'a', name: 'n', properties: [])),
        isEmpty,
      );

      final noGeometry = _erf(3, vertices: 0);
      final decoded = ErfAreaCodec.decode(ErfAreaCodec.encode(
          areaId: 'a', name: 'n', properties: [noGeometry]));
      expect(decoded.single.polygon, isEmpty);
    });

    test('refuses a payload written by a different format version', () {
      final future = Uint8List.fromList(const GZipEncoder()
          .encode(utf8.encode(jsonEncode({'v': 99, 'parcels': []}))));

      expect(
          () => ErfAreaCodec.decode(future), throwsA(isA<FormatException>()));
    });

    test('refuses input that is not a gzip payload at all', () {
      expect(
        () => ErfAreaCodec.decode(Uint8List.fromList(utf8.encode('nonsense'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('compresses far below the Firestore document representation', () {
      final parcels = [for (var i = 1; i <= 500; i++) _erf(i)];

      final packed = ErfAreaCodec.encode(
          areaId: 'region_C0160011', name: 'CONSTANTIA', properties: parcels);
      final firestoreish = utf8
          .encode(jsonEncode(parcels.map((p) => p.toMap()).toList()))
          .length;

      // Expect at least a 10x saving; in practice it lands far better.
      expect(packed.length * 10, lessThan(firestoreish));
      // ignore: avoid_print
      print('500 parcels: Firestore-shape ${firestoreish ~/ 1024} KB → '
          'packed ${packed.length ~/ 1024} KB '
          '(${(firestoreish / packed.length).toStringAsFixed(1)}x smaller)');
    });
  });
}
