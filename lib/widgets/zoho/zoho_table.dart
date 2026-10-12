import 'package:flutter/material.dart';

/// Visual tokens matching the Zoho Books web UI: white surface, light grey
/// header, hairline borders, blue link text, dense rows.
class ZohoPalette {
  const ZohoPalette._();

  static const surface = Color(0xFFFFFFFF);
  static const pageBackground = Color(0xFFF5F6F8);
  static const headerBackground = Color(0xFFF4F6F8);
  static const border = Color(0xFFE3E7EB);

  /// The line under each row — darker than [border] so the eye can follow one
  /// row from left to right across a wide table.
  static const divider = Color(0xFFB9C2CB);
  static const rowHover = Color(0xFFF7FAFD);

  /// Width of the coloured strip on the left of a row given a [ZohoTable.rowAccent].
  static const accentWidth = 4.0;

  static const textPrimary = Color(0xFF2F3A45);
  static const textMuted = Color(0xFF7A8794);
  static const link = Color(0xFF2B7DE9);

  /// Zoho's row height — noticeably denser than a Material ListTile.
  static const rowHeight = 44.0;
  static const headerHeight = 40.0;
}

/// One column in a [ZohoTable].
class ZohoColumn {
  final String label;

  /// Fixed width, or the minimum width when [flexible] is true.
  final double width;

  /// Flexible columns absorb leftover horizontal space on wide viewports so
  /// the table fills the window instead of leaving a gap on the right.
  final bool flexible;

  final Alignment alignment;

  /// Whether clicking the header sorts by this column.
  final bool sortable;

  const ZohoColumn({
    required this.label,
    required this.width,
    this.flexible = false,
    this.alignment = Alignment.centerLeft,
    this.sortable = true,
  });
}

/// A dense, horizontally scrollable data table in the Zoho Books style.
///
/// Columns keep fixed widths so the table stays readable on narrow screens by
/// scrolling sideways — the same thing the Zoho web app does — while
/// [ZohoColumn.flexible] columns stretch to fill a wide window.
class ZohoTable extends StatelessWidget {
  final List<ZohoColumn> columns;
  final int rowCount;

  /// Builds the cells for one row. Must return exactly [columns].length
  /// widgets, in column order.
  final List<Widget> Function(BuildContext context, int index) rowBuilder;

  final void Function(int index)? onRowTap;

  /// Index of the column currently sorted on, or null when unsorted.
  final int? sortColumnIndex;
  final bool sortAscending;

  /// Called with the tapped column's index. Callers toggle direction when the
  /// same column is tapped again.
  final void Function(int columnIndex)? onSort;

  /// Called as the user nears the bottom, for lazy paging. Fires repeatedly,
  /// so the callback must be idempotent while a fetch is in flight.
  ///
  /// Also invoked by the explicit "Load more" footer button, which is the only
  /// route on a tall window: if every row fits, the list never scrolls and no
  /// ScrollNotification is ever dispatched.
  final VoidCallback? onEndReached;

  /// Renders a spinner row beneath the last row while the next page loads.
  final bool isLoadingMore;

  /// Whether more pages exist. Drives the "Load more" footer.
  final bool hasMore;

  /// Optional per-row colour — e.g. invoice status. The row gets a solid
  /// strip of it on the left and a faint tint across, so rows of the same
  /// kind read as a group and one row can be followed left to right.
  final Color? Function(int index)? rowAccent;

