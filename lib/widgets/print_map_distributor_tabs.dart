import 'package:flutter/material.dart';

/// One tab in the Print Map top bar: a distributor's job on the same date.
class PrintMapTabItem {
  final String jobId;
  final String label;

  const PrintMapTabItem({required this.jobId, required this.label});
}

/// A single row of distributor tabs that fits the space it is given.
///
/// When the tabs are wider than that space, left and right arrows appear to
/// scroll them; each arrow is disabled at its end. The selected tab is kept
/// scrolled into view.
class PrintMapDistributorTabs extends StatefulWidget {
  final List<PrintMapTabItem> tabs;
  final String selectedJobId;
  final ValueChanged<String>? onSelected;

  const PrintMapDistributorTabs({
    super.key,
    required this.tabs,
    required this.selectedJobId,
    this.onSelected,
  });

  @override
  State<PrintMapDistributorTabs> createState() =>
      _PrintMapDistributorTabsState();
}

class _PrintMapDistributorTabsState extends State<PrintMapDistributorTabs> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _tabKeys = {};
  final GlobalKey _viewportKey = GlobalKey();
  bool _canScrollLeft = false;
  bool _canScrollRight = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateArrows);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateArrows();
      _revealSelected(animate: false);
    });
  }

  @override
  void didUpdateWidget(covariant PrintMapDistributorTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedJobId != widget.selectedJobId) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _revealSelected());
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _updateArrows() {
    if (!mounted || !_scroll.hasClients) return;
    final position = _scroll.position;
    final left = position.pixels > 0.5;
    final right = position.pixels < position.maxScrollExtent - 0.5;
    if (left != _canScrollLeft || right != _canScrollRight) {
      final wasOverflowing = _canScrollLeft || _canScrollRight;
      setState(() {
        _canScrollLeft = left;
        _canScrollRight = right;
      });
      // The arrows coming or going resizes the strip; keep the selected
      // tab in view.
      if (wasOverflowing != (left || right)) {
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _revealSelected(animate: false));
      }
    }
  }

  /// Centres the selected tab in the strip, when the strip can scroll.
  void _revealSelected({bool animate = true}) {
    if (!mounted || !_scroll.hasClients) return;
    final tabBox =
        _tabKeys[widget.selectedJobId]?.currentContext?.findRenderObject();
    final viewportBox = _viewportKey.currentContext?.findRenderObject();
    if (tabBox is! RenderBox || viewportBox is! RenderBox) return;
    final position = _scroll.position;
    // The tab's left edge within the scrolled content.
    final tabLeft = tabBox.localToGlobal(Offset.zero).dx -
        viewportBox.localToGlobal(Offset.zero).dx +
        position.pixels;
    final target =
        (tabLeft + tabBox.size.width / 2 - viewportBox.size.width / 2)
            .clamp(0.0, position.maxScrollExtent);
    if ((target - position.pixels).abs() < 1) return;
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  void _scrollBy(double direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target = (position.pixels + direction * position.viewportDimension * 0.8)
        .clamp(0.0, position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final keepIds = widget.tabs.map((t) => t.jobId).toSet();
    _tabKeys.removeWhere((id, _) => !keepIds.contains(id));

    // Show the arrows only while the tabs overflow.
    final overflowing = _canScrollLeft || _canScrollRight;

    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _updateArrows());
        return false;
      },
      child: Row(
        children: [
          if (overflowing)
            IconButton(
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Earlier distributors',
              visualDensity: VisualDensity.compact,
              onPressed: _canScrollLeft ? () => _scrollBy(-1) : null,
            ),
          Expanded(
            child: SingleChildScrollView(
              key: _viewportKey,
              controller: _scroll,
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final tab in widget.tabs)
                    Padding(
                      key: _tabKeys.putIfAbsent(tab.jobId, GlobalKey.new),
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: ChoiceChip(
                        label: Text(tab.label),
                        selected: tab.jobId == widget.selectedJobId,
                        showCheckmark: false,
                        visualDensity: VisualDensity.compact,
                        onSelected: widget.onSelected == null
                            ? null
                            : (_) => widget.onSelected!(tab.jobId),
                      ),
                    ),
                ],
              ),
            ),
          ),
          if (overflowing)
            IconButton(
              icon: const Icon(Icons.chevron_right),
              tooltip: 'More distributors',
              visualDensity: VisualDensity.compact,
              onPressed: _canScrollRight ? () => _scrollBy(1) : null,
            ),
        ],
      ),
    );
  }
}
