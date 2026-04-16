const admin = require('firebase-admin');
admin.initializeApp({ storageBucket: 'clmschedule.firebasestorage.app' });
const { XMLParser } = require('fast-xml-parser');

const bucket = admin.storage().bucket();
const folderPath = process.argv[2] || 'Distribution/2026/Mar 2026/Jo Lombard';

function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a = Math.sin(dLat / 2) ** 2 + Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

(async () => {
  try {
    const [files] = await bucket.getFiles({ prefix: folderPath + '/' });
    const gpxFiles = files.filter((f) => f.name.toLowerCase().endsWith('.gpx'));
    console.log('Found', gpxFiles.length, 'GPX files in', folderPath);

    if (gpxFiles.length === 0) {
      console.log('No GPX files. All files in folder:');
      files.forEach((f) => console.log('  ', f.name));
      process.exit(0);
    }

    const tracks = [];
    const waypoints = [];
    const parser = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '@_' });

    for (const file of gpxFiles) {
      const [buf] = await file.download();
      const xml = buf.toString('utf-8');
      const parsed = parser.parse(xml);
      const gpx = parsed.gpx;
      if (!gpx) continue;

      // Extract tracks
      const trks = gpx.trk ? (Array.isArray(gpx.trk) ? gpx.trk : [gpx.trk]) : [];
      for (const trk of trks) {
        const segs = trk.trkseg ? (Array.isArray(trk.trkseg) ? trk.trkseg : [trk.trkseg]) : [];
        const points = [];
        const times = [];
        for (const seg of segs) {
          const pts = seg.trkpt ? (Array.isArray(seg.trkpt) ? seg.trkpt : [seg.trkpt]) : [];
          for (const pt of pts) {
            points.push([parseFloat(pt['@_lat']), parseFloat(pt['@_lon'])]);
            if (pt.time) times.push(pt.time);
          }
        }
        if (points.length > 0) {
          let distanceMeters = 0;
          for (let i = 1; i < points.length; i++) {
            distanceMeters += haversine(points[i - 1][0], points[i - 1][1], points[i][0], points[i][1]);
          }
          const entry = {
            name: trk.name || file.name.split('/').pop(),
            points,
            distanceMeters: Math.round(distanceMeters),
          };
          if (times.length >= 2) {
            entry.startTime = times[0];
            entry.endTime = times[times.length - 1];
            const startMs = new Date(times[0]).getTime();
            const endMs = new Date(times[times.length - 1]).getTime();
            if (startMs && endMs) entry.durationMs = endMs - startMs;
          }
          tracks.push(entry);
        }
      }

      // Extract waypoints
      const wpts = gpx.wpt ? (Array.isArray(gpx.wpt) ? gpx.wpt : [gpx.wpt]) : [];
      for (const wpt of wpts) {
        waypoints.push({
          name: wpt.name || 'Waypoint',
          lat: parseFloat(wpt['@_lat']),
          lon: parseFloat(wpt['@_lon']),
        });
      }
    }

    console.log('Compiled', tracks.length, 'tracks,', waypoints.length, 'waypoints');

    if (tracks.length > 0) {
      const tf = bucket.file(folderPath + '/_compiled_tracks.json');
      await tf.save(JSON.stringify({ tracks, compiledAt: new Date().toISOString() }), { contentType: 'application/json' });
      console.log('Uploaded _compiled_tracks.json');
    }
    if (waypoints.length > 0) {
      const wf = bucket.file(folderPath + '/_compiled_waypoints.json');
      await wf.save(JSON.stringify({ waypoints, compiledAt: new Date().toISOString() }), { contentType: 'application/json' });
      console.log('Uploaded _compiled_waypoints.json');
    }

    console.log('Done');
    process.exit(0);
  } catch (e) {
    console.error('Error:', e.message);
    process.exit(1);
  }
})();
