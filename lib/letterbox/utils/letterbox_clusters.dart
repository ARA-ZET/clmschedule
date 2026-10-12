import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Split of a letterbox set into freestanding houses and apartment blocks.
class LetterboxBreakdown {
  /// Every letterbox, however it is grouped.
  final int total;

  /// Letterboxes standing on their own — a house with its own box at the gate.
  final int houses;

  /// Letterboxes that sit in a cluster: the bank of boxes at a block's
  /// entrance. This is a count of BOXES, not of blocks.
  final int apartmentBoxes;

  /// How many distinct clusters those boxes form.
  final int apartmentBlocks;

  const LetterboxBreakdown({
    required this.total,
    required this.houses,
    required this.apartmentBoxes,
    required this.apartmentBlocks,
  });

  static const empty = LetterboxBreakdown(
      total: 0, houses: 0, apartmentBoxes: 0, apartmentBlocks: 0);

  /// Average boxes per block, for a sanity read on the clustering.
  double get boxesPerBlock =>
      apartmentBlocks == 0 ? 0 : apartmentBoxes / apartmentBlocks;
}

/// One apartment block: where it is, and how many boxes are behind that door.
class LetterboxBlock {
  /// Centre of the boxes, so a single pin sits where the entrance is rather
  /// than on whichever box happened to be logged first.
  final LatLng centre;

  final int count;

  const LetterboxBlock({required this.centre, required this.count});
}

/// Letterboxes split into freestanding houses and apartment blocks.
class LetterboxGroups {
  final List<LatLng> houses;
  final List<LetterboxBlock> blocks;

  const LetterboxGroups({required this.houses, required this.blocks});

  static const empty = LetterboxGroups(houses: [], blocks: []);

  int get apartmentBoxes => blocks.fold(0, (sum, b) => sum + b.count);

  LetterboxBreakdown get breakdown => LetterboxBreakdown(
        total: houses.length + apartmentBoxes,
        houses: houses.length,
        apartmentBoxes: apartmentBoxes,
        apartmentBlocks: blocks.length,
      );
}

/// Grouping letterboxes that share a location.
///
/// Distribution records one waypoint per box delivered. At a freestanding house
/// that is a single point at the gate; at a block of flats it is a handful of
/// points at the entrance, one per box. So a tight cluster is not noise to be
/// removed — it *is* the apartment block, and its size is the number of boxes
/// in it.
///
/// That makes the houses-versus-flats split fall straight out of the geometry,
/// with no extra data to record — governed by two thresholds:
/// [clusterMetres], how close boxes must be to share an address, and
/// [minBlockBoxes], how many must share it before it counts as a block.
///
/// **What geometry cannot settle.** Two letterboxes 3 m apart might be a pair
/// of boxes at one door or two very narrow terraced houses; nothing in the
/// positions distinguishes them. [clusterMetres] is therefore a judgement
/// about the housing being measured, not a fact, and areas with unusually
/// tight frontages will be classified optimistically as blocks.
class LetterboxClusters {
  const LetterboxClusters._();

  /// Radius around a cluster's first point. Everything within it is taken to
  /// be the same address — the bank of boxes at one entrance.
  ///
  /// A cluster therefore spans at most twice this, which is what stops a
  /// street chaining into one giant "block": with single-linkage, houses 6 m
  /// apart each fell within 8 m of the next and twenty of them became one
  /// apartment block of twenty boxes.
  ///
  /// 5 m is chosen so that boxes logged at one doorway (typically within 1-2 m
  /// of each other) group, while houses on normal Cape Town frontages of 6 m
  /// and up stay separate. Terraces tighter than about 5 m cannot be told
  /// apart from a box bank by geometry alone — see the class doc.
  static const double clusterMetres = 5.0;

  /// How many boxes a cluster needs before it counts as an apartment block.
  ///
  /// Distance alone is not enough. Two or three boxes sharing a spot are
  /// usually a semi-detached pair, a duplex, or a granny flat behind a house —
  /// not a block — and treating every such pair as a block inflated the
  /// apartment figure badly. Five is the point at which a shared entrance
  /// stops being explicable as a couple of houses.
  ///
  /// Boxes in a cluster below this threshold are counted as freestanding
  /// letterboxes, so the total never changes — only how it is split.
  static const int minBlockBoxes = 5;

