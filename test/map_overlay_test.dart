import 'package:clmschedule/shareable_maps/providers/map_gesture_provider.dart';
import 'package:clmschedule/shareable_maps/widgets/map_overlay.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:flutter_test/flutter_test.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Panels drawn over the Google Map must switch the map's gesture handling off
/// while the pointer is on them, and — critically — switch it back on in every
/// path out. A missed release leaves the map permanently unable to pan or zoom.
/// Dialogs, menus and sheets hold the map for their whole life through
/// [MapModalGestureObserver].
void main() {
  late riverpod.ProviderContainer container;

  setUp(() {
    container = riverpod.ProviderContainer();
  });

  tearDown(() => container.dispose());

  WebGestureHandling handling() =>
      container.read(mapGestureRiverpod).gestureHandling;
  bool overPolygon() => container.read(mapGestureRiverpod).isHeld;
  // ignore: invalid_use_of_visible_for_testing_member
  int held() => container.read(mapGestureRiverpod).holderCount;

  Future<void> pumpOverlays(WidgetTester tester, List<Widget> panels) {
    return tester.pumpWidget(
      riverpod.UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorObservers: [container.read(mapModalObserverRiverpod)],
          home: Scaffold(
            body: Stack(children: [
              const SizedBox.expand(),
              ...panels,
            ]),
          ),
        ),
      ),
    );
  }

  Widget panel(String label, {double top = 0}) => Positioned(
        left: 0,
        top: top,
        child: MapOverlay(
          child: SizedBox(width: 100, height: 40, child: Text(label)),
        ),
      );

  Future<TestGesture> hover(WidgetTester tester, Finder target) async {
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(500, 500));
    addTearDown(() => gesture.removePointer());
    await gesture.moveTo(tester.getCenter(target));
    await tester.pump();
    return gesture;
  }

  testWidgets('map starts free to receive gestures', (tester) async {
    await pumpOverlays(tester, [panel('a')]);
    expect(handling(), WebGestureHandling.greedy);
    expect(overPolygon(), isFalse);
  });

  testWidgets('pointer over a panel takes gestures off the map',
      (tester) async {
    await pumpOverlays(tester, [panel('a')]);
    await hover(tester, find.text('a'));

    expect(handling(), WebGestureHandling.none,
        reason: 'a scroll here must not zoom the map');
    expect(overPolygon(), isTrue,
        reason: 'polygon taps must be suppressed under the panel');
  });

  testWidgets('leaving the panel gives the map back', (tester) async {
    await pumpOverlays(tester, [panel('a')]);
    final gesture = await hover(tester, find.text('a'));

    await gesture.moveTo(const Offset(600, 600));
    await tester.pump();

    expect(handling(), WebGestureHandling.greedy);
    expect(overPolygon(), isFalse);
  });

  testWidgets(
      'a panel removed while hovered still gives the map back '
      '(onExit never fires in that case)', (tester) async {
    // The exact failure this widget exists to prevent: the "letterboxes
    // hidden" notice removes itself when its own Show button is pressed, and
    // the busy spinner vanishes when work finishes — both under the cursor.
    await pumpOverlays(tester, [panel('a')]);
    await hover(tester, find.text('a'));
    expect(handling(), WebGestureHandling.none);

    await pumpOverlays(tester, const []); // panel unmounts, pointer inside
    await tester.pump(); // let the deferred release run

    expect(handling(), WebGestureHandling.greedy,
        reason: 'otherwise the map is frozen for the rest of the session');
    expect(overPolygon(), isFalse);
  });

  testWidgets('overlapping panels only release on the last one',
      (tester) async {
    // Two stacked panels: leaving the upper one must not hand gestures back
    // while the pointer is still over the lower one.
    await pumpOverlays(tester, [
      Positioned(
        left: 0,
        top: 0,
        child: MapOverlay(
          child: SizedBox(
            width: 200,
            height: 200,
            child: Stack(children: [
              const SizedBox.expand(
                  child: ColoredBox(color: Color(0xFF0000FF))),
              Positioned(
                left: 0,
                top: 0,
                child: MapOverlay(
                  child: const SizedBox(
                    width: 60,
                    height: 60,
                    child: ColoredBox(
                        key: Key('over'),
                        color: Color(0xFF00FF00),
                        child: SizedBox.expand()),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);

    final gesture = await hover(tester, find.byKey(const Key('over')));
    expect(handling(), WebGestureHandling.none);

    // Move to the outer panel but stay inside it.
    await gesture.moveTo(const Offset(150, 150));
    await tester.pump();
    expect(handling(), WebGestureHandling.none,
        reason: 'still over the outer panel');

    // Now leave both.
    await gesture.moveTo(const Offset(600, 600));
    await tester.pump();
    expect(handling(), WebGestureHandling.greedy);
  });

  testWidgets('re-entering after a release works again', (tester) async {
    await pumpOverlays(tester, [panel('a')]);
    final gesture = await hover(tester, find.text('a'));
    await gesture.moveTo(const Offset(600, 600));
    await tester.pump();
    expect(handling(), WebGestureHandling.greedy);

    await gesture.moveTo(tester.getCenter(find.text('a')));
    await tester.pump();
    expect(handling(), WebGestureHandling.none);

    await gesture.moveTo(const Offset(600, 600));
    await tester.pump();
    expect(handling(), WebGestureHandling.greedy);
  });

  testWidgets('a panel that collapses to zero size while hovered releases',
      (tester) async {
    // The legend does exactly this: it stays mounted but returns
    // SizedBox.shrink() when the all-suburbs overlay is switched off. dispose()
    // never runs, so the release has to come from onExit firing when the hit
    // area vanishes underneath the pointer.
    Widget build({required bool visible}) => riverpod.UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: Scaffold(
              body: Stack(children: [
                const SizedBox.expand(),
                Positioned(
                  left: 0,
                  top: 0,
                  child: MapOverlay(
                    child: visible
                        ? const SizedBox(
                            width: 100, height: 40, child: Text('legend'))
                        : const SizedBox.shrink(),
                  ),
                ),
              ]),
            ),
          ),
        );

    await tester.pumpWidget(build(visible: true));
    await hover(tester, find.text('legend'));
    expect(handling(), WebGestureHandling.none);

    await tester.pumpWidget(build(visible: false));
    await tester.pump();

    expect(handling(), WebGestureHandling.greedy,
        reason: 'collapsing the panel must hand the map back');
    expect(held(), 0);
  });

  testWidgets('navigating away while hovered releases', (tester) async {
    // Route teardown is the other way a panel disappears under the cursor.
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      riverpod.UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          home: Scaffold(
            body: Stack(children: [
              const SizedBox.expand(),
              Positioned(
                left: 0,
                top: 0,
                child: MapOverlay(
                  child: const SizedBox(
                    width: 100,
                    height: 40,
                    child: ColoredBox(
                        key: Key('p'),
                        color: Color(0xFFFF0000),
                        child: SizedBox.expand()),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );

    await hover(tester, find.byKey(const Key('p')));
    expect(handling(), WebGestureHandling.none);

    navigator.currentState!.push(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('next'))),
    );
    await tester.pumpAndSettle();

    expect(handling(), WebGestureHandling.greedy);
    expect(held(), 0);
  });

  testWidgets('the pointer leaving the window releases', (tester) async {
    await pumpOverlays(tester, [panel('a')]);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(500, 500));
    await gesture.moveTo(tester.getCenter(find.text('a')));
    await tester.pump();
    expect(handling(), WebGestureHandling.none);

    await gesture.removePointer();
    await tester.pump();

    expect(handling(), WebGestureHandling.greedy,
        reason:
            'the cursor leaving the browser window must not freeze the map');
  });

  testWidgets('the held counter never drifts', (tester) async {
    // Drift would eventually pin the map either permanently off or
    // permanently on.
    await pumpOverlays(tester, [panel('a'), panel('b', top: 100)]);

    final gesture = await hover(tester, find.text('a'));
    await gesture.moveTo(tester.getCenter(find.text('b')));
    await tester.pump();
    await gesture.moveTo(const Offset(600, 600));
    await tester.pump();

    expect(held(), 0);
    expect(handling(), WebGestureHandling.greedy);
  });

  group('showMapDialog', () {
    testWidgets('a dialog over the map takes gestures off it', (tester) async {
      // Scrolling a long list in a dialog would otherwise zoom the map behind
      // it — the folder picker is exactly that shape.
      await pumpOverlays(tester, const []);
      final context = tester.element(find.byType(Scaffold));

      showMapDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('picker')),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.text('picker'));
      expect(handling(), WebGestureHandling.none);
    });

    testWidgets('closing a dialog under the cursor gives the map back',
        (tester) async {
      // Pressing a dialog's confirm button dismisses it with the pointer still
      // on it, so onExit never fires — the release has to come from dispose.
      await pumpOverlays(tester, const []);
      final context = tester.element(find.byType(Scaffold));

      showMapDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('picker'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Seed'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await hover(tester, find.text('Seed'));
      expect(handling(), WebGestureHandling.none);

      await tester.tap(find.text('Seed'));
      await tester.pumpAndSettle();

      expect(handling(), WebGestureHandling.greedy,
          reason: 'otherwise the map is frozen after every dialog');
      expect(held(), 0);
    });

    testWidgets('dismissing by barrier tap also releases', (tester) async {
      await pumpOverlays(tester, const []);
      final context = tester.element(find.byType(Scaffold));

      showMapDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('picker')),
      );
      await tester.pumpAndSettle();
      await hover(tester, find.text('picker'));
      expect(handling(), WebGestureHandling.none);

      // A corner, well clear of the centred dialog box.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(find.text('picker'), findsNothing,
          reason: 'the dialog must actually have closed for this to mean '
              'anything');

      expect(handling(), WebGestureHandling.greedy);
      expect(held(), 0);
    });
  });

  group('MapModalGestureObserver', () {
    testWidgets('a dialog holds the map as soon as it opens, before any hover',
        (tester) async {
      // A click on the barrier or on a button never hovers first on touch
      // screens, and a wheel event can arrive before the pointer has moved.
      await pumpOverlays(tester, const []);
      final context = tester.element(find.byType(Scaffold));

      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('confirm')),
      );
      await tester.pump();

      expect(handling(), WebGestureHandling.none);
      expect(overPolygon(), isTrue,
          reason: 'map and shape clicks must be ignored while it is open');
    });

    testWidgets('the hold outlasts the pop until the exit animation ends',
        (tester) async {
      // The click that closes a dialog also reaches the HTML map. Releasing
      // at pop would let it open whatever lies behind the dialog.
      await pumpOverlays(tester, const []);
      final context = tester.element(find.byType(Scaffold));

      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          content: const Text('confirm'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Delete'));
      await tester.pump(); // popped, exit animation just started
      expect(handling(), WebGestureHandling.none,
          reason: 'still held while the dialog animates out');

      await tester.pumpAndSettle();
      expect(handling(), WebGestureHandling.greedy);
      expect(held(), 0);
    });

    testWidgets('a popup menu holds and releases', (tester) async {
      await pumpOverlays(tester, const []);
      final context = tester.element(find.byType(Scaffold));

      showMenu<String>(
        context: context,
        position: const RelativeRect.fromLTRB(100, 100, 100, 100),
        items: const [PopupMenuItem(value: 'x', child: Text('Rename'))],
      );
      await tester.pumpAndSettle();
      expect(handling(), WebGestureHandling.none);

      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(handling(), WebGestureHandling.greedy);
      expect(held(), 0);
    });

    testWidgets(
        'closing a dialog opened from a hovered panel keeps the map held '
        'until the pointer leaves the panel too', (tester) async {
      // The old single flag got this wrong: whichever released first handed
      // the map back while the other still covered it.
      await pumpOverlays(tester, [panel('a')]);
      final gesture = await hover(tester, find.text('a'));
      final context = tester.element(find.byType(Scaffold));

      showDialog<void>(
        context: context,
        builder: (ctx) => const AlertDialog(content: Text('edit')),
      );
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('edit'))).pop();
      await tester.pumpAndSettle();

      await gesture.moveTo(tester.getCenter(find.text('a')));
      await tester.pump();
      expect(handling(), WebGestureHandling.none,
          reason: 'the pointer is still on the panel');

      await gesture.moveTo(const Offset(600, 600));
      await tester.pump();
      expect(handling(), WebGestureHandling.greedy);
      expect(held(), 0);
    });

    testWidgets('a page route does not hold the map', (tester) async {
      await pumpOverlays(tester, const []);
      final context = tester.element(find.byType(Scaffold));

      Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('page'))),
      );
      await tester.pumpAndSettle();
      expect(handling(), WebGestureHandling.greedy);
    });
  });
}
