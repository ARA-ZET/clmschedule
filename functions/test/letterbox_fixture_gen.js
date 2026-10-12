/**
 * Generates the cross-language fixture that guards the letterbox payload
 * format.
 *
 * The Cloud Function writes these payloads and the Flutter app reads them. If
 * the two encoders ever drift, the app decodes zero letterboxes and every
 * quote silently reads low — a failure with no error message. So the Node
 * encoder writes a fixture here, and a Dart test
 * (test/letterbox_node_payload_test.dart) decodes it and asserts the contents.
 *
 * Regenerate after any change to the payload shape, and bump FORMAT_VERSION in
 * BOTH lib/letterbox_index.js and lib/letterbox/services/letterbox_codec.dart:
 *
 *   node functions/test/letterbox_fixture_gen.js
 */

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const FORMAT_VERSION = 1;
const COORD_PRECISION = 6;

const round = (v) => Number(v.toFixed(COORD_PRECISION));

// Deliberately awkward values: southern/western hemisphere, a coordinate that
// needs rounding, and one that is already exact.
const POSITIONS = [
  { lat: -33.925001, lng: 18.425001 },
  { lat: -33.9260005, lng: 18.4260004 }, // rounds at the 6th decimal
  { lat: -33.927, lng: 18.427 },
  { lat: -33.928123, lng: 18.428987 },
];

function encode(suburbId, suburbName, positions) {
  const pts = [];
  for (const p of positions) {
    pts.push(round(p.lng), round(p.lat));
  }
  return zlib.gzipSync(
    Buffer.from(
      JSON.stringify({
        v: FORMAT_VERSION,
        suburbId,
        name: suburbName,
        count: positions.length,
        pts,
      }),
      "utf8"
    )
  );
}

const outDir = path.join(__dirname, "..", "..", "test", "fixtures");
fs.mkdirSync(outDir, { recursive: true });

const outFile = path.join(outDir, "letterbox_node_payload.json.gz");
fs.writeFileSync(outFile, encode("fixture_suburb", "Fixture Suburb", POSITIONS));

console.log(
  `Wrote ${outFile} (${fs.statSync(outFile).size} bytes, ` +
    `${POSITIONS.length} positions, format v${FORMAT_VERSION})`
);
