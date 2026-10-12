import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';

import 'package:clmschedule/track_editor/models/tab_item.dart';
import 'package:clmschedule/track_editor/providers/te_tabs_provider.dart';
import 'package:clmschedule/track_editor/utils/te_track_gaps.dart';

// Re-splitting a round at a different distance has to start from the file the
// tab was opened with: splitting drops the jumps, so a wider distance can
// never be recovered from the already-split tracks.
const base = -33.93;
const lon = 18.86;

Wpt pt(double lat) => Wpt(lat: lat, lon: lon);

/// Six points ~55 m apart — a distributor driving between streets.
Trk drivenRound() => Trk(name: 'Route', trksegs: [
      Trkseg(trkpts: [for (var i = 0; i < 6; i++) pt(base + i * 0.0005)])
    ]);

TETabsProvider providerWithDrivenTab() {
  final source = [drivenRound()];
  final provider = TETabsProvider();
  provider.addTab(TETabItem(
    title: 'Route',
    polygons: [],
    tracks: splitTracksAtGapsDetached(source, kTrackGapSplitM),
    waypoints: [],
    targetPolygons: [],
    sourceTracks: source,
  ));
  return provider;
}

void main() {
  test('widening the gap rebuilds the round from the original file', () {
    final provider = providerWithDrivenTab();
    final tabIndex = provider.tabs.length - 1;
    // At the 50 m default every step is a cut, so nothing survives.
    expect(provider.tabs[tabIndex].tracks, isEmpty);

    final previous = provider.setTrackGapSplit(tabIndex, 60);

    expect(previous, isEmpty);
    expect(provider.tabs[tabIndex].tracks, hasLength(1));
    expect(provider.tabs[tabIndex].tracks.single.trksegs.single.trkpts,
        hasLength(6));
    expect(provider.tabs[tabIndex].gapSplitM, 60);
  });

  test('the tab keeps the same tracks list so open panels stay in step', () {
    final provider = providerWithDrivenTab();
    final tabIndex = provider.tabs.length - 1;
    final held = provider.tabs[tabIndex].tracks;

    provider.setTrackGapSplit(tabIndex, 60);

    expect(identical(provider.tabs[tabIndex].tracks, held), isTrue);
    expect(held, hasLength(1));
  });

  test('narrowing again cuts the round back up', () {
    final provider = providerWithDrivenTab();
    final tabIndex = provider.tabs.length - 1;

    provider.setTrackGapSplit(tabIndex, 60);
    provider.setTrackGapSplit(tabIndex, kTrackGapSplitMinM);

    expect(provider.tabs[tabIndex].tracks, isEmpty);
    expect(provider.tabs[tabIndex].gapSplitM, kTrackGapSplitMinM);
  });

  test('undo puts the previous tracks and distance back', () {
    final provider = providerWithDrivenTab();
    final tabIndex = provider.tabs.length - 1;
    provider.setTrackGapSplit(tabIndex, 60);

    final before = List<Trk>.from(provider.tabs[tabIndex].tracks);
    final beforeGap = provider.tabs[tabIndex].gapSplitM;
    provider.setTrackGapSplit(tabIndex, 100);
    provider.restoreTracks(tabIndex, before, beforeGap);

    expect(provider.tabs[tabIndex].tracks, hasLength(1));
    expect(identical(provider.tabs[tabIndex].tracks.single, before.single),
        isTrue);
    expect(provider.tabs[tabIndex].gapSplitM, 60);
  });

  test('a tab without its original file is left alone', () {
    final provider = TETabsProvider();
    provider.addTab(TETabItem(
      title: 'From the cloud',
      polygons: [],
      tracks: [drivenRound()],
      waypoints: [],
      targetPolygons: [],
    ));
    final tabIndex = provider.tabs.length - 1;

    expect(provider.setTrackGapSplit(tabIndex, 100), isNull);
    expect(provider.tabs[tabIndex].tracks, hasLength(1));
    expect(provider.tabs[tabIndex].gapSplitM, kTrackGapSplitM);
  });
}
