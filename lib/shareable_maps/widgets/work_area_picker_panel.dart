import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../../models/work_area.dart';
import '../../models/work_suburb.dart';
import '../../providers/schedule_provider.dart';
import '../providers/shareable_map_provider.dart';

/// A floating panel that lists all work areas and suburbs from Firestore
/// and lets the user toggle them on/off to add as polygons to the map.
///
/// The panel has two collapsible layers — "Work Areas" and "Suburbs" —
/// each with an independent visibility toggle. The search field, Select
/// All, Deselect All and Lasso buttons all act on the currently visible
/// layer(s).
class WorkAreaPickerPanel extends riverpod.ConsumerStatefulWidget {
  /// Called when the user taps the close button.
  final VoidCallback onClose;

  const WorkAreaPickerPanel({super.key, required this.onClose});

  @override
  riverpod.ConsumerState<WorkAreaPickerPanel> createState() =>
      _WorkAreaPickerPanelState();
}

class _WorkAreaPickerPanelState
    extends riverpod.ConsumerState<WorkAreaPickerPanel> {
  String _searchQuery = '';
  bool _workAreasExpanded = true;
  bool _suburbsExpanded = true;

  @override
  Widget build(BuildContext context) {
    final scheduleProvider = ref.watch(scheduleRiverpod);
    final mapProvider = ref.watch(shareableMapRiverpod);
    final workAreas = scheduleProvider.workAreas;
    final suburbs = scheduleProvider.workSuburbs;

    final showWorkAreas = mapProvider.pickerWorkAreasVisible;
    final showSuburbs = mapProvider.pickerSuburbsVisible;

    // Filter by search
    final filteredWorkAreas = !showWorkAreas
        ? <WorkArea>[]
        : _searchQuery.isEmpty
            ? workAreas
            : workAreas.where((wa) {
                final q = _searchQuery.toLowerCase();
                return wa.name.toLowerCase().contains(q) ||
                    wa.description.toLowerCase().contains(q);
              }).toList();

    final filteredSuburbs = !showSuburbs
        ? <WorkSuburb>[]
        : _searchQuery.isEmpty
            ? suburbs
            : suburbs.where((s) {
                final q = _searchQuery.toLowerCase();
                return s.name.toLowerCase().contains(q) ||
                    s.description.toLowerCase().contains(q);
              }).toList();

    // Count imported from each visible layer
    final importedWorkAreaCount = showWorkAreas
        ? workAreas
            .where((wa) => mapProvider.isWorkAreaImported(wa.name))
            .length
        : 0;
    final importedSuburbCount = showSuburbs
        ? suburbs.where((s) => mapProvider.isSuburbImported(s.name)).length
        : 0;
    final totalImported = importedWorkAreaCount + importedSuburbCount;

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(12),
      color: Colors.white,
      child: SizedBox(
        width: 310,
        height: 460,
        child: Column(
          children: [
            // ── Header ──
            Container(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 0),
              child: Row(
                children: [
                  const Icon(Icons.map_outlined,
                      size: 20, color: Color(0xFF1967D2)),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Work Areas',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF202124),
                      ),
                    ),
                  ),
                  if (totalImported > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1967D2).withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '$totalImported',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Color(0xFF1967D2),
                        ),
                      ),
                    ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 18, color: Color(0xFF5F6368)),
                    onPressed: widget.onClose,
                    splashRadius: 18,
                    tooltip: 'Close',
                  ),
                ],
              ),
            ),

            // ── Search bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: TextField(
                style: const TextStyle(fontSize: 13, color: Color(0xFF202124)),
                decoration: InputDecoration(
                  hintText: 'Search work areas & suburbs...',
                  hintStyle:
                      const TextStyle(fontSize: 13, color: Color(0xFF9AA0A6)),
                  prefixIcon: const Icon(Icons.search,
                      size: 18, color: Color(0xFF9AA0A6)),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                  filled: true,
                  fillColor: const Color(0xFFF1F3F4),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(20),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (value) => setState(() => _searchQuery = value),
              ),
            ),

            // ── Select All / Deselect All / Lasso ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  _ActionChip(
                    label: 'Select All',
                    icon: Icons.select_all,
                    onTap: () {
                      if (showWorkAreas) {
                        for (final wa in filteredWorkAreas) {
                          mapProvider.addWorkAreaToMap(wa);
                        }
                      }
                      if (showSuburbs) {
                        for (final s in filteredSuburbs) {
                          mapProvider.addSuburbToMap(s);
                        }
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  _ActionChip(
                    label: 'Deselect All',
                    icon: Icons.deselect,
                    onTap: () {
                      if (showWorkAreas) {
                        for (final wa in filteredWorkAreas) {
                          if (mapProvider.isWorkAreaImported(wa.name)) {
                            mapProvider.removeWorkAreaFromMap(wa.name);
                          }
                        }
                      }
                      if (showSuburbs) {
                        for (final s in filteredSuburbs) {
                          if (mapProvider.isSuburbImported(s.name)) {
                            mapProvider.removeSuburbFromMap(s.name);
                          }
                        }
                      }
                    },
                  ),
                  const SizedBox(width: 8),
                  _ActionChip(
                    label: 'Lasso',
                    icon: Icons.gesture,
                    isActive: mapProvider.isLassoSelectActive,
                    onTap: () {
                      if (mapProvider.isLassoSelectActive) {
                        mapProvider.cancelLassoSelect();
                      } else {
                        mapProvider.startLassoSelect();
                      }
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            const Divider(height: 1),

            // ── Two-layer list ──
            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  // ── Work Areas layer ──
                  _LayerHeader(
                    label: 'Work Areas',
                    icon: Icons.crop_square,
                    color: WorkArea.defaultColor,
                    count: workAreas.length,
                    importedCount: importedWorkAreaCount,
                    isVisible: showWorkAreas,
                    isExpanded: _workAreasExpanded,
                    onToggleVisible: () =>
                        mapProvider.togglePickerWorkAreasVisible(),
                    onToggleExpanded: () => setState(
                        () => _workAreasExpanded = !_workAreasExpanded),
                  ),
                  if (showWorkAreas && _workAreasExpanded) ...[
                    if (filteredWorkAreas.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Text(
                          _searchQuery.isEmpty
                              ? 'No work areas found'
                              : 'No results for "$_searchQuery"',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9AA0A6)),
                        ),
                      )
                    else
                      ...filteredWorkAreas
                          .map((wa) => _WorkAreaTile(workArea: wa)),
                  ],

                  const Divider(height: 1, indent: 16, endIndent: 16),

                  // ── Suburbs layer ──
                  _LayerHeader(
                    label: 'Suburbs',
                    icon: Icons.location_city,
                    color: WorkSuburb.defaultColor,
                    count: suburbs.length,
                    importedCount: importedSuburbCount,
                    isVisible: showSuburbs,
                    isExpanded: _suburbsExpanded,
                    onToggleVisible: () =>
                        mapProvider.togglePickerSuburbsVisible(),
                    onToggleExpanded: () =>
                        setState(() => _suburbsExpanded = !_suburbsExpanded),
                  ),
                  if (showSuburbs && _suburbsExpanded) ...[
                    if (filteredSuburbs.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                        child: Text(
                          _searchQuery.isEmpty
                              ? 'No suburbs found'
                              : 'No results for "$_searchQuery"',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF9AA0A6)),
                        ),
                      )
                    else
                      ...filteredSuburbs.map((s) => _SuburbTile(suburb: s)),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Layer section header ──────────────────────────────────────────────

class _LayerHeader extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final int count;
  final int importedCount;
  final bool isVisible;
  final bool isExpanded;
  final VoidCallback onToggleVisible;
  final VoidCallback onToggleExpanded;

  const _LayerHeader({
    required this.label,
    required this.icon,
    required this.color,
    required this.count,
    required this.importedCount,
    required this.isVisible,
    required this.isExpanded,
    required this.onToggleVisible,
    required this.onToggleExpanded,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggleExpanded,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Eye toggle
            InkWell(
              onTap: onToggleVisible,
              borderRadius: BorderRadius.circular(14),
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Icon(
                  isVisible ? Icons.visibility : Icons.visibility_off,
                  size: 18,
                  color: isVisible ? color : const Color(0xFFDADCE0),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(icon,
                size: 16, color: isVisible ? color : const Color(0xFFDADCE0)),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: isVisible
                      ? const Color(0xFF202124)
                      : const Color(0xFF9AA0A6),
                ),
              ),
            ),
            if (importedCount > 0)
              Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$importedCount / $count',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.only(right: 6),
                child: Text(
                  '$count',
                  style:
                      const TextStyle(fontSize: 12, color: Color(0xFF9AA0A6)),
                ),
              ),
            Icon(
              isExpanded && isVisible ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: const Color(0xFF9AA0A6),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Individual work area tile ─────────────────────────────────────────

class _WorkAreaTile extends riverpod.ConsumerWidget {
  final WorkArea workArea;
  const _WorkAreaTile({required this.workArea});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final mapProvider = ref.watch(shareableMapRiverpod);
    final isImported = mapProvider.isWorkAreaImported(workArea.name);
    final color = workArea.color;

    return InkWell(
      onTap: () {
        if (isImported) {
          mapProvider.removeWorkAreaFromMap(workArea.name);
        } else {
          mapProvider.addWorkAreaToMap(workArea);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: isImported ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isImported ? color : const Color(0xFFDADCE0),
                  width: 1.5,
                ),
              ),
              child: isImported
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.3),
                border: Border.all(color: color, width: 1.5),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    workArea.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isImported ? FontWeight.w600 : FontWeight.w400,
                      color: const Color(0xFF202124),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${workArea.polygonPoints.length} points',
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Individual suburb tile ────────────────────────────────────────────

class _SuburbTile extends riverpod.ConsumerWidget {
  final WorkSuburb suburb;
  const _SuburbTile({required this.suburb});

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final mapProvider = ref.watch(shareableMapRiverpod);
    final isImported = mapProvider.isSuburbImported(suburb.name);
    final color = suburb.color;

    return InkWell(
      onTap: () {
        if (isImported) {
          mapProvider.removeSuburbFromMap(suburb.name);
        } else {
          mapProvider.addSuburbToMap(suburb);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: isImported ? color : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: isImported ? color : const Color(0xFFDADCE0),
                  width: 1.5,
                ),
              ),
              child: isImported
                  ? const Icon(Icons.check, size: 16, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.3),
                border: Border.all(color: color, width: 1.5),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    suburb.name,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight:
                          isImported ? FontWeight.w600 : FontWeight.w400,
                      color: const Color(0xFF202124),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    '${suburb.polygonPoints.length} points',
                    style:
                        const TextStyle(fontSize: 11, color: Color(0xFF9AA0A6)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Small action chip ─────────────────────────────────────────────────

class _ActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool isActive;

  const _ActionChip({
    required this.label,
    required this.icon,
    required this.onTap,
    this.isActive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = isActive ? const Color(0xFF1967D2) : const Color(0xFF5F6368);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color:
              isActive ? const Color(0xFF1967D2).withValues(alpha: 0.1) : null,
          border: Border.all(
            color: isActive ? const Color(0xFF1967D2) : const Color(0xFFDADCE0),
          ),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                color: color,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
