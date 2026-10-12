import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:clmschedule/letterbox/services/letterbox_codec.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// A plausible spread of letterbox positions across a Cape Town suburb.
List<LatLng> _suburbPoints(int n) {
  return [
    for (var i = 0; i < n; i++)
      LatLng(
        -33.925000 + (i % 120) * 0.000180,
        18.425000 + (i ~/ 120) * 0.000210,
      ),
  ];
}

void main() {
  group('LetterboxCodec', () {
    test('round-trips positions', () {
      final points = _suburbPoints(1450);

      final decoded = LetterboxCodec.decode(LetterboxCodec.encode(
        suburbId: 'constantia',
        suburbName: 'Constantia',
        points: points,
      ));

      expect(decoded.length, points.length);
      for (var i = 0; i < points.length; i++) {
        // 6-dp rounding is the only loss, so ~11 cm.
        expect(decoded[i].latitude, closeTo(points[i].latitude, 1e-6));
        expect(decoded[i].longitude, closeTo(points[i].longitude, 1e-6));
      }
    });

    test('preserves order, so a save does not reshuffle a curated set', () {
      final points = [
        const LatLng(-33.900001, 18.400001),
        const LatLng(-33.910002, 18.410002),
        const LatLng(-33.920003, 18.420003),
      ];

      final decoded = LetterboxCodec.decode(LetterboxCodec.encode(
        suburbId: 's',
        suburbName: 'S',
        points: points,
      ));

      expect(decoded.map((p) => p.latitude).toList(),
          [-33.900001, -33.910002, -33.920003]);
      expect(decoded.map((p) => p.longitude).toList(),
          [18.400001, 18.410002, 18.420003]);
    });

    test('round-trips an empty suburb', () {
      final decoded = LetterboxCodec.decode(LetterboxCodec.encode(
        suburbId: 'empty',
        suburbName: 'Empty',
        points: const [],
      ));
      expect(decoded, isEmpty);
    });

    test('refuses a payload written by a different format version', () {
      final future = Uint8List.fromList(const GZipEncoder()
          .encode(utf8.encode(jsonEncode({'v': 99, 'pts': <double>[]}))));

      expect(
          () => LetterboxCodec.decode(future), throwsA(isA<FormatException>()));
    });

    test('refuses input that is not gzip at all', () {
      expect(
        () =>
            LetterboxCodec.decode(Uint8List.fromList(utf8.encode('nonsense'))),
        throwsA(isA<FormatException>()),
      );
    });

    test('refuses an odd-length coordinate array rather than dropping a point',
        () {
      final truncated =
          Uint8List.fromList(const GZipEncoder().encode(utf8.encode(jsonEncode({
        'v': LetterboxCodec.formatVersion,
        'pts': [18.42, -33.92, 18.43],
      }))));

      expect(() => LetterboxCodec.decode(truncated),
          throwsA(isA<FormatException>()));
    });

    test('compresses far below the Firestore document representation', () {
      final points = _suburbPoints(1450);

      final packed = LetterboxCodec.encode(
        suburbId: 'constantia',
        suburbName: 'Constantia',
        points: points,
      );

      // What these points would cost in the shape the app uses everywhere
      // else — CustomPolygon.toMap()'s {'latitude': .., 'longitude': ..}.
      final firestoreish = utf8
          .encode(jsonEncode(points
              .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
              .toList()))
          .length;

      // The plan's acceptance bar for this stage.
      expect(packed.length * 8, lessThan(firestoreish));

      // ignore: avoid_print
      print('1450 letterboxes: Firestore-shape $firestoreish B → '
          'packed ${packed.length} B '
          '(${(firestoreish / packed.length).toStringAsFixed(1)}x smaller)');
    });
  });
}
