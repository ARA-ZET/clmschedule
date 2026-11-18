import 'dart:async';

import 'package:flutter/widgets.dart';

/// Shared tracker for job drags so the schedule grid can auto-scroll when the
/// pointer nears its edges.
///
/// Drag sources ([LongPressDraggable]s in the schedule cells and the
/// unfinished work areas panel) call [start]/[update]/[end]; the grid listens
/// to [activeDrags] and, while a drag is live, reads [pointerPosition] on a
/// timer to drive its scroll controllers. The timer is needed because a
/// pointer held still inside the edge zone produces no further drag updates,
/// yet scrolling should continue.
class GridDragAutoScroll {
  GridDragAutoScroll._();

  /// Number of live drags (effectively 0 or 1; a counter keeps mismatched
  /// start/end calls from wedging the state).
  static final ValueNotifier<int> activeDrags = ValueNotifier<int>(0);

  /// Last known global pointer position of the drag, null when none.
  static Offset? pointerPosition;

  static void start() => activeDrags.value = activeDrags.value + 1;

  static void update(Offset globalPosition) =>
      pointerPosition = globalPosition;

  static void end() {
    final next = activeDrags.value - 1;
    activeDrags.value = next < 0 ? 0 : next;
    if (activeDrags.value == 0) pointerPosition = null;
  }
}

/// Drives edge auto-scrolling of a scrollable viewport during drags tracked
/// by [GridDragAutoScroll].
///
/// Owned by the grid's State: create in initState, call [dispose] in dispose.
/// [viewportKey] must be attached to a widget covering the scrollable area;
/// [horizontal] and [vertical] are the controllers to move. Scroll speed
/// ramps up the deeper the pointer is into the [edgeSize] band, up to
/// [maxStepPerTick] px per 16 ms tick.
class EdgeAutoScroller {
  EdgeAutoScroller({
    required this.viewportKey,
    this.horizontal,
    this.vertical,
    this.edgeSize = 80.0,
    this.maxStepPerTick = 22.0,
  }) {
    GridDragAutoScroll.activeDrags.addListener(_onDragsChanged);
    _onDragsChanged();
  }

  final GlobalKey viewportKey;
  final ScrollController? horizontal;
  final ScrollController? vertical;
  final double edgeSize;
  final double maxStepPerTick;

  /// How far past the viewport bounds the pointer may wander (e.g. onto the
  /// pinned side panel or window chrome) while still counting as "near the
  /// edge" for the perpendicular axis.
  static const double _outsideSlack = 60.0;

  Timer? _timer;
  bool _disposed = false;

  void dispose() {
    _disposed = true;
    GridDragAutoScroll.activeDrags.removeListener(_onDragsChanged);
    _timer?.cancel();
    _timer = null;
  }

  void _onDragsChanged() {
    if (_disposed) return;
    final active = GridDragAutoScroll.activeDrags.value > 0;
    if (active && _timer == null) {
      _timer =
          Timer.periodic(const Duration(milliseconds: 16), (_) => _tick());
    } else if (!active) {
      _timer?.cancel();
      _timer = null;
    }
  }

  void _tick() {
    final pos = GridDragAutoScroll.pointerPosition;
    if (pos == null) return;
    final context = viewportKey.currentContext;
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return;

    final local = box.globalToLocal(pos);
    final size = box.size;

    final withinY =
        local.dy > -_outsideSlack && local.dy < size.height + _outsideSlack;
    final withinX =
        local.dx > -_outsideSlack && local.dx < size.width + _outsideSlack;

    if (withinY) {
      _scrollAxis(
        horizontal,
        position: local.dx,
        extent: size.width,
      );
    }
    if (withinX) {
      _scrollAxis(
        vertical,
        position: local.dy,
        extent: size.height,
      );
    }
  }

  void _scrollAxis(
    ScrollController? controller, {
    required double position,
    required double extent,
  }) {
    if (controller == null || !controller.hasClients) return;

    double delta = 0;
    if (position < edgeSize) {
      delta = -_step(edgeSize - position);
    } else if (position > extent - edgeSize) {
      delta = _step(position - (extent - edgeSize));
    }
    if (delta == 0) return;

    final p = controller.position;
    final target =
        (p.pixels + delta).clamp(p.minScrollExtent, p.maxScrollExtent);
    if (target != p.pixels) controller.jumpTo(target);
  }

  /// Speed ramps linearly with how deep into the edge band the pointer is;
  /// past the edge (negative positions) it saturates at full speed.
  double _step(double depthIntoEdge) {
    final t = (depthIntoEdge / edgeSize).clamp(0.0, 1.0);
    return maxStepPerTick * t;
  }
}
