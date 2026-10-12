import 'package:clmschedule/shareable_maps/utils/gpx_track_rename.dart';
import 'package:flutter_test/flutter_test.dart';

const _gpx = '''<?xml version="1.0" encoding="UTF-8"?>
<gpx version="1.1" creator="CLM" xmlns="http://www.topografix.com/GPX/1/1">
  <metadata><name>Jo Lomberd</name></metadata>
  <wpt lat="-33.9" lon="18.4"><name>Jo Lomberd</name></wpt>
  <trk>
    <name>Jo Lomberd</name>
    <trkseg><trkpt lat="-33.9" lon="18.4"/><trkpt lat="-33.91" lon="18.41"/></trkseg>
  </trk>
  <trk>
    <trkseg><trkpt lat="-33.9" lon="18.4"/><trkpt lat="-33.91" lon="18.41"/></trkseg>
  </trk>
</gpx>''';

void main() {
  test('renames only the matching track name', () {
    final r =
        renameTracksInGpx(_gpx, oldBase: 'Jo Lomberd', newBase: 'Jo Lombard');
    expect(r.renamed, 1);
    expect(r.gpx, contains('<trk>\n    <name>Jo Lombard</name>'));
    // Waypoint and metadata names are left alone.
    expect('Jo Lomberd'.allMatches(r.gpx).length, 2);
    expect(r.gpx, contains('xmlns="http://www.topografix.com/GPX/1/1"'));
  });

  test('names an unnamed track shown as "Track N"', () {
    final r = renameTracksInGpx(_gpx, oldBase: 'Track 2', newBase: 'Sam');
    expect(r.renamed, 1);
    expect(r.gpx, contains('<trk><name>Sam</name>'));
  });

  test('no match leaves the file alone', () {
    expect(renameTracksInGpx(_gpx, oldBase: 'Nobody', newBase: 'X').renamed, 0);
  });

  test('segment suffix round-trips', () {
    expect(baseTrackName('Jo Lomberd (seg 2)'), 'Jo Lomberd');
    expect(renamedDisplayName('Jo Lomberd (seg 2)', 'Jo Lombard'),
        'Jo Lombard (seg 2)');
  });

  test('Track Editor (N) pieces are one track', () {
    expect(baseTrackName('Petros – Full Track (5)'), 'Petros – Full Track');
    expect(baseTrackName('Petros – Full Track (5) (seg 2)'),
        'Petros – Full Track');
    expect(renamedDisplayName('Petros – Full Track (5) (seg 2)', 'Petros'),
        'Petros (5) (seg 2)');
  });

  test('renames every piece of a split track, keeping each number', () {
    const gpx = '''<gpx xmlns="http://www.topografix.com/GPX/1/1">
  <trk><name>Petros Full (5)</name></trk>
  <trk><name>Petros Full (6)</name></trk>
  <trk><name>Francis (80)</name></trk>
</gpx>''';
    final r = renameTracksInGpx(gpx, oldBase: 'Petros Full', newBase: 'Petros');
    expect(r.renamed, 2);
    expect(r.gpx, contains('<name>Petros (5)</name>'));
    expect(r.gpx, contains('<name>Petros (6)</name>'));
    expect(r.gpx, contains('<name>Francis (80)</name>'));
  });

  test('file name fix', () {
    expect(
        renamedGpxFileName(
            'Track   01 Mar 2026   Jo Lomberd   Acme   12 fulltrack.gpx',
            'Jo Lomberd',
            'Jo Lombard'),
        'Track   01 Mar 2026   Jo Lombard   Acme   12 fulltrack.gpx');
    expect(
        renamedGpxFileName('Track 2.gpx', 'Jo Lomberd', 'Jo Lombard'), isNull);
  });
}
