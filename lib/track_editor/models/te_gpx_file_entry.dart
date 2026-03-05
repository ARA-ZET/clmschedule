// track_editor/models/te_gpx_file_entry.dart
import 'package:flutter/foundation.dart';
import 'package:gpx/gpx.dart';

/// Whether a GPX file contains a track or waypoints.
enum TEGpxFileType { track, waypoints, unknown }

/// One GPX file picked for processing.
///
/// Naming convention: `{Type} {rest...}.gpx`
/// where [matchKey] = everything after stripping the leading type word.
/// Two files are a pair when they share the same [matchKey].
class TEGpxFileEntry {
  final String filename;
  final TEGpxFileType type;

  /// The part of the filename used for pairing:
  ///   strip "Track " or "Waypoints " prefix + ".gpx" suffix → normalised lower.
  final String matchKey;

  /// Raw bytes (kept so we can re-parse / pass downstream).
  final Uint8List bytes;

  /// Parsed GPX data.
  final List<Trk> tracks;
  final List<Wpt> waypoints;

  const TEGpxFileEntry({
    required this.filename,
    required this.type,
    required this.matchKey,
    required this.bytes,
    required this.tracks,
    required this.waypoints,
  });

  /// Parse a GPX [bytes] blob and build a [TEGpxFileEntry].
  factory TEGpxFileEntry.parse(String filename, Uint8List bytes) {
    final lname = filename.toLowerCase();
    TEGpxFileType type;
    String stripped;

    if (lname.startsWith('track ')) {
      type = TEGpxFileType.track;
      stripped = filename.substring('track '.length);
    } else if (lname.startsWith('waypoints ')) {
      type = TEGpxFileType.waypoints;
      stripped = filename.substring('waypoints '.length);
    } else {
      type = TEGpxFileType.unknown;
      stripped = filename;
    }

    // Strip .gpx extension for a cleaner key
    final key = stripped
        .replaceAll(RegExp(r'\.gpx$', caseSensitive: false), '')
        .trim()
        .toLowerCase();

    List<Trk> tracks = [];
    List<Wpt> wpts = [];
    try {
      final xml = String.fromCharCodes(bytes);
      final gpx = GpxReader().fromString(xml);
      tracks = gpx.trks;
      wpts = gpx.wpts;
    } catch (e) {
      debugPrint('❌ TEGpxFileEntry: failed to parse $filename: $e');
    }

    return TEGpxFileEntry(
      filename: filename,
      type: type,
      matchKey: key,
      bytes: bytes,
      tracks: tracks,
      waypoints: wpts,
    );
  }

  /// Human-readable label derived from the match key. Capitalises each word.
  String get displayLabel {
    return matchKey
        .split(' ')
        .map((w) => w.isEmpty ? '' : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' ');
  }
}

/// A matched pair of track + waypoints files ready to open as one tab.
class TEGpxMatchedPair {
  final TEGpxFileEntry trackFile;
  final TEGpxFileEntry waypointsFile;
  final String matchKey;

  const TEGpxMatchedPair({
    required this.trackFile,
    required this.waypointsFile,
    required this.matchKey,
  });

  /// Filename format:  `{Type} {DD} {Mon} {YYYY} {DistributorName...} {WorkArea...} {Count}.gpx`
  /// matchKey is already lowercased with type + extension stripped.
  /// The date occupies the first 3 words (DD Mon YYYY), so word index 3 is
  /// the distributor first name. Capitalise it for the tab title.
  String get distributorName {
    final words = matchKey.trim().split(RegExp(r'\s+'));
    if (words.length > 3) {
      final name = words[3];
      return name[0].toUpperCase() + name.substring(1);
    }
    // Fallback — use full display label
    return displayLabel;
  }

  /// Full human-readable match-key label (every word capitalised).
  String get displayLabel => trackFile.displayLabel;

  /// Short tab title = distributor first name.
  String get tabTitle => distributorName;
}
