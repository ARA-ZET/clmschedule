import 'dart:io';

import 'package:clmschedule/letterbox/services/letterbox_codec.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the payload format across the Node/Dart boundary.
///
/// The Cloud Function (`functions/lib/letterbox_index.js`) writes the
/// per-suburb `.json.gz` payloads; this app reads them. A drift between the
/// two encoders would not throw — the app would simply decode zero
/// letterboxes and every quote would read low, with no error anywhere.
///
/// The fixture is produced by `node functions/test/letterbox_fixture_gen.js`.
/// If this test fails, the two encoders have diverged: fix them and
/// regenerate, bumping the format version on both sides.
void main() {
  group('Node-written letterbox payload', () {
    final fixture = File('test/fixtures/letterbox_node_payload.json.gz');

    test('fixture exists', () {
      expect(
        fixture.existsSync(),
        isTrue,
        reason: 'Run: node functions/test/letterbox_fixture_gen.js',
      );
    });

    test('decodes with the Dart codec', () {
      final points =
          LetterboxCodec.decode(Uint8List.fromList(fixture.readAsBytesSync()));

      expect(points, hasLength(4));

      // Coordinate order is the trap: the payload stores [lng, lat] pairs
      // while LatLng takes (lat, lng). Swapping them puts Cape Town in
      // Kazakhstan, so assert both explicitly.
      expect(points[0].latitude, closeTo(-33.925001, 1e-9));
      expect(points[0].longitude, closeTo(18.425001, 1e-9));

      // Written as -33.9260005 / 18.4260004, which sits exactly on the 6-dp
      // rounding boundary. Node rounds the latitude away from zero to
      // -33.926001 and the longitude down to 18.426 — the app must see
      // precisely those, not its own re-rounding of them.
      expect(points[1].latitude, closeTo(-33.926001, 1e-9));
      expect(points[1].longitude, closeTo(18.426, 1e-9));

      expect(points[2].latitude, closeTo(-33.927, 1e-9));
      expect(points[2].longitude, closeTo(18.427, 1e-9));

      expect(points[3].latitude, closeTo(-33.928123, 1e-9));
      expect(points[3].longitude, closeTo(18.428987, 1e-9));
    });

    test('Dart re-encodes the Node payload to identical bytes', () {
      // The strongest form of the guarantee: decode what Node wrote, encode it
      // again with the Dart codec, and require the gzipped bytes to match.
      // This catches key renames, field reordering, precision changes and
      // rounding-rule drift in one assertion — any of which would otherwise
      // surface as a silently low letterbox count rather than an error.
      final original = Uint8List.fromList(fixture.readAsBytesSync());
      final points = LetterboxCodec.decode(original);

      final reencoded = LetterboxCodec.encode(
        suburbId: 'fixture_suburb',
        suburbName: 'Fixture Suburb',
        points: points,
      );

      expect(
        reencoded,
        equals(original),
        reason: 'The Node and Dart encoders have diverged. Fix both, then '
            'run: node functions/test/letterbox_fixture_gen.js',
      );
    });

    test('every position lands in Cape Town, not mirrored or transposed', () {
      final points =
          LetterboxCodec.decode(Uint8List.fromList(fixture.readAsBytesSync()));

      for (final p in points) {
        expect(p.latitude, inInclusiveRange(-35.0, -33.0));
        expect(p.longitude, inInclusiveRange(18.0, 19.5));
      }
    });
  });
}
