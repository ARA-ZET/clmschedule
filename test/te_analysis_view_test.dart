// Layout guards for the Track Editor's Analysis pane.
//
// No golden images here on purpose: the pane is almost entirely text and
// `flutter test` renders with a placeholder font, so a golden would lock in
// metrics the real app never uses. What is worth pinning down is that the
// pane survives the constraints the page actually hands it, at the widths a
// laptop and a wide monitor produce.
import 'package:clmschedule/track_editor/models/tab_item.dart';
import 'package:clmschedule/track_editor/providers/te_tabs_provider.dart';
import 'package:clmschedule/track_editor/providers/te_view_provider.dart';
import 'package:clmschedule/track_editor/widgets/te_analysis_chart.dart';
import 'package:clmschedule/track_editor/widgets/te_analysis_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpx/gpx.dart';

DateTime _at(int seconds) =>
    DateTime.utc(2026, 4, 14, 6, 0).add(Duration(seconds: seconds));

/// A lifelike round: 10 s sampling, four worked corners with a walk between
/// each, a lunch break and a logger dropout.
(Trk, List<Wpt>) buildRound() {
  const lon = 18.42;
  final pts = <Wpt>[];
  final wpts = <Wpt>[];
  var lat = -33.92;
  var sec = 0;

  void log(int seconds, double dLatPerStep) {
    for (var s = 0; s < seconds; s += 10) {
      lat += dLatPerStep;
      pts.add(Wpt(
        lat: lat + (sec % 3 - 1) * 0.00002,
        lon: lon + (sec % 5 - 2) * 0.00002,
        time: _at(sec),
      ));
      sec += 10;
    }
  }

  void work(int minutes, int handoutsPerMin) {
    final from = sec;
    log(minutes * 60, 0);
    for (var m = 0; m < minutes; m++) {
      for (var k = 0; k < handoutsPerMin; k++) {
        wpts.add(Wpt(lat: lat, lon: lon, time: _at(from + m * 60 + k * 12)));
      }
    }
  }

  log(8 * 60, 0.00017); // walk in at ~6 km/h
  work(45, 3); // corner 1
  log(6 * 60, 0.00017);
  work(35, 2); // corner 2
  log(4 * 60, 0.00017);
  log(28 * 60, 0); // lunch — stationary, nothing handed out
  log(5 * 60, 0.00017);
  work(50, 4); // corner 3, peak hour
  sec += 9 * 60; // logger dropout
  lat += 0.004;
  log(3 * 60, 0.00017);
  work(20, 1); // corner 4, winding down
  log(7 * 60, 0.00017); // walk out

  return (Trk(trksegs: [Trkseg(trkpts: pts)]), wpts);
}

/// The other kind of device: it writes a point every 10 s while the
/// distributor walks and NOTHING at all while they stand at an intersection,
/// so each stop arrives as a single long silence rather than as trackpoints.
(Trk, List<Wpt>) buildMotionTriggeredRound() {
  const lon = 18.42;
  final pts = <Wpt>[];
  final wpts = <Wpt>[];
  var lat = -33.92;
  var sec = 0;

  void walk(int minutes) {
    for (var s = 0; s < minutes * 60; s += 10) {
      lat += 0.00017;
      pts.add(Wpt(lat: lat, lon: lon, time: _at(sec)));
      sec += 10;
    }
  }

  void stand(int minutes, int handouts) {
    final from = sec;
    for (var k = 0; k < handouts; k++) {
      wpts.add(Wpt(
          lat: lat, lon: lon, time: _at(from + k * minutes * 60 ~/ handouts)));
    }
    sec += minutes * 60;
    lat += 0.00006; // a few metres of drift by the time it wakes up
    pts.add(Wpt(lat: lat, lon: lon, time: _at(sec)));
    sec += 10;
  }

  walk(7);
  stand(48, 141);
  walk(6);
  stand(37, 74);
  walk(4);
  stand(31, 1); // a near-empty stretch: one press in half an hour
  walk(5);
  stand(52, 205);
  walk(8);
  return (Trk(trksegs: [Trkseg(trkpts: pts)]), wpts);
}

ProviderContainer _containerWith(TETabItem tab, {bool analysis = true}) {
  final c = ProviderContainer();
  c.read(teTabsRiverpod)
    ..addTab(tab)
    ..selectTab(1);
  if (analysis) c.read(teViewRiverpod).setView(TEPaneView.analysis);
  return c;
}

TETabItem _tabWithRound({bool motionTriggered = false}) {
  final (trk, wpts) =
      motionTriggered ? buildMotionTriggeredRound() : buildRound();
  return TETabItem(
    title: 'Route 3 — Mon 14 Apr',
    polygons: const [],
    tracks: [trk],
    waypoints: wpts,
    targetPolygons: const [],
  );
}

