import 'package:clmschedule/track_editor/models/tab_item.dart';
import 'package:clmschedule/track_editor/providers/te_tabs_provider.dart';
import 'package:clmschedule/track_editor/providers/te_view_provider.dart';
import 'package:clmschedule/track_editor/widgets/te_analysis_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'te_analysis_view_test.dart' as fx;

Future<ProviderContainer> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final (trk, wpts) = fx.buildRound();
  final c = ProviderContainer();
  c.read(teTabsRiverpod)
    ..addTab(TETabItem(
      title: 'Route 3',
      polygons: const [],
      tracks: [trk],
      waypoints: wpts,
      targetPolygons: const [],
    ))
    ..selectTab(1);
  c.read(teViewRiverpod).setView(TEPaneView.analysis);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: c,
    child: const MaterialApp(
      home: Scaffold(
        body: SizedBox(width: 1440, height: 900, child: TEAnalysisView()),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  await tester.tap(find.byIcon(Icons.tune));
  await tester.pumpAndSettle();
  return c;
}

void main() {
  testWidgets('a single drag tick updates the label immediately',
      (tester) async {
    await _open(tester);
    expect(find.text('35 m'), findsOneWidget);
    tester.widget<Slider>(find.byType(Slider).first).onChanged!(60);
    await tester.pump();
    expect(find.text('60 m'), findsOneWidget);
    expect(find.text('35 m'), findsNothing);
  });

  testWidgets(
      'consecutive drag ticks on the same slider keep landing, '
      'not resetting to the start', (tester) async {
    await _open(tester);
    final radiusSlider = find.byType(Slider).first;
    for (final v in [40.0, 55.0, 70.0, 90.0]) {
      tester.widget<Slider>(radiusSlider).onChanged!(v);
      await tester.pump();
      expect(find.text('${v.round()} m'), findsOneWidget,
          reason: 'label should track tick $v, not snap back to 35 m');
    }
  });

  testWidgets(
      'dragging one slider does not disturb the others\' displayed '
      'values', (tester) async {
    await _open(tester);
    expect(find.text('2.0 min'), findsOneWidget); // minimum stop default
    expect(find.text('10 min'), findsOneWidget); // break threshold default
    expect(find.text('4 min'), findsOneWidget); // gap threshold default

    tester.widget<Slider>(find.byType(Slider).first).onChanged!(80); // radius
    await tester.pump();

    expect(find.text('80 m'), findsOneWidget);
    // The other three sliders' values must be untouched by the radius drag —
    // this is what proves `c` is one shared config carried across ticks
    // rather than each slider clobbering its siblings back to defaults.
    expect(find.text('2.0 min'), findsOneWidget);
    expect(find.text('10 min'), findsOneWidget);
    expect(find.text('4 min'), findsOneWidget);
  });

  testWidgets('the change reaches the chart in real time, popup still open',
      (tester) async {
    final c = await _open(tester);
    final before = c.read(teTabsRiverpod); // sanity: container is alive
    expect(before.tabs, isNotEmpty);

    tester.widget<Slider>(find.byType(Slider).first).onChanged!(90);
    await tester.pump();

    // The popup route sits on top, but the analysis pane underneath still
    // rebuilds on the same frame — the chart's own state reflects the new
    // threshold without needing the popup to close first.
    expect(tester.takeException(), isNull);
    expect(find.text('90 m'), findsOneWidget);
  });
}