  /// Metres between two positions.
  ///
  /// Equirectangular approximation: within a centimetre of the great-circle
  /// result at these distances and far cheaper. Accounts for longitude
  /// converging at this latitude — 0.0001 degrees of longitude is ~9.2 m in
  /// Cape Town, not 11.1 m, and ignoring that would make the radius lopsided
  /// east to west.
  static double metresBetween(LatLng a, LatLng b) {
    const metresPerDegreeLat = 110574.0;
    const metresPerDegreeLngAtEquator = 111320.0;
    final meanLatRadians = (a.latitude + b.latitude) / 2 * math.pi / 180;
    final dy = (b.latitude - a.latitude) * metresPerDegreeLat;
    final dx = (b.longitude - a.longitude) *
        metresPerDegreeLngAtEquator *
        math.cos(meanLatRadians);
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Group [points] into clusters of co-located boxes.
  ///
  /// Leader clustering, NOT single-linkage. The first unassigned point seeds a
  /// cluster and everything within [metres] of *that point* joins it. Cluster
  /// extent is therefore bounded at 2x[metres].
  ///
  /// Single-linkage — where a point joins if it is near any existing member —
  /// chains: on a street of houses 6 m apart, every house is within 8 m of the
  /// next, so all twenty merged into a single 114 m "apartment block". Bounding
  /// the extent is what prevents that.
  ///
  /// Returns lists of indices into [points].
  static List<List<int>> cluster(
    List<LatLng> points, {
    double metres = clusterMetres,
  }) {
    if (points.isEmpty) return const [];

    // Bucket by cell so this does not compare every pair. Cell is larger than
    // the radius, so any point in range is in this cell or one of the eight
    // around it.
    final cellDegrees = (metres / 110574.0) * 1.5;
    final grid = <int, List<int>>{};
    int keyOf(int row, int col) => row * 1000000 + col;
    int rowOf(double lat) => (lat / cellDegrees).floor();
    int colOf(double lng) => (lng / cellDegrees).floor();

    for (var i = 0; i < points.length; i++) {
      (grid[keyOf(rowOf(points[i].latitude), colOf(points[i].longitude))] ??=
              [])
          .add(i);
    }

    final taken = List<bool>.filled(points.length, false);
    final clusters = <List<int>>[];

    for (var i = 0; i < points.length; i++) {
      if (taken[i]) continue;

      // This point leads the cluster; membership is measured against IT, not
      // against whichever member happens to be nearest. That bound is the
      // whole point — it is what a chain-forming rule lacks.
      final leader = points[i];
      final members = <int>[i];
      taken[i] = true;

      final row = rowOf(leader.latitude);
      final col = colOf(leader.longitude);
      for (var dr = -1; dr <= 1; dr++) {
        for (var dc = -1; dc <= 1; dc++) {
          final bucket = grid[keyOf(row + dr, col + dc)];
          if (bucket == null) continue;
          for (final j in bucket) {
            if (taken[j]) continue;
            if (metresBetween(leader, points[j]) <= metres) {
              taken[j] = true;
              members.add(j);
            }
          }
        }
      }

      members.sort();
      clusters.add(members);
    }

    return clusters;
  }

  /// Split [points] into freestanding houses and located apartment blocks.
  ///
  /// The blocks carry their centre so the map can show one pin per entrance
  /// with the box count on it, rather than a pile of indistinguishable markers.
  static LetterboxGroups group(
    List<LatLng> points, {
    double metres = clusterMetres,
    int minBlock = minBlockBoxes,
  }) {
    if (points.isEmpty) return LetterboxGroups.empty;

    final houses = <LatLng>[];
    final blocks = <LetterboxBlock>[];

    for (final members in cluster(points, metres: metres)) {
      // Below the threshold a cluster is a pair of houses sharing a spot, not
      // a block, so each box counts on its own.
      if (members.length < minBlock) {
        for (final i in members) {
          houses.add(points[i]);
        }
        continue;
      }
      var lat = 0.0, lng = 0.0;
      for (final i in members) {
        lat += points[i].latitude;
        lng += points[i].longitude;
      }
      blocks.add(LetterboxBlock(
        centre: LatLng(lat / members.length, lng / members.length),
        count: members.length,
      ));
    }

    return LetterboxGroups(houses: houses, blocks: blocks);
  }

  /// Houses-versus-flats split for [points].
  static LetterboxBreakdown breakdown(
    List<LatLng> points, {
    double metres = clusterMetres,
    int minBlock = minBlockBoxes,
  }) =>
      group(points, metres: metres, minBlock: minBlock).breakdown;
}