/// Reproduces the page's own constraint shape: the pane is an `IndexedStack`
/// in a `Row` that aligns to the top, so it is handed LOOSE height.
Widget _pane(ProviderContainer c) => UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        home: Scaffold(
          body: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 200),
              Expanded(
                child: IndexedStack(
                  sizing: StackFit.expand,
                  index: 1,
                  children: [SizedBox.shrink(), TEAnalysisView()],
                ),
              ),
            ],
          ),
        ),
      ),
    );

/// Tapping a row or a bar has to (a) look like it did something and (b) put
/// the chart back in front of the user, since reframing the time axis is
/// pointless if they are left parked over a table far below it.
void _tapFeedbackTests() {
  Future<void> pumpTall(WidgetTester tester, ProviderContainer c) async {
    // Tall but not the whole page, so there is real scrolling to undo.
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_pane(c));
    await tester.pumpAndSettle();
  }

  testWidgets('ink can actually be seen — the pane has its own Material',
      (tester) async {
    // The pane paints an opaque background over the Material further up the
    // tree, so without one of its own every splash renders behind it and
    // every row looks dead to the touch.
    await pumpTall(tester, _containerWith(_tabWithRound()));
    expect(
      find.descendant(
        of: find.byType(TEAnalysisView),
        matching: find.byType(Material),
      ),
      findsWidgets,
    );
  });

  testWidgets('tapping a row scrolls the chart back into view', (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpTall(tester, c);

    // Read the hours BEFORE scrolling: the chart is at the top of a lazy
    // ListView and is disposed once it leaves the viewport.
    final hours = tester
        .widget<TEAnalysisChart>(find.byType(TEAnalysisChart))
        .analysis
        .hourly;
    final target = hours[1];
    final rowLabel = '${target.hourStart.hour.toString().padLeft(2, '0')}:00–'
        '${target.hourEnd.hour.toString().padLeft(2, '0')}:00';

    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;

    // Scroll down the page to the hour-by-hour table — however far that
    // actually is. A fixed pixel count (or an assumption that the chart's
    // widget is disposed by then) would be brittle against how tall the
    // page above the hourly table happens to be; the two things that
    // matter are that scrolling really happened, and that the tap below
    // brings it back to zero.
    await tester.scrollUntilVisible(find.text(rowLabel), 300,
        scrollable: scrollable);
    expect(position.pixels, greaterThan(0));

    await tester.tap(find.text(rowLabel));
    await tester.pumpAndSettle();

    // Back at the top, with the chart on screen and reframed.
    expect(position.pixels, 0);
    final chart = tester.widget<TEAnalysisChart>(find.byType(TEAnalysisChart));
    expect(chart.viewEnd.difference(chart.viewStart),
        lessThan(chart.analysis.elapsed));
    expect(chart.viewStart.difference(target.from).abs(),
        lessThan(const Duration(seconds: 30)));
  });

  testWidgets('dragging the zoom slider does NOT yank the page around',
      (tester) async {
    // Only an explicit tap on a row or bar reframes-and-returns; the slider
    // sits under the chart already, so scrolling would be a jolt.
    final c = _containerWith(_tabWithRound());
    await pumpTall(tester, c);

    final scrollable = find.byType(Scrollable).first;
    final position = tester.state<ScrollableState>(scrollable).position;
    await tester.drag(scrollable, const Offset(0, -200));
    await tester.pumpAndSettle();
    final was = position.pixels;
    expect(was, greaterThan(0));

    await tester.drag(find.byType(RangeSlider), const Offset(60, 0));
    await tester.pumpAndSettle();
    expect(position.pixels, was);
  });

  testWidgets('the row you picked stays marked when you scroll back to it',
      (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpTall(tester, c);

    final hours = tester
        .widget<TEAnalysisChart>(find.byType(TEAnalysisChart))
        .analysis
        .hourly;
    final target = hours[1];
    final rowLabel = '${target.hourStart.hour.toString().padLeft(2, '0')}:00–'
        '${target.hourEnd.hour.toString().padLeft(2, '0')}:00';

    // The tint a focus row wears once the chart is framed on exactly it.
    final selectedTint = TEChartColors.speed.withValues(alpha: 0.13);
    int markedRows() => tester
        .widgetList<AnimatedContainer>(find.byType(AnimatedContainer))
        .where((w) => (w.decoration as BoxDecoration?)?.color == selectedTint)
        .length;

    Future<void> scrollToRow() => tester.scrollUntilVisible(
          find.text(rowLabel),
          300,
          scrollable: find.byType(Scrollable).first,
        );

    await scrollToRow();
    expect(markedRows(), 0, reason: 'nothing is framed yet');

    await tester.tap(find.text(rowLabel));
    await tester.pumpAndSettle();

    // Scroll back down: the row is still the one obviously picked.
    await scrollToRow();
    expect(markedRows(), 1);
  });
}

