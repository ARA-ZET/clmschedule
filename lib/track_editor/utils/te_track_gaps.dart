// track_editor/utils/te_track_gaps.dart
//
// Breaks tracks apart where the logger jumped. A GPS spike or a signal drop
// leaves two consecutive trackpoints far apart, and the map draws that as a
// long straight line across town that the distributor never walked.
import 'package:gpx/gpx.dart';

import 'te_track_analysis.dart';

/// Largest distance, in metres, allowed between two consecutive trackpoints
/// before the track is split there.
const double kTrackGapSplitM = 50;

/// Split every track in [tracks] wherever two consecutive trackpoints are
/// more than [maxGapM] apart, dropping the jump between them.
///
/// Pieces left with a single point are discarded: a lone point between two
/// jumps is the GPS spike itself. Tracks with no gap come back unchanged
/// (same instance). Segments within a track are flattened first, because
/// the map draws a track as one line across all its segments anyway.
List<Trk> splitTracksAtGaps(List<Trk> tracks,
    {double maxGapM = kTrackGapSplitM}) {
  final out = <Trk>[];
  for (final trk in tracks) {
    final pts = trk.trksegs
        .expand((seg) => seg.trkpts)
        .where((p) => p.lat != null && p.lon != null)
        .toList();

    final pieces = <List<Wpt>>[];
    var current = <Wpt>[];
    for (final p in pts) {
      if (current.isNotEmpty) {
        final prev = current.last;
        if (haversineM(prev.lat!, prev.lon!, p.lat!, p.lon!) > maxGapM) {
          pieces.add(current);
          current = <Wpt>[];
        }
      }
      current.add(p);
    }
    if (current.isNotEmpty) pieces.add(current);

    if (pieces.length <= 1) {
      out.add(trk);
      continue;
    }

    final kept = pieces.where((p) => p.length >= 2).toList();
    for (var i = 0; i < kept.length; i++) {
      final name = trk.name;
      out.add(Trk(
        name: kept.length == 1 || name == null ? name : '$name (${i + 1})',
        cmt: trk.cmt,
        desc: trk.desc,
        src: trk.src,
        number: trk.number,
        type: trk.type,
        trksegs: [Trkseg(trkpts: kept[i])],
      ));
    }
  }
  return out;
}

/// Bounds the Processing panel offers for [splitTracksAtGaps]'s threshold.
///
/// A distributor who drives between streets leaves legitimate 50–80 m steps
/// between trackpoints, which the 50 m default chops into a confetti of tiny
/// segments; raising the distance stitches those back together. Below 20 m
/// ordinary walking pace starts splitting, above 100 m real GPS jumps survive.
const double kTrackGapSplitMinM = 20;
const double kTrackGapSplitMaxM = 100;
const double kTrackGapSplitStepM = 10;

/// Number of slider stops between [kTrackGapSplitMinM] and [kTrackGapSplitMaxM].
int get kTrackGapSplitDivisions =>
    ((kTrackGapSplitMaxM - kTrackGapSplitMinM) / kTrackGapSplitStepM).round();

/// Split like [splitTracksAtGaps], but never hand back a track that is still
/// part of [source].
///
/// A processing tab keeps its unsplit tracks so the user can re-split them at
/// a different distance later. [splitTracksAtGaps] returns a gap-free track as
/// the *same* instance, so renaming it in the editor would quietly rewrite
/// that pristine copy and the next re-split would come out renamed too.
///
/// Trackpoints themselves stay shared: dragging a point is a real edit to the
/// round and should survive a re-split. Only the objects around them are new.
List<Trk> splitTracksAtGapsDetached(List<Trk> source, double maxGapM) =>
    splitTracksAtGaps(source, maxGapM: maxGapM).map(_detach).toList();

Trk _detach(Trk t) => Trk(
      name: t.name,
      cmt: t.cmt,
      desc: t.desc,
      src: t.src,
      links: [...t.links],
      number: t.number,
      type: t.type,
      extensions: {...t.extensions},
      trksegs: [for (final s in t.trksegs) Trkseg(trkpts: [...s.trkpts])],
    );
