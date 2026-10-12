import 'package:clmschedule/track_editor/utils/te_track_gaps.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';

// Roughly 11 m per 0.0001 degree of latitude.
const base = -33.93;
const lon = 18.86;

Wpt pt(double lat, [double lng = lon]) => Wpt(lat: lat, lon: lng);

Trk walk(double startLat, int n, {String? name}) => Trk(
      name: name,
      trksegs: [
        Trkseg(trkpts: [for (var i = 0; i < n; i++) pt(startLat + i * 0.0001)])
      ],
    );

void main() {
  test('a track with no gap comes back as the same instance', () {
    final trk = walk(base, 20, name: 'Route');
    final out = splitTracksAtGaps([trk]);
    expect(out, hasLength(1));
    expect(identical(out.single, trk), isTrue);
  });

  test('splits at a jump over 50 m and drops the jump', () {
    final trk = Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [
        for (var i = 0; i < 5; i++) pt(base + i * 0.0001),
        // ~1 km away
        for (var i = 0; i < 5; i++) pt(base + 0.01 + i * 0.0001),
      ])
    ]);
    final out = splitTracksAtGaps([trk]);
    expect(out, hasLength(2));
    expect(out.map((t) => t.name), ['Route (1)', 'Route (2)']);
    expect(out.map((t) => t.trksegs.single.trkpts.length), [5, 5]);
  });

  test('removes a single-point GPS spike out and back', () {
    // The spike on the map: a walk in Stellenbosch, one point in
    // Matroosfontein, then back to Stellenbosch.
    final trk = Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [
        for (var i = 0; i < 5; i++) pt(base + i * 0.0001),
        pt(-33.95, 18.58),
        for (var i = 5; i < 10; i++) pt(base + i * 0.0001),
      ])
    ]);
    final out = splitTracksAtGaps([trk]);
    expect(out, hasLength(2));
    final all = out.expand((t) => t.trksegs.single.trkpts);
    expect(all.any((p) => p.lon == 18.58), isFalse);
  });

  test('keeps the original name when only one piece survives', () {
    final trk = Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [
        for (var i = 0; i < 5; i++) pt(base + i * 0.0001),
        pt(-33.95, 18.58),
      ])
    ]);
    final out = splitTracksAtGaps([trk]);
    expect(out.single.name, 'Route');
    expect(out.single.trksegs.single.trkpts, hasLength(5));
  });

  test('a 50 m step is kept, anything over is split', () {
    // 0.00044 deg lat ≈ 49 m; 0.00047 deg ≈ 52 m.
    final keep = Trk(trksegs: [
      Trkseg(trkpts: [pt(base), pt(base + 0.00044)])
    ]);
    final split = Trk(trksegs: [
      Trkseg(trkpts: [pt(base), pt(base + 0.00047)])
    ]);
    expect(splitTracksAtGaps([keep]), hasLength(1));
    expect(splitTracksAtGaps([split]), isEmpty);
  });

  test('flattens segments and splits across a segment boundary', () {
    final trk = Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [for (var i = 0; i < 3; i++) pt(base + i * 0.0001)]),
      Trkseg(
          trkpts: [for (var i = 0; i < 3; i++) pt(base + 0.01 + i * 0.0001)]),
    ]);
    final out = splitTracksAtGaps([trk]);
    expect(out, hasLength(2));
  });

  test('a wider distance keeps a driven stretch in one piece', () {
    // ~55 m between points: a distributor driving between streets. The 50 m
    // default cuts every step; 60 m leaves the stretch whole.
    final drive = Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [for (var i = 0; i < 6; i++) pt(base + i * 0.0005)])
    ]);
    expect(splitTracksAtGaps([drive]), isEmpty);
    expect(splitTracksAtGaps([drive], maxGapM: 60), hasLength(1));
  });

  test('a narrower distance splits where the default would not', () {
    // ~33 m steps: kept at 50 m, split at 20 m.
    final trk = Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [for (var i = 0; i < 4; i++) pt(base + i * 0.0003)])
    ]);
    expect(splitTracksAtGaps([trk]), hasLength(1));
    expect(splitTracksAtGaps([trk], maxGapM: 20), isEmpty);
  });

  test('the detached split never hands back a track from the source', () {
    final trk = walk(base, 20, name: 'Route');
    final source = [trk];
    final out = splitTracksAtGapsDetached(source, kTrackGapSplitM);

    expect(out, hasLength(1));
    expect(identical(out.single, trk), isFalse);
    expect(out.single.name, 'Route');
    // Renaming the split copy must leave the source alone, so re-splitting
    // it later starts from the file's own names again.
    out.single.name = 'Renamed';
    expect(trk.name, 'Route');
    // Trackpoints are deliberately shared — a dragged point survives a
    // re-split.
    expect(
      identical(out.single.trksegs.single.trkpts.first,
          trk.trksegs.single.trkpts.first),
      isTrue,
    );
  });

  test('re-splitting the source at a wider distance rejoins the pieces', () {
    final trk = Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [for (var i = 0; i < 6; i++) pt(base + i * 0.0005)])
    ]);
    final source = [trk];
    expect(splitTracksAtGapsDetached(source, kTrackGapSplitM), isEmpty);
    expect(splitTracksAtGapsDetached(source, 60), hasLength(1));
  });

  test('the slider bounds cover 20-100 m in 10 m steps', () {
    expect(kTrackGapSplitMinM, 20);
    expect(kTrackGapSplitMaxM, 100);
    expect(kTrackGapSplitStepM, 10);
    expect(kTrackGapSplitDivisions, 8);
    expect(kTrackGapSplitM, greaterThanOrEqualTo(kTrackGapSplitMinM));
    expect(kTrackGapSplitM, lessThanOrEqualTo(kTrackGapSplitMaxM));
  });
}
