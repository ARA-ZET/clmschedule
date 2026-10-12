// Renaming a track that lives in a cloud tracks layer.
//
// A cloud tracks layer is rebuilt from the GPX files in its Storage folder
// (via `_compiled_tracks.json`), so a rename only sticks if it is written into
// the GPX file itself. The compiler (`parseGpxFile` in functions/index.js)
// names each compiled track from its `<trk>`/`<rte>`:
//
//  * `<name>` of the track, or `Track N` / `Route N` (1-based) when it has none;
//  * plus ` (seg N)` when the `<trk>` has more than one `<trkseg>`.
//
// The Track Editor splits one distributor's day into several `<trk>`s named
// `… (5)`, `… (6)`, … in the same file. Those are one track too, so the
// ` (N)` ending is treated like ` (seg N)`: renaming one renames them all,
// each keeping its number.
//
// These helpers undo that mapping so the right `<name>`s get rewritten.
import 'package:xml/xml.dart';

/// The Track Editor's ` (N)` and the compiler's ` (seg N)`, in the order
/// they get appended.
final _pieceSuffix = RegExp(r'( \(\d+\))?( \(seg \d+\))?$');

/// The track a compiled track name is a piece of — [displayName] minus any
/// ` (N)` / ` (seg N)` ending.
String baseTrackName(String displayName) =>
    displayName.replaceFirst(_pieceSuffix, '');

/// [displayName] with its base swapped for [newBase], keeping any
/// ` (N)` / ` (seg N)` ending so the pieces still read as pieces.
String renamedDisplayName(String displayName, String newBase) {
  final suffix = _pieceSuffix.firstMatch(displayName)?.group(0) ?? '';
  return '$newBase$suffix';
}

/// Rewrites the `<name>` of every `<trk>` and `<rte>` in [gpx] whose
/// [baseTrackName] is [oldBase], to [newBase] plus its own ` (N)` ending.
///
/// Only the track/route's own `<name>` is touched — never waypoint or
/// metadata names — and the rest of the document is left as it was. Returns
/// the new document and how many tracks were renamed; zero means [gpx] has
/// no track by that name and should not be re-uploaded.
({String gpx, int renamed}) renameTracksInGpx(
  String gpx, {
  required String oldBase,
  required String newBase,
}) {
  final doc = XmlDocument.parse(gpx);
  final root = doc.rootElement;
  var renamed = 0;

  void renameAll(String tag, String unnamedPrefix) {
    final elements = root.childElements.where((e) => e.localName == tag);
    var index = 0;
    for (final el in elements) {
      index++;
      final nameEl =
          el.childElements.where((e) => e.localName == 'name').firstOrNull;
      final current = nameEl?.innerText.trim() ?? '';
      final shownAs = current.isNotEmpty ? current : '$unnamedPrefix $index';
      if (baseTrackName(shownAs) != oldBase) continue;

      if (nameEl != null) {
        nameEl.innerText = renamedDisplayName(current, newBase);
      } else {
        // GPX puts <name> first inside <trk>/<rte>.
        final ns = el.name.prefix;
        final created = XmlElement(
          XmlName('name', ns),
          const [],
          [XmlText(newBase)],
        );
        el.children.insert(0, created);
      }
      renamed++;
    }
  }

  renameAll('trk', 'Track');
  renameAll('rte', 'Route');
  return (gpx: doc.toXmlString(), renamed: renamed);
}

/// [fileName] with [oldBase] replaced by [newBase], or null when the file
/// name doesn't contain [oldBase] (nothing to fix there).
///
/// Saved track files carry the distributor's name
/// ("Track   01 Mar 2026   Jo Lombard   Client   12 fulltrack.gpx"), and the
/// Track Editor's report scanner reads the distributor back out of it, so a
/// misspelling in the file name matters as much as the one on the map.
String? renamedGpxFileName(String fileName, String oldBase, String newBase) {
  if (oldBase.isEmpty || !fileName.contains(oldBase)) return null;
  final renamed = fileName.replaceAll(oldBase, newBase);
  return renamed == fileName ? null : renamed;
}