void main() {
  _tapFeedbackTests();
  _zoomTests();

  for (final size in const [Size(1440, 900), Size(1024, 720)]) {
    for (final motion in [false, true]) {
      testWidgets(
          'lays out cleanly at ${size.width.toInt()}px wide'
          '${motion ? ', motion-triggered log' : ''}', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
            _pane(_containerWith(_tabWithRound(motionTriggered: motion))));
        await tester.pumpAndSettle();

        // A RenderFlex overflow surfaces as a test exception, so this covers
        // both "did it build" and "did anything spill out of its row".
        expect(tester.takeException(), isNull);
        expect(find.byType(TEAnalysisChart), findsOneWidget);
      });
    }
  }

  // Tall enough that the pane's ListView builds the whole page — these two
  // assert on sections well below the fold, which a lazy list would skip.
  const wholePage = Size(1440, 3600);

  testWidgets('says so when the logger only records while moving',
      (tester) async {
    tester.view.physicalSize = wholePage;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
        _pane(_containerWith(_tabWithRound(motionTriggered: true))));
    await tester.pumpAndSettle();

    final a =
        tester.widget<TEAnalysisChart>(find.byType(TEAnalysisChart)).analysis;
    expect(a.isMotionTriggered, isTrue);
    expect(a.gaps, isEmpty, reason: 'standing still is not a hole in the data');
    // The banner is the client-facing summary's only mention of how the
    // device behaves — the detailed silence-by-silence evidence table that
    // used to sit below the fold was removed for the simplified report.
    expect(find.textContaining('Motion-triggered logger'), findsOneWidget);
  });

  testWidgets('a continuously-logging device is not labelled as one',
      (tester) async {
    tester.view.physicalSize = wholePage;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_pane(_containerWith(_tabWithRound())));
    await tester.pumpAndSettle();

    final a =
        tester.widget<TEAnalysisChart>(find.byType(TEAnalysisChart)).analysis;
    expect(a.isMotionTriggered, isFalse);
    expect(find.textContaining('Motion-triggered logger'), findsNothing);
  });

  testWidgets(
      'the simplified summary shows exactly the six client tiles, '
      'and the detailed sections are gone', (tester) async {
    tester.view.physicalSize = wholePage;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_pane(_containerWith(_tabWithRound())));
    await tester.pumpAndSettle();

    for (final label in [
      'Flyers handed out',
      'Distance walked',
      'Shift length',
      'Handouts / working hour',
      'Break and lunch',
      'Best hour',
    ]) {
      expect(find.text(label), findsOneWidget, reason: '"$label" tile');
    }

    // Removed for the simplified client report — the deep-dive tables.
    for (final gone in [
      'Stops',
      'Between trackpoints',
      'Every silence worth explaining',
      'Where the flyers went',
      'Holes in the tracklog',
    ]) {
      expect(find.text(gone), findsNothing, reason: '"$gone" should be gone');
    }

    // What's left still works: the chart, the zoom bar, the time split, the
    // rate histogram and the hourly table are all untouched by this change.
    expect(find.byType(TEAnalysisChart), findsOneWidget);
    expect(find.text('Where the shift went'), findsOneWidget);
    expect(find.text('Hour by hour'), findsOneWidget);
    expect(find.textContaining('Handouts per'), findsOneWidget);
  });

  testWidgets('both chart layouts render', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final c = _containerWith(_tabWithRound());
    await tester.pumpWidget(_pane(c));
    await tester.pumpAndSettle();
    expect(c.read(teViewRiverpod).overlaySeries, isTrue);

    c.read(teViewRiverpod).setOverlaySeries(false);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TEAnalysisChart), findsOneWidget);
  });

  testWidgets('an empty tab shows the empty state, not a broken chart',
      (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final c = _containerWith(TETabItem(
      title: 'Untitled',
      polygons: const [],
      tracks: const [],
      waypoints: const [],
      targetPolygons: const [],
    ));
    await tester.pumpWidget(_pane(c));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(TEAnalysisChart), findsNothing);
    expect(find.textContaining('Nothing to analyse'), findsOneWidget);
  });

  testWidgets('does no work while the map view is showing', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final c = _containerWith(_tabWithRound(), analysis: false);
    await tester.pumpWidget(_pane(c));
    await tester.pumpAndSettle();
    expect(find.byType(TEAnalysisChart), findsNothing);

    c.read(teViewRiverpod).setView(TEPaneView.analysis);
    await tester.pumpAndSettle();
    expect(find.byType(TEAnalysisChart), findsOneWidget);
  });
}

