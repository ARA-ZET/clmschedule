import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../providers/map_gesture_provider.dart';

/// Wraps a widget that sits on top of a Google Map. Every inline overlay over a
/// map — info windows, toolbars, panels, search bars — goes through this.
///
/// On web the map is an HTML platform view layered under the Flutter canvas and
/// consumes pointer events even where a Flutter widget is drawn over it —
/// scrolling a panel zooms the map. Wrapping the panel in a GestureDetector
/// does not help: the platform view receives the event independently. The fix
/// that works is to switch the map's own gesture handling off while the pointer
/// is over the panel ([MapGestureProvider]).
///
/// **Do not add PointerInterceptor here.** It renders an `HtmlElementView`,
/// which is another platform view, and each one splits the Flutter web scene
/// into a separate compositing layer. Stacking several over a map that is
/// already a platform view makes panning crawl.
///
/// Dialogs, menus and sheets don't need this: [MapModalGestureObserver] holds
/// the map for as long as one is open.
///
/// Two failure modes this exists to prevent, both of which leave the map
/// permanently frozen because gesture handling never gets switched back on:
///
///  * **Unmount while hovered.** `MouseRegion.onExit` does not fire when the
///    widget is removed from the tree with the pointer still inside it. Panels
///    are conditional — an info window closes from its own ✕, a busy spinner
///    disappears when work finishes, tool panels swap when the tool changes —
///    and all of that happens under the cursor. [dispose] therefore releases
///    the same way an exit would.
///  * **Overlapping panels.** Each overlay holds the map with its own identity,
///    so leaving one cannot re-enable the map while the pointer is still over
///    another, or while a dialog opened from it is up.
class MapOverlay extends riverpod.ConsumerStatefulWidget {
  final Widget child;

  const MapOverlay({super.key, required this.child});

  @override
  riverpod.ConsumerState<MapOverlay> createState() => _MapOverlayState();
}

class _MapOverlayState extends riverpod.ConsumerState<MapOverlay> {
  bool _inside = false;

  // Captured up front so [dispose] can still reach it: `ref` is not usable
  // once the element is being torn down.
  MapGestureProvider? _gestures;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _gestures = ref.read(mapGestureRiverpod);
  }

  void _acquire() {
    if (_inside) return;
    _inside = true;
    _gestures?.hold(this);
  }

  void _release({bool deferNotify = false}) {
    if (!_inside) return;
    _inside = false;

    final gestures = _gestures;
    if (deferNotify) {
      // Notifying listeners during dispose would rebuild mid-teardown, so the
      // release waits for the end of a frame.
      //
      // addPostFrameCallback does NOT request a frame of its own: if nothing
      // else schedules one, the callback simply never runs and the map stays
      // frozen. Dismissing a dialog by tapping its barrier is exactly that
      // case — nothing repaints afterwards. So ask for a frame explicitly.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        gestures?.release(this);
      });
      WidgetsBinding.instance.scheduleFrame();
    } else {
      gestures?.release(this);
    }
  }

  @override
  void dispose() {
    _release(deferNotify: true);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      // deferToChild, NOT the default opaque.
      //
      // An AlertDialog expands to fill the screen and centres its own content,
      // so an opaque MouseRegion around one becomes a full-screen hit target
      // that swallows the modal barrier's tap — leaving the dialog impossible
      // to dismiss by clicking outside it. Deferring means this region is only
      // hit where the child actually paints, which is also exactly when the
      // map should stop taking gestures.
      hitTestBehavior: HitTestBehavior.deferToChild,
      onEnter: (_) => _acquire(),
      onExit: (_) => _release(),
      child: widget.child,
    );
  }
}

/// [showDialog], kept as the name call sites over a map already use. The map
/// is held for the dialog's whole life by [MapModalGestureObserver], so no
/// wrapping is needed here.
Future<T?> showMapDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  return showDialog<T>(context: context, builder: builder);
}