  const ZohoTable({
    super.key,
    required this.columns,
    required this.rowCount,
    required this.rowBuilder,
    this.onRowTap,
    this.sortColumnIndex,
    this.sortAscending = true,
    this.onSort,
    this.onEndReached,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.rowAccent,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // The accent strip sits outside the columns, so it is counted here or
        // the rows would overflow by its width.
        final accentWidth = rowAccent == null ? 0.0 : ZohoPalette.accentWidth;
        final totalFixed =
            columns.fold<double>(0, (sum, c) => sum + c.width) + accentWidth;
        final flexCount = columns.where((c) => c.flexible).length;

        // Give any leftover width to the flexible columns; below that, the
        // table scrolls horizontally rather than squashing.
        final leftover = constraints.maxWidth - totalFixed;
        final bonus =
            (flexCount > 0 && leftover > 0) ? leftover / flexCount : 0.0;

        final widths =
            columns.map((c) => c.flexible ? c.width + bonus : c.width).toList();
        final tableWidth =
            widths.fold<double>(0, (a, b) => a + b) + accentWidth;

        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SizedBox(
            width: tableWidth,
            child: Column(
              children: [
                _buildHeader(widths),
                Expanded(
                  child: NotificationListener<ScrollNotification>(
                    onNotification: (n) {
                      // Fire a page ahead of the actual bottom so the next
                      // rows are usually there before the user reaches them.
                      if (onEndReached != null &&
                          n.metrics.axis == Axis.vertical &&
                          n.metrics.extentAfter < 400) {
                        onEndReached!();
                      }
                      return false;
                    },
                    child: ListView.builder(
                      // One extra row for the footer: a spinner while paging,
                      // or a "Load more" button when more pages exist.
                      itemCount:
                          rowCount + ((isLoadingMore || hasMore) ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= rowCount) return _buildFooter();
                        return SizedBox(
                          height: ZohoPalette.rowHeight,
                          child: _buildRow(context, index, widths),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Spinner while a page is loading, otherwise an explicit "Load more".
  ///
  /// The button matters: when every loaded row fits on screen the list never
  /// scrolls, so the scroll-based trigger never fires and this is the only way
  /// to reach the next page.
  Widget _buildFooter() {
    return Container(
      height: 56,
      alignment: Alignment.center,
      decoration: const BoxDecoration(
        color: ZohoPalette.surface,
        border: Border(bottom: BorderSide(color: ZohoPalette.border)),
      ),
      child: isLoadingMore
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : TextButton.icon(
              onPressed: onEndReached,
              icon: const Icon(Icons.expand_more, size: 18),
              label: const Text('Load more'),
              style: TextButton.styleFrom(
                foregroundColor: ZohoPalette.link,
                textStyle:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ),
    );
  }

  Widget _buildHeader(List<double> widths) {
    return Container(
      height: ZohoPalette.headerHeight,
      decoration: BoxDecoration(
        color: ZohoPalette.headerBackground,
        border: Border(
          top: const BorderSide(color: ZohoPalette.border),
          bottom: const BorderSide(color: ZohoPalette.divider),
          // Matches the rows' accent strip so the columns stay aligned.
          left: rowAccent == null
              ? BorderSide.none
              : const BorderSide(
                  color: ZohoPalette.headerBackground,
                  width: ZohoPalette.accentWidth),
        ),
      ),
      child: Row(
        children: [
          for (var i = 0; i < columns.length; i++)
            _buildHeaderCell(i, widths[i]),
        ],
      ),
    );
  }

  Widget _buildHeaderCell(int index, double width) {
    return _HeaderCell(
      column: columns[index],
      width: width,
      isSorted: sortColumnIndex == index,
      sortAscending: sortAscending,
      onSort: (columns[index].sortable && onSort != null)
          ? () => onSort!(index)
          : null,
    );
  }

  Widget _buildRow(BuildContext context, int index, List<double> widths) {
    final cells = rowBuilder(context, index);
    assert(cells.length == columns.length,
        'rowBuilder must return one widget per column');

    // Each row is its own Material. It used to be an `Ink` painting onto the
    // nearest Material ancestor — the Scaffold — but the page's opaque grey
    // background sits between the two, so the row fill, its dividing line and
    // the status colour were all painted *underneath* it and never seen.
    //
    // The fill is the Material's colour, so the InkWell's hover paints on top
    // of it; the lines are drawn by a transparent Container over both.
    final accent = rowAccent?.call(index);
    return Material(
      color: accent == null
          ? ZohoPalette.surface
          : Color.alphaBlend(
              accent.withValues(alpha: 0.12), ZohoPalette.surface),
      child: InkWell(
        onTap: onRowTap == null ? null : () => onRowTap!(index),
        // An overlay, not a fixed colour, so a status-tinted row stays tinted.
        hoverColor: Colors.black.withValues(alpha: 0.04),
        // A row is a link to its detail screen; say so before it is clicked.
        mouseCursor: onRowTap == null
            ? SystemMouseCursors.basic
            : SystemMouseCursors.click,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              bottom: const BorderSide(color: ZohoPalette.divider, width: 1.5),
              left: rowAccent == null
                  ? BorderSide.none
                  : BorderSide(
                      color: accent ?? ZohoPalette.surface,
                      width: ZohoPalette.accentWidth),
            ),
          ),
          child: Row(
            children: [
              for (var i = 0; i < columns.length; i++)
                Container(
                  width: widths[i],
                  alignment: columns[i].alignment,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: cells[i],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One column header, which shows where sorting is available *before* it is
/// used.
///
/// Stateful only to track hover: previously the sort arrow appeared solely on
/// the already-sorted column, so nothing distinguished a sortable header from a
/// fixed one until after you had guessed correctly and clicked it.
class _HeaderCell extends StatefulWidget {
  final ZohoColumn column;
  final double width;
  final bool isSorted;
  final bool sortAscending;
  final VoidCallback? onSort;

  const _HeaderCell({
    required this.column,
    required this.width,
    required this.isSorted,
    required this.sortAscending,
    this.onSort,
  });

  @override
  State<_HeaderCell> createState() => _HeaderCellState();
}

class _HeaderCellState extends State<_HeaderCell> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final column = widget.column;
    final canSort = widget.onSort != null;
    final rightAligned = column.alignment == Alignment.centerRight;

    // Sorted: solid arrow in the sort direction. Hovered but not sorted: the
    // same arrow, faint, hinting what a click would do.
    final showArrow = widget.isSorted || (canSort && _hovered);
    final arrow = showArrow
        ? Icon(
            widget.sortAscending ? Icons.arrow_upward : Icons.arrow_downward,
            size: 12,
            color: widget.isSorted
                ? ZohoPalette.textPrimary
                : ZohoPalette.textMuted.withValues(alpha: 0.6),
          )
        : null;

    final label = Flexible(
      child: Text(
        column.label.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.4,
          // The active sort column darkens, the way Zoho highlights it.
          color: (widget.isSorted || (canSort && _hovered))
              ? ZohoPalette.textPrimary
              : ZohoPalette.textMuted,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );

    return SizedBox(
      width: widget.width,
      child: MouseRegion(
        cursor: canSort ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: canSort ? (_) => setState(() => _hovered = true) : null,
        onExit: canSort ? (_) => setState(() => _hovered = false) : null,
        child: GestureDetector(
          onTap: widget.onSort,
          behavior: HitTestBehavior.opaque,
          child: Container(
            alignment: column.alignment,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: rightAligned
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: [
                if (arrow != null && rightAligned) ...[
                  arrow,
                  const SizedBox(width: 4),
                ],
                label,
                if (arrow != null && !rightAligned) ...[
                  const SizedBox(width: 4),
                  arrow,
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Plain table text, at Zoho's density.
class ZohoCellText extends StatelessWidget {
  final String text;
  final bool muted;
  final bool strikeThrough;
  final FontWeight? weight;

  const ZohoCellText(
    this.text, {
    super.key,
    this.muted = false,
    this.strikeThrough = false,
    this.weight,
  });

  @override
  Widget build(BuildContext context) {
    return Text(
      text.isEmpty ? '—' : text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: muted ? ZohoPalette.textMuted : ZohoPalette.textPrimary,
        fontWeight: weight,
        decoration: strikeThrough ? TextDecoration.lineThrough : null,
      ),
    );
  }
}

/// The blue link styling Zoho uses for the primary identifier in each row
/// (invoice number, contact name).
class ZohoLinkText extends StatelessWidget {
  final String text;
  final bool strikeThrough;

  const ZohoLinkText(this.text, {super.key, this.strikeThrough = false});

  @override
  Widget build(BuildContext context) {
    return Text(
      text.isEmpty ? '—' : text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 13,
        color: ZohoPalette.link,
        fontWeight: FontWeight.w500,
        decoration: strikeThrough ? TextDecoration.lineThrough : null,
      ),
    );
  }
}

/// Toolbar across the top of a Zoho-style list screen: a filter control on the
/// left and actions on the right.
class ZohoToolbar extends StatelessWidget {
  final Widget leading;
  final List<Widget> actions;

  const ZohoToolbar(
      {super.key, required this.leading, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(
        color: ZohoPalette.surface,
        border: Border(bottom: BorderSide(color: ZohoPalette.border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          return Row(
            children: [
              Expanded(child: leading),
              // A Row lays out its non-flexible children at their natural
              // width, so a toolbar with a search field, two dropdowns and
              // three icon buttons overflows into the striped error banner on a
              // narrow window. Capping the actions and letting them scroll —
              // reversed, so the rightmost stay put — degrades instead.
              ConstrainedBox(
                constraints:
                    BoxConstraints(maxWidth: constraints.maxWidth * 0.8),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: actions,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Zoho's primary action button — "+ New" in toolbars, or a plain filled
/// button when [icon] is null (e.g. a dialog's Save).
class ZohoNewButton extends StatelessWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  const ZohoNewButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon = Icons.add,
  });

  @override
  Widget build(BuildContext context) {
    final style = FilledButton.styleFrom(
      backgroundColor: ZohoPalette.link,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
    );

    if (icon == null) {
      return FilledButton(
        onPressed: onPressed,
        style: style,
        child: Text(label),
      );
    }

    return FilledButton.icon(
      onPressed: onPressed,
      style: style,
      icon: Icon(icon, size: 16),
      label: Text(label),
    );
  }
}

/// Secondary filter dropdown for a Zoho toolbar — smaller and outlined,
/// distinct from the primary view selector on the left.
class ZohoFilterDropdown<T> extends StatelessWidget {
  final T value;

  /// Options in display order. Dart preserves Map insertion order.
  final Map<T, String> options;
  final ValueChanged<T>? onChanged;
  final IconData icon;

  const ZohoFilterDropdown({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icon = Icons.filter_list,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: ZohoPalette.surface,
        border: Border.all(color: ZohoPalette.border),
        borderRadius: BorderRadius.circular(4),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          onChanged: onChanged == null ? null : (v) => onChanged!(v as T),
          isDense: true,
          borderRadius: BorderRadius.circular(4),
          icon: const Icon(Icons.arrow_drop_down,
              size: 20, color: ZohoPalette.textMuted),
          style: const TextStyle(
            fontSize: 13,
            color: ZohoPalette.textPrimary,
          ),
          items: options.entries
              .map((e) => DropdownMenuItem<T>(
                    value: e.key,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, size: 14, color: ZohoPalette.textMuted),
                        const SizedBox(width: 6),
                        Text(e.value,
                            style: const TextStyle(
                                fontSize: 13, color: ZohoPalette.textPrimary)),
                      ],
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

/// Compact search field styled to sit in a Zoho toolbar.
class ZohoSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hintText;
  final ValueChanged<String> onChanged;
  final VoidCallback onClear;
  final bool showClear;

  const ZohoSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    required this.onChanged,
    required this.onClear,
    required this.showClear,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 34,
      width: 260,
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(fontSize: 13),
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle:
              const TextStyle(fontSize: 13, color: ZohoPalette.textMuted),
          prefixIcon:
              const Icon(Icons.search, size: 18, color: ZohoPalette.textMuted),
          prefixIconConstraints:
              const BoxConstraints(minWidth: 34, minHeight: 34),
          suffixIcon: showClear
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 16),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 30, minHeight: 30),
                  onPressed: onClear,
                )
              : null,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          filled: true,
          fillColor: ZohoPalette.surface,
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: ZohoPalette.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(4),
            borderSide: const BorderSide(color: ZohoPalette.link),
          ),
        ),
      ),
    );
  }
}