/// The time-window controls. These drive the chart's axis only — the analysis
/// itself is never recomputed — so the assertions read the window straight off
/// the [TEAnalysisChart] the pane is currently showing.
void _zoomTests() {
  TEAnalysisChart chartOf(WidgetTester tester) =>
      tester.widget<TEAnalysisChart>(find.byType(TEAnalysisChart));

  Future<void> pumpPane(WidgetTester tester, ProviderContainer c) async {
    tester.view.physicalSize = const Size(1440, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_pane(c));
    await tester.pumpAndSettle();
  }

  testWidgets('opens showing the whole shift', (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpPane(tester, c);
    final chart = chartOf(tester);
    expect(chart.viewStart, chart.analysis.start);
    expect(chart.viewEnd, chart.analysis.end);
  });

  testWidgets('an hour chip frames exactly that clock hour', (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpPane(tester, c);
    final hours = chartOf(tester).analysis.hourly;
    // Pick a whole hour in the middle, not a partial one at either end.
    final target = hours.firstWhere((h) => !h.isPartial && h != hours.first);
    final label = target.hourStart.hour.toString().padLeft(2, '0');

    await tester.tap(find.text(label).first);
    await tester.pumpAndSettle();

    final chart = chartOf(tester);
    expect(chart.viewStart.difference(target.from).abs(),
        lessThan(const Duration(seconds: 30)));
    expect(chart.viewEnd.difference(target.to).abs(),
        lessThan(const Duration(seconds: 30)));
    // Narrowing the axis must not re-run the analysis.
    expect(identical(chart.analysis, chartOf(tester).analysis), isTrue);
  });

  testWidgets('tapping an hourly row zooms the chart onto it', (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpPane(tester, c);
    final hours = chartOf(tester).analysis.hourly;
    final target = hours[1];
    final rowLabel = '${target.hourStart.hour.toString().padLeft(2, '0')}:00–'
        '${target.hourEnd.hour.toString().padLeft(2, '0')}:00';

    await tester.tap(find.text(rowLabel));
    await tester.pumpAndSettle();

    final chart = chartOf(tester);
    expect(chart.viewEnd.difference(chart.viewStart),
        lessThan(chart.analysis.elapsed));
    expect(chart.viewStart.difference(target.from).abs(),
        lessThan(const Duration(seconds: 30)));
  });

  testWidgets('zoom out and reset widen the window again', (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpPane(tester, c);
    final full = chartOf(tester).analysis.elapsed;

    await tester.tap(find.text('09').first);
    await tester.pumpAndSettle();
    final zoomed = chartOf(tester);
    expect(zoomed.viewEnd.difference(zoomed.viewStart), lessThan(full));

    await tester.tap(find.byTooltip('Zoom out'));
    await tester.pumpAndSettle();
    final wider = chartOf(tester);
    expect(wider.viewEnd.difference(wider.viewStart),
        greaterThan(zoomed.viewEnd.difference(zoomed.viewStart)));

    await tester.tap(find.byTooltip('Whole shift'));
    await tester.pumpAndSettle();
    expect(chartOf(tester).viewStart, chartOf(tester).analysis.start);
    expect(chartOf(tester).viewEnd, chartOf(tester).analysis.end);
  });

  testWidgets('panning slides the window without resizing it', (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpPane(tester, c);
    await tester.tap(find.text('09').first);
    await tester.pumpAndSettle();
    final before = chartOf(tester);
    final width = before.viewEnd.difference(before.viewStart);

    // Drag left = move forward in time, like pulling a strip of film.
    await tester.drag(find.byType(TEAnalysisChart), const Offset(-120, 0));
    await tester.pumpAndSettle();

    final after = chartOf(tester);
    expect(after.viewEnd.difference(after.viewStart), width);
    expect(after.viewStart.isAfter(before.viewStart), isTrue);
  });

  testWidgets('the window never runs off either end of the shift',
      (tester) async {
    final c = _containerWith(_tabWithRound());
    await pumpPane(tester, c);
    await tester.tap(find.text('08').first);
    await tester.pumpAndSettle();

    // Shove it hard past the start; it should stop at the start.
    await tester.drag(find.byType(TEAnalysisChart), const Offset(4000, 0));
    await tester.pumpAndSettle();
    var chart = chartOf(tester);
    expect(chart.viewStart, chart.analysis.start);

    // And hard past the end.
    await tester.drag(find.byType(TEAnalysisChart), const Offset(-8000, 0));
    await tester.pumpAndSettle();
    chart = chartOf(tester);
    expect(chart.viewEnd.difference(chart.analysis.end).abs(),
        lessThan(const Duration(seconds: 30)));
  });
}
