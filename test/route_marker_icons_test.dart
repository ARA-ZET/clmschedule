import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:clmschedule/utils/route_marker_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('numbered pins actually rasterise', () {
    test('a single-digit stop produces a real bitmap', () async {
      expect(
        await RouteMarkerIcons.renderProducesBitmap('1', Colors.green),
        isTrue,
      );
    });

    test('a three-digit stop produces a real bitmap', () async {
      expect(
        await RouteMarkerIcons.renderProducesBitmap('147', Colors.red),
        isTrue,
      );
    });

    test('the depot letter produces a real bitmap', () async {
      expect(
        await RouteMarkerIcons.renderProducesBitmap('S', Colors.purple),
        isTrue,
      );
    });

    test('an empty label (the plain dot) still produces a bitmap', () async {
      expect(
        await RouteMarkerIcons.renderProducesBitmap('', Colors.blue),
        isTrue,
      );
    });

    test('nothing fell back to an unnumbered stock pin', () {
      expect(RouteMarkerIcons.encodeFailures, 0);
    });
  });

  group('run colouring', () {
    test('walks green to red across the run', () {
      final first = RouteMarkerIcons.colorForPosition(0, 10);
      final last = RouteMarkerIcons.colorForPosition(9, 10);

      expect(first.g, greaterThan(first.r));
      expect(last.r, greaterThan(last.g));
    });

    test('a single stop does not divide by zero', () {
      expect(() => RouteMarkerIcons.colorForPosition(0, 1), returnsNormally);
      expect(() => RouteMarkerIcons.colorForPosition(0, 0), returnsNormally);
    });
  });

  group('batch building', () {
    test('returns one icon per requested key', () async {
      final icons = await RouteMarkerIcons.batch({
        'a': (label: '1', color: Colors.green),
        'b': (label: '2', color: Colors.orange),
        'c': (label: '3', color: Colors.red),
      });

      expect(icons.keys, containsAll(['a', 'b', 'c']));
    });

    test('an empty request yields an empty map', () async {
      expect(await RouteMarkerIcons.batch({}), isEmpty);
    });
  });

  group('the number is actually drawn into the pixels', () {
    /// Count pixels that are close to white inside the pin's disc — that is
    /// the glyph, since the disc itself is a solid colour.
    Future<int> whitePixelsInGlyphArea(String label) async {
      final image = await RouteMarkerIcons.renderImage(label, Colors.green);
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      expect(data, isNotNull);

      final bytes = data!.buffer.asUint8List();
      final width = image.width;
      // The disc sits in the upper portion of the bitmap; sample a box
      // around its centre, well inside the white ring.
      final cx = width ~/ 2;
      final cy = (width * 16 / 38).round();
      final radius = (width * 7 / 38).round();

      var white = 0;
      for (var y = cy - radius; y <= cy + radius; y++) {
        for (var x = cx - radius; x <= cx + radius; x++) {
          final i = (y * width + x) * 4;
          if (i < 0 || i + 3 >= bytes.length) continue;
          final r = bytes[i];
          final g = bytes[i + 1];
          final b = bytes[i + 2];
          final a = bytes[i + 3];
          if (a > 200 && r > 220 && g > 220 && b > 220) white++;
        }
      }
      image.dispose();
      return white;
    }

    test('a digit leaves white pixels inside the disc', () async {
      expect(await whitePixelsInGlyphArea('7'), greaterThan(20));
    });

    test('a three-digit stop still paints inside the disc', () async {
      // Not a comparison against a shorter label: the test font renders
      // every glyph as an identical solid block, so digit shapes are
      // indistinguishable here. What matters is that 147 still lands ink
      // in the middle of the pin rather than overflowing it.
      expect(await whitePixelsInGlyphArea('147'), greaterThan(20));
    });

    test('an empty label leaves the disc clean', () async {
      // The plain dot must not accidentally paint a glyph.
      expect(await whitePixelsInGlyphArea(''), lessThan(20));
    });
  });

  group('bitmap sizing', () {
    test('renders at the pixel ratio, not the logical size', () async {
      final image = await RouteMarkerIcons.renderImage('1', Colors.green);
      // A logical 38pt pin drawn at 3x is a 114px bitmap; handing the map a
      // 38px one would look soft on every retina screen.
      expect(image.width, greaterThan(RouteMarkerIcons.pinSize));
      expect(image.width, image.height);
      image.dispose();
    });
  });
}
