// TEMode.report is a new enum value, and every per-mode provider
// (tabs/tracks/waypoints/files/map-layer) indexes a hardcoded
// Map<TEMode, ...> with `!`. Report mode's own panel never reads those
// providers — but applyTrackEditorMode still calls .setActiveMode(report)
// on all of them on every mode switch (it's the single generic hook every
// mode goes through), and a stray read afterwards (a keyboard shortcut
// handler, a future widget) would hit the map with the new key. Each of
// those 5 maps needed a TEMode.report entry added; this is the regression
// test for that, exercised directly rather than through the full page (which
// drags in Processing/Import's own unrelated Firebase and layout needs).
import 'dart:io';

import 'package:clmschedule/track_editor/pages/te_report_preview_page.dart';
import 'package:clmschedule/track_editor/pages/track_editor_page.dart';
import 'package:clmschedule/track_editor/providers/te_files_provider.dart';
import 'package:clmschedule/track_editor/providers/te_map_layer_provider.dart';
import 'package:clmschedule/track_editor/providers/te_mode_provider.dart';
import 'package:clmschedule/track_editor/providers/te_tabs_provider.dart';
import 'package:clmschedule/track_editor/providers/te_tracks_provider.dart';
import 'package:clmschedule/track_editor/providers/te_waypoints_provider.dart';
import 'package:clmschedule/track_editor/widgets/te_report_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every per-mode provider has a TEMode.report bucket', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    applyTrackEditorMode(container, TEMode.report);

    // Each of these would throw `Null check operator used on a null value`
    // on the very first access if its map were missing the report key.
    expect(() => container.read(teTabsRiverpod).tabs, returnsNormally);
    expect(() => container.read(teTabsRiverpod).currentTab, returnsNormally);
    expect(() => container.read(teTracksRiverpod).tracks, returnsNormally);
    expect(
        () => container.read(teWaypointsRiverpod).waypoints, returnsNormally);
    expect(() => container.read(teFilesRiverpod).selectedFileNames,
        returnsNormally);
    // The map-layer provider's per-mode state is private behind `_s`;
    // selectWaypoint is the simplest public entry point that forces the
    // same lookup.
    expect(() => container.read(teMapLayerRiverpod).selectWaypoint(0, null),
        returnsNormally);
  });

  test('switching processing -> report -> processing does not throw', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    applyTrackEditorMode(container, TEMode.processing);
    expect(
        () => applyTrackEditorMode(container, TEMode.report), returnsNormally);
    expect(() => container.read(teTabsRiverpod).tabs, returnsNormally);
    expect(() => applyTrackEditorMode(container, TEMode.processing),
        returnsNormally);
  });

  testWidgets(
      'report mode shows the report panel, not the map/analysis '
      'split or the tab bar', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(teModeRiverpod).setMode(TEMode.report);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: TrackEditorPage()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(TEReportPanel), findsOneWidget);
    expect(find.text('Client report'), findsOneWidget);
    expect(find.text('Choose folder'), findsOneWidget);
    // Report mode has no map/analysis pane and no open-tabs bar to switch
    // between GPX files — neither applies to a folder-wide scan.
    expect(find.byType(TEReportPreviewPage), findsNothing);
  });

  testWidgets(
      'report mode starts with a Choose folder prompt and no crash '
      'from an empty scan state', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(teModeRiverpod).setMode(TEMode.report);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: Scaffold(body: TrackEditorPage()),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Pick a Storage folder'), findsOneWidget);
    // Nothing scanned yet, so none of the results sections should render.
    expect(find.text('Whole team'), findsNothing);
    expect(find.text('Generate PDF'), findsNothing);
  });

  test('the app bar no longer offers Import or Trim, but does offer Report',
      () {
    // The app bar (in track_editor_screen.dart) needs a live Firebase app
    // to mount at all — TrackEditorPage's own Processing-mode panel reads
    // the schedule provider eagerly, well below what this check needs.
    // Reading the source directly is the simplest thing that can't lie
    // about which buttons are actually wired in.
    final source = File('lib/track_editor/pages/track_editor_screen.dart')
        .readAsStringSync();
    expect(source.contains("label: 'Import'"), isFalse);
    expect(source.contains("label: 'Trim'"), isFalse);
    expect(source.contains("label: 'Report'"), isTrue);
    expect(source.contains('TEMode.report'), isTrue);
  });
}
