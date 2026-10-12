// track_editor/services/te_work_area_import.dart
//
// Bringing a saved work area onto the open tab — and, when that tab came in
// through the processing flow, onto the schedule jobs behind it.
//
// One implementation for both ways in: the sidebar's search-and-tick list and
// the map's work-area overlay. They differ only in how you choose an area; what
// happens next — the styled polygon, the undo entry, the write back to each
// linked job — has to be identical, or the same action would leave different
// state depending on which control you reached for.
import 'package:flutter/material.dart';

import '../../models/custom_polygon.dart';
import '../../models/work_area.dart';
import '../../providers/schedule_provider.dart';
import '../models/styled_polygon.dart';
import '../models/tab_item.dart';
import '../providers/te_mode_provider.dart';
import '../providers/te_tabs_provider.dart';
import '../providers/te_undo_provider.dart';

/// The colour work areas take on the tab. Matches the overlay they were picked
/// from, so an area looks the same before and after it is added.
const Color kTEWorkAreaColor = Color(0xFF00796B); // teal.shade700

/// What an import did.
class TEWorkAreaImportResult {
  /// Areas that were put on the tab.
  final List<WorkArea> added;

  /// Areas the tab already had, by name. Not an error — tapping an area that
  /// is already there should be a no-op, not a second copy of it.
  final List<WorkArea> alreadyPresent;

  const TEWorkAreaImportResult({
    this.added = const [],
    this.alreadyPresent = const [],
  });

  bool get isEmpty => added.isEmpty;
  int get addedCount => added.length;
}

/// Styled polygon for [area], as the track editor draws work areas.
TEStyledPolygon teStyledPolygonFor(WorkArea area) {
  return TEStyledPolygon(
    // Prefixed so it cannot collide with a drawn polygon's id, and stable per
    // work area so re-adding one after an undo lands on the same identity.
    id: 'wa_${area.id}',
    name: area.name,
    points: List.of(area.polygonPoints),
    style: TEKmlStyle(
      strokeColor: kTEWorkAreaColor,
      strokeWidth: 2.0,
      fillColor: const Color(0xFF4DB6AC), // teal.shade300
      fill: true,
      outline: true,
    ),
  );
}

/// Split [areas] into the ones [existingNames] does not already cover and the
/// ones it does.
///
/// **Name, not id, is the key.** A work area reaches a tab as a polygon that
/// keeps only its name, and the same ground can arrive from a work area, a KML
/// import or a schedule job's work map — all of which agree on the name and
/// none of which share an id. Compared trimmed and case-folded, because those
/// three sources do not agree on spacing or capitalisation either.
///
/// Duplicates *within* [areas] collapse too: picking the same area twice in one
/// selection adds it once.
TEWorkAreaImportResult planWorkAreaImport(
  List<WorkArea> areas,
  Iterable<String> existingNames,
) {
  final seen = existingNames.map(_nameKey).toSet();
  final add = <WorkArea>[];
  final present = <WorkArea>[];
  for (final area in areas) {
    if (seen.add(_nameKey(area.name))) {
      add.add(area);
    } else {
      present.add(area);
    }
  }
  return TEWorkAreaImportResult(added: add, alreadyPresent: present);
}

/// The work maps that should be appended to a job holding [existing], for
/// [areas]. Same name rule as [planWorkAreaImport].
List<CustomPolygon> workMapsToAppend(
  List<CustomPolygon> existing,
  List<WorkArea> areas,
) {
  final seen = existing.map((p) => _nameKey(p.name)).toSet();
  final out = <CustomPolygon>[];
  for (final area in areas) {
    if (!seen.add(_nameKey(area.name))) continue;
    out.add(CustomPolygon(
      name: area.name,
      description: area.description,
      points: List.of(area.polygonPoints),
      color: kTEWorkAreaColor,
      // Carried across so the schedule's own map does not have to recount
      // ground the work area already has a number for.
      letterBoxEstimate: area.letterBoxEstimate,
    ));
  }
  return out;
}

String _nameKey(String name) => name.trim().toLowerCase();

/// Add [areas] to the tab at [tabIndex], skipping any the tab already has.
///
/// Adding is one undoable command however many areas are involved, so Ctrl+Z
/// takes back the whole selection rather than one area at a time.
///
/// In processing mode the areas are also appended to every schedule job this
/// tab is matched to, which is what makes them show up on the schedule grid and
/// map view without anyone going to look for them. That write is best-effort
/// per job: one job failing must not cost the others, and must not undo the
/// polygon that is already on the tab.
Future<TEWorkAreaImportResult> addWorkAreasToTab({
  required TETabsProvider tabs,
  required TEUndoProvider undo,
  required ScheduleProvider schedule,
  required int tabIndex,
  required List<WorkArea> areas,
}) async {
  if (areas.isEmpty) return const TEWorkAreaImportResult();
  if (tabIndex < 0 || tabIndex >= tabs.tabs.length) {
    return const TEWorkAreaImportResult();
  }

  final tab = tabs.tabs[tabIndex];
  final plan = planWorkAreaImport(areas, tab.polygons.map((p) => p.name));
  final toAdd = plan.added;
  if (toAdd.isEmpty) return plan;

  final polygons = toAdd.map(teStyledPolygonFor).toList(growable: false);
  final addedCount = polygons.length;

  undo.run(
    tabs.activeMode,
    tabIndex,
    TECommand(
      description: 'Add ${addedCount == 1 ? 'map' : '$addedCount maps'}',
      // Addressed by index rather than "the current tab", so the undo entry
      // and the add can never end up pointing at different tabs.
      doFn: () {
        if (tabIndex < 0 || tabIndex >= tabs.tabs.length) return;
        tabs.replacePolygons(
            tabIndex, [...tabs.tabs[tabIndex].polygons, ...polygons]);
      },
      undoFn: () {
        // Remove the trailing N polygons that were appended.
        if (tabIndex < 0 || tabIndex >= tabs.tabs.length) return;
        final current = tabs.tabs[tabIndex].polygons;
        final keep = current.length - addedCount;
        if (keep < 0) return;
        tabs.replacePolygons(tabIndex, current.sublist(0, keep));
      },
    ),
  );

  if (tabs.activeMode == TEMode.processing && tab.jobIds.isNotEmpty) {
    await persistWorkAreasToJobs(
      schedule: schedule,
      tab: tab,
      areas: toAdd,
    );
  }

  return plan;
}

/// Append [areas] to the `workMaps` of every schedule job this tab is matched
/// to, so the same maps are on the schedule grid and map view.
Future<void> persistWorkAreasToJobs({
  required ScheduleProvider schedule,
  required TETabItem tab,
  required List<WorkArea> areas,
}) async {
  for (final jobId in tab.jobIds) {
    try {
      final job = schedule.jobs.where((j) => j.id == jobId).firstOrNull;
      if (job == null) continue;
      final toAppend = workMapsToAppend(job.workMaps, areas);
      if (toAppend.isEmpty) continue;
      await schedule
          .updateJob(job.copyWith(workMaps: [...job.workMaps, ...toAppend]));
    } catch (e) {
      // Best-effort: one job failing must not stop the rest, and must not
      // take back the polygon that is already on the tab.
      debugPrint('⚠️ persistWorkAreasToJobs($jobId): $e');
    }
  }
}
