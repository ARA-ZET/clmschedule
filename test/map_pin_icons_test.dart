// Map pins say what happens at the spot: the drop-off van, a bin for a junk
// collection, a sofa for a furniture move, a window for window cleaning.
// These pin down which picture each point gets.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import 'package:clmschedule/models/company.dart';
import 'package:clmschedule/models/custom_job_type.dart';
import 'package:clmschedule/models/custom_polygon.dart';
import 'package:clmschedule/utils/map_pin_icons.dart';

CustomPolygon _point(PointCategory category, {String name = ''}) =>
    CustomPolygon(
      name: name,
      description: '',
      points: const [LatLng(-33.9, 18.6)],
      color: Colors.purple,
      type: MapElementType.point,
      pointCategory: category,
    );

CustomJobType _type(String id, String label,
        {String companyId = Company.junkAndStuffId, int? colorValue}) =>
    CustomJobType(
      id: id,
      label: label,
      companyId: companyId,
      colorValue: colorValue,
    );

void main() {
  group('MapPinStyle.forPoint', () {
    test('the worker drop-off is always the drop-off van', () {
      final style = MapPinStyle.forPoint(_point(PointCategory.dropoff),
          jobType: _type('junkCollection', 'Junk Collection'));
      expect(style, MapPinStyle.dropOff);
      expect(style.shape, PinShape.sign);
      expect(style.tag, 'DROP-OFF');
    });

    test('a pick-up with no job is the pick-up van', () {
      final style = MapPinStyle.forPoint(_point(PointCategory.pickup));
      expect(style, MapPinStyle.pickUp);
      expect(style.shape, PinShape.sign);
      expect(style.tag, 'PICK-UP');
    });

    test('a booked call-out carries its time under the word', () {
      final solar = _type('solarPanelCleaning', 'Solar Panel Cleaning',
          companyId: Company.happySunId);
      final style = MapPinStyle.forPoint(_point(PointCategory.cleaning),
          jobType: solar, time: '09:30');
      expect(style.tag, 'SOLAR CLEANING');
      expect(style.time, '09:30');
      expect(style.withoutTime.time, isNull);
      expect(style.withoutTime.tag, 'SOLAR CLEANING');
      expect(style.key, isNot(style.withoutTime.key));
      // The second line makes the pin's box taller, not narrower.
      final timed = MapPinPainter.bounds(style);
      final plain = MapPinPainter.bounds(style.withoutTime);
      expect(timed.height, greaterThanOrEqualTo(plain.height));
      expect(timed.width, greaterThanOrEqualTo(plain.width));
    });

    test('a time needs a job: plain points never show one', () {
      expect(
          MapPinStyle.forPoint(_point(PointCategory.cleaning), time: '09:30')
              .time,
          isNull);
    });

    test('the default job types each get their own picture', () {
      IconData glyph(String id, String label) => MapPinStyle.forPoint(
              _point(PointCategory.pickup),
              jobType: _type(id, label))
          .glyph;
      expect(glyph('junkCollection', 'Junk Collection'), Icons.delete_rounded);
      expect(glyph('furnitureMove', 'Furniture Move'), Icons.weekend_rounded);
      expect(glyph('trailerTowing', 'Trailer Towing'), Icons.rv_hookup_rounded);
      expect(glyph('windowCleaning', 'Window Cleaning'), Icons.window_rounded);
      expect(glyph('solarPanelCleaning', 'Solar Panel Cleaning'),
          Icons.solar_power_rounded);
    });

    test('types added in Settings are recognised by name', () {
      IconData glyph(String label, {String company = Company.happySunId}) =>
          MapPinStyle.forPoint(_point(PointCategory.generic),
                  jobType: _type('custom-1', label, companyId: company))
              .glyph;
      expect(glyph('Gutter Cleaning'), Icons.roofing_rounded);
      expect(glyph('Garden Refuse Removal', company: Company.junkAndStuffId),
          Icons.delete_rounded);
      expect(glyph('High Pressure Cleaning'), Icons.water_drop_rounded);
      expect(glyph('Carpet Cleaning'), Icons.chair_rounded);
      expect(glyph('Something New'), Icons.wb_sunny_rounded);
      expect(glyph('Something New', company: Company.junkAndStuffId),
          Icons.local_shipping_rounded);
    });

    test('job pins are teardrops tagged with a short word', () {
      MapPinStyle style(String id, String label) => MapPinStyle.forPoint(
          _point(PointCategory.pickup),
          jobType: _type(id, label, companyId: Company.happySunId));
      expect(style('junkCollection', 'Junk Collection').shape, PinShape.pin);
      expect(style('junkCollection', 'Junk Collection').tag, 'COLLECTION');
      expect(style('windowCleaning', 'Window Cleaning').tag, 'WINDOWS CLEANING');
      // Unrecognised types are tagged with their first word.
      expect(style('custom-1', 'Aircon Service').tag, 'AIRCON');
    });

    test('loading and offloading say so', () {
      final move = _type('furnitureMove', 'Furniture Move');
      final load = MapPinStyle.forPoint(_point(PointCategory.loading),
          jobType: move);
      final drop = MapPinStyle.forPoint(_point(PointCategory.offloading),
          jobType: move);
      expect(load.glyph, Icons.weekend_rounded);
      expect(load.tag, 'FURNITURE MOVE · LOADING');
      expect(load.label, 'Furniture Move – loading');
      expect(drop.tag, 'FURNITURE MOVE · OFFLOADING');
      expect(drop.label, 'Furniture Move – offloading');
    });

    test("the job type's own colour wins", () {
      final style = MapPinStyle.forPoint(_point(PointCategory.pickup),
          jobType: _type('junkCollection', 'Junk Collection',
              colorValue: 0xFF123456));
      expect(style.color, const Color(0xFF123456));
    });

    test('plain points are recognised by name, in their own colour', () {
      final lights = MapPinStyle.forPoint(
          _point(PointCategory.generic, name: 'Robot at Voortrekker Rd'));
      expect(lights.glyph, Icons.traffic_rounded);
      expect(lights.tag, 'ROBOT');
      expect(lights.color, Colors.purple.withValues(alpha: 1));
      expect(MapPinStyle.forPoint(_point(PointCategory.generic)).shape,
          PinShape.dot);
    });
  });

  test('MapPinIcons draws a PNG anchored on the tip', () async {
    final image = await MapPinIcons.render(MapPinStyle.dropOff, mono: true);
    expect(image.png.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    // The tag runs right, so the tip sits left of centre, near the bottom.
    expect(image.anchor.dx, lessThan(0.5));
    expect(image.anchor.dy, greaterThan(0.85));
  });

  group('MapPinStyle.named', () {
    test('a work spot carries its own name in the colour given', () {
      final style = MapPinStyle.named(
          _point(PointCategory.generic, name: 'Traffic light Main Rd'),
          Colors.red);
      expect(style.tag, 'Traffic light Main Rd');
      expect(style.glyph, Icons.traffic_rounded);
      expect(style.color.toARGB32(), Colors.red.toARGB32());
      expect(style.shape, PinShape.pin);
    });

    test('poster spots get the poster glyph; other names a place pin', () {
      expect(
          MapPinStyle.named(
                  _point(PointCategory.generic, name: 'Poster - Spar'),
                  Colors.blue)
              .glyph,
          Icons.campaign_rounded);
      expect(
          MapPinStyle.named(
                  _point(PointCategory.generic, name: 'Corner'), Colors.blue)
              .glyph,
          Icons.place_rounded);
    });

    test('a long name wraps onto two balanced lines', () {
      final style = MapPinStyle.named(
          _point(PointCategory.generic,
              name: 'Burger King Turfhall Road Drive-Thru'),
          Colors.green);
      expect(style.tag, 'Burger King Turfhall\nRoad Drive-Thru');
      expect(style.label, 'Burger King Turfhall Road Drive-Thru');
      // The second line makes the tag taller (seen on a pin hanging down,
      // where nothing else reaches below it), not the pin wider.
      final one = MapPinPainter.bounds(MapPinStyle.named(
              _point(PointCategory.generic, name: 'Burger King Turfhall'),
              Colors.green)
          .withPlacement(PinPlacement.down));
      final two =
          MapPinPainter.bounds(style.withPlacement(PinPlacement.down));
      expect(two.height, greaterThan(one.height));
      expect(two.width, closeTo(one.width, 2));
    });

    test('a name too long for two lines is cut short on the second', () {
      final tag = MapPinStyle.named(
              _point(PointCategory.generic,
                  name: 'Hand-out at the corner of Durban Road and Main '
                      'Road opposite the station'),
              Colors.green)
          .tag!;
      final lines = tag.split('\n');
      expect(lines, hasLength(2));
      expect(lines.every((l) => l.length <= 22), isTrue);
      expect(lines.last, endsWith('…'));
    });

    test('an unnamed point shows its word, or no tag', () {
      expect(
          MapPinStyle.named(_point(PointCategory.generic), Colors.green).tag,
          isNull);
    });
  });

  group('MapPinLayout', () {
    MapPinStyle named(String name) => MapPinStyle.named(
        _point(PointCategory.generic, name: name), Colors.blue);

    test('far-apart pins all stay upright with the tag on the right', () {
      final out = MapPinLayout.arrange([
        ('a', const LatLng(-33.95, 18.50), named('Lansdowne Station')),
        ('b', const LatLng(-33.99, 18.56), named('Boeta Tuckshop')),
      ], 15);
      expect(out.values, everyElement(PinPlacement.up));
    });

    test('close pins are turned so their tags do not cover each other', () {
      // ~140 m apart along one street (about 35 px at zoom 15): their
      // upright tags would collide.
      final pins = [
        ('a', const LatLng(-33.9700, 18.5300), named('Burger King Turfhall')),
        ('b', const LatLng(-33.9702, 18.5315), named('Castor Road')),
        ('c', const LatLng(-33.9698, 18.5285), named('Shado Wholesale')),
      ];
      final out = MapPinLayout.arrange(pins, 15);
      expect(out.values.toSet(), hasLength(greaterThan(1)));

      // The chosen pins do not overlap.
      final world = 256 * 32768.0;
      Rect box(int i) {
        final (id, at, style) = pins[i];
        final x = (at.longitude + 180) / 360 * world;
        final sn = math.sin(at.latitude * math.pi / 180);
        final y = (0.5 - math.log((1 + sn) / (1 - sn)) / (4 * math.pi)) * world;
        // Less the 3 px margin round each picture.
        return MapPinPainter.bounds(style.withPlacement(out[id]!))
            .shift(Offset(x, y))
            .deflate(3);
      }

      for (var i = 0; i < pins.length; i++) {
        for (var j = i + 1; j < pins.length; j++) {
          final o = box(i).intersect(box(j));
          expect(o.width <= 0 || o.height <= 0, isTrue,
              reason: '${pins[i].$1} and ${pins[j].$1} overlap');
        }
      }
    });

    test('a pin hanging down has its head below the spot, tag on the left',
        () {
      final style = named('Castor Road');
      final up = MapPinPainter.bounds(style);
      final down =
          MapPinPainter.bounds(style.withPlacement(PinPlacement.downLeft));
      expect(up.top, lessThan(-30));
      expect(down.bottom, greaterThan(30));
      expect(down.top, greaterThan(-10));
      expect(down.left, lessThan(-40));
      expect(style.withPlacement(PinPlacement.down).key, isNot(style.key));
    });

    testWidgets('every placement rasterises with the tip as the anchor',
        (tester) async {
      await tester.runAsync(() async {
        for (final p in PinPlacement.values) {
          final image = await MapPinIcons.render(
              named('Burger King Turfhall Road Drive-Thru').withPlacement(p));
          expect(image.png, isNotEmpty);
          expect(image.anchor.dy, p.hangsDown ? lessThan(0.3) : greaterThan(0.7));
        }
      });
    });
  });
}
