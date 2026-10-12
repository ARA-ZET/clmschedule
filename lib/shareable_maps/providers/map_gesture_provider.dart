import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Riverpod provider for MapGestureProvider.
final mapGestureRiverpod = riverpod.ChangeNotifierProvider<MapGestureProvider>(
    (ref) => MapGestureProvider());

/// Whether Google Maps on web may take pointer input.
///
/// On web the map is an HTML platform view under the Flutter canvas, so it
/// receives clicks and wheel events meant for Flutter UI drawn over it — info
/// windows, panels, dialogs, menus. The only fix that works is to switch the
/// map's own `webGestureHandling` to `none` while something is over it. Every
/// GoogleMap watches [gestureHandling]; nothing else should decide it.
///
/// Anything that needs the map off **holds** it with an object of its own and
/// releases with the same object. The map is free only when nobody holds it,
/// so overlapping holders — a panel under the pointer while a dialog opened
/// from it is up — can never switch it back on early. A single on/off flag
/// had exactly that bug.
///
/// Don't call [hold]/[release] by hand for UI: wrap inline overlays in
/// `MapOverlay`, and dialogs/menus/sheets are held automatically by
/// [MapModalGestureObserver].
class MapGestureProvider extends ChangeNotifier {
  final Set<Object> _holders = {};

  /// Current web gesture handling mode.
  WebGestureHandling get gestureHandling =>
      _holders.isEmpty ? WebGestureHandling.greedy : WebGestureHandling.none;

  /// True while UI is over the map (pointer on a panel, or a dialog/menu
  /// open). Google still fires `click` on the map and its shapes even with
  /// gesture handling off, so every map/shape `onTap` must bail when this is
  /// true — otherwise the click that pressed a dialog button also opens
  /// whatever lies beneath it.
  bool get isHeld => _holders.isNotEmpty;

  /// Turn the map's gestures off on behalf of [holder].
  void hold(Object holder) {
    final wasHeld = isHeld;
    _holders.add(holder);
    if (!wasHeld) notifyListeners();
  }

  /// Drop [holder]'s hold. The map comes back only when no holder remains.
  void release(Object holder) {
    if (!_holders.remove(holder)) return;
    if (!isHeld) notifyListeners();
  }

  @visibleForTesting
  int get holderCount => _holders.length;
}

/// Holds the map for as long as any popup route — dialog, popup menu,
/// dropdown, bottom sheet, date picker — is on screen, so none of them needs
/// its own gesture handling. Register on every Navigator that can show one
/// over a map.
///
/// The hold outlives the pop until the route's exit animation finishes. The
/// click that closes a dialog (a barrier tap, its Delete button) also reaches
/// the HTML map as a `click`; releasing at pop would let it land on the
/// polygon behind the dialog.
class MapModalGestureObserver extends NavigatorObserver {
  final MapGestureProvider gestures;

  MapModalGestureObserver(this.gestures);

  final Map<PopupRoute<dynamic>, void Function(AnimationStatus)> _exitListeners =
      {};

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) gestures.hold(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is! PopupRoute) return;
    final animation = route.animation;
    if (animation == null || animation.status == AnimationStatus.dismissed) {
      _release(route);
      return;
    }
    void onStatus(AnimationStatus status) {
      if (status == AnimationStatus.dismissed) _release(route);
    }

    _exitListeners[route] = onStatus;
    animation.addStatusListener(onStatus);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (route is PopupRoute) _release(route);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute is PopupRoute) _release(oldRoute);
    if (newRoute is PopupRoute) gestures.hold(newRoute);
  }

  void _release(PopupRoute<dynamic> route) {
    final listener = _exitListeners.remove(route);
    if (listener != null) route.animation?.removeStatusListener(listener);
    gestures.release(route);
  }
}

/// The app's root-navigator [MapModalGestureObserver]. An observer can belong
/// to only one Navigator, so a nested Navigator makes its own.
final mapModalObserverRiverpod = riverpod.Provider<MapModalGestureObserver>(
    (ref) => MapModalGestureObserver(ref.read(mapGestureRiverpod)));
