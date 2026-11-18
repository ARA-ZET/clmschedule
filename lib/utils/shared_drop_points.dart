import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../models/dropsheet_day.dart';
import '../models/dropsheet_task.dart';
import '../services/client_address_pin.dart';

/// Shared drop points: to save fuel, one driver drops (or collects) several
/// distributors at one spot when they work the same or neighbouring areas.
///
/// Stops of one driver within [kSharedDropRadiusM] of each other count as one
/// point — one pin on the day planner map, flagged on the dropsheet. Dropping
/// a pin within that radius of another snaps it onto that exact spot, so the
/// route has a single stop there.
const double kSharedDropRadiusM = 100;

/// Straight-line distance in metres.
double distanceMeters(LatLng a, LatLng b) {
  const earthRadiusM = 6371000.0;
  double rad(double d) => d * math.pi / 180;
  final dLat = rad(b.latitude - a.latitude);
  final dLng = rad(b.longitude - a.longitude);
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(rad(a.latitude)) *
          math.cos(rad(b.latitude)) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * earthRadiusM * math.asin(math.min(1, math.sqrt(h)));
}

/// Groups [items] (in route order) whose points lie within [radiusM] of the
/// group's first item. Every item lands in exactly one group, singletons
/// included, and groups keep the order of their first item.
List<List<T>> clusterByDistance<T>(
  List<T> items,
  LatLng Function(T) positionOf, {
  double radiusM = kSharedDropRadiusM,
}) {
  final groups = <List<T>>[];
  for (final item in items) {
    final p = positionOf(item);
    final home = groups
        .where((g) => distanceMeters(positionOf(g.first), p) <= radiusM)
        .firstOrNull;
    if (home != null) {
      home.add(item);
    } else {
      groups.add([item]);
    }
  }
  return groups;
}

/// Drop-offs and pick-ups are the stops a driver shares; a Distribute task
/// is the driver working an area himself.
bool isShareableStop(DropsheetTask t) =>
    t.type == DropsheetTaskType.dropOff || t.type == DropsheetTaskType.pickUp;

/// Drop-offs and pick-ups never share a point with each other: they happen
/// at different times of the day.
bool _samePass(DropsheetTask a, DropsheetTask b) =>
    (a.type == DropsheetTaskType.pickUp) == (b.type == DropsheetTaskType.pickUp);

LatLng? taskPoint(DropsheetTask t) {
  final lat = (t.typeData['lat'] as num?)?.toDouble();
  final lng = (t.typeData['lng'] as num?)?.toDouble();
  return lat == null || lng == null ? null : LatLng(lat, lng);
}

/// For every drop-off / pick-up on [day] that shares its point with at least
/// one other stop of the same driver, the stops at that point (itself
/// included, in route order). Stops with no coordinate never share.
Map<String, List<DropsheetTask>> sharedStopsByTaskId(DropsheetDay day) => {
      for (final section in day.sections) ...sharedStopsInSection(section),
    };

/// [sharedStopsByTaskId] for one driver's run.
Map<String, List<DropsheetTask>> sharedStopsInSection(
    DropsheetDriverSection section) {
  // Nobody drops Own transport people off, so there is no shared point.
  if (section.isOwnTransport) return {};
  final out = <String, List<DropsheetTask>>{};
  // A job site's crew is listed under its job instead.
  final sites = jobSitesInSection(section);
  final stops = section.tasks
      .where((t) =>
          isShareableStop(t) &&
          taskPoint(t) != null &&
          !sites.containsKey(t.id))
      .toList();
  for (final pass in [false, true]) {
    final ofPass = stops
        .where((t) => (t.type == DropsheetTaskType.pickUp) == pass)
        .toList();
    for (final group in clusterByDistance(ofPass, (t) => taskPoint(t)!)) {
      if (group.length < 2) continue;
      for (final t in group) {
        out[t.id] = group;
      }
    }
  }
  return out;
}

/// "Same drop point as Thabo, Sipho" — the others at [task]'s shared point,
/// or null when it has its own.
String? sharedStopNote(
    DropsheetTask task, Map<String, List<DropsheetTask>> shared) {
  final group = shared[task.id];
  if (group == null) return null;
  final others = group
      .where((t) => t.id != task.id && _samePass(t, task))
      .map(stopPersonName)
      .where((n) => n.isNotEmpty)
      .toList();
  if (others.isEmpty) return null;
  final what = task.type == DropsheetTaskType.pickUp ? 'pick-up' : 'drop';
  return 'Same $what point as ${others.join(', ')}';
}

/// The distributor a stop is for.
String stopPersonName(DropsheetTask t) {
  final name = (t.typeData['distributorName'] as String?)?.trim() ?? '';
  return name.isNotEmpty ? name : t.contact.trim();
}

/// How many map stops [t] has from its own coordinates: a furniture move
/// one per address, anything else one when it has a point.
int taskStopCount(DropsheetTask t) {
  if (t.type == DropsheetTaskType.furnitureMove) {
    return [
      t.typeData['loadingLat'] != null && t.typeData['loadingLng'] != null,
      t.typeData['offloadLat'] != null && t.typeData['offloadLng'] != null,
    ].where((has) => has).length;
  }
  return taskPoint(t) == null ? 0 : 1;
}

/// The number each stop of [section] carries on the day planner map — and
/// on the printed dropsheet, so the two always agree. Stops count in run
/// order, skipping the fixed Inspect / Pack / Leave / Arrive rows and
/// anything without a point; a task with several stops (furniture move)
/// takes one number per stop and maps to its first. When the run has
/// pick-ups they count from 1 again, as the map shows them in a view of
/// their own. [stopCount] lets the map count from live job points.
Map<String, int> stopNumbersFor(DropsheetDriverSection section,
    {int Function(DropsheetTask)? stopCount}) {
  // Own transport isn't a run: its people get there themselves, unnumbered.
  if (section.isOwnTransport) return {};
  final count = stopCount ?? taskStopCount;
  final hasPickUps =
      section.tasks.any((t) => t.type == DropsheetTaskType.pickUp);
  // A job site is one stop: its job and crew share the number of whichever
  // comes first in the run.
  final sites = jobSitesInSection(section);
  final siteNumbers = <String, int>{};
  final out = <String, int>{};
  var drops = 0;
  var pickUps = 0;
  for (final t in section.tasks) {
    if (t.isMandatory) continue;
    final n = count(t);
    if (n == 0) continue;
    final site = sites[t.id];
    if (site != null) {
      out[t.id] = siteNumbers.putIfAbsent(site.job.id, () => ++drops);
      continue;
    }
    if (hasPickUps && t.type == DropsheetTaskType.pickUp) {
      out[t.id] = pickUps + 1;
      pickUps += n;
    } else {
      out[t.id] = drops + 1;
      drops += n;
    }
  }
  return out;
}

// ── Job sites ───────────────────────────────────────────────────────────────
//
// Junk & Stuff and Happy Sun jobs are worked at the client's house, usually
// by several people the driver drops there. On the run they are one stop:
// the job (e.g. "Window Cleaning: Martin Vanlierde") with its crew listed
// under it, rather than a drop-off per person beside the job.

/// A Junk & Stuff / Happy Sun Job List job with a point, worked where it is
/// (a two-address move is not a site anyone is dropped at).
bool isJobSiteTask(DropsheetTask t) =>
    t.sourceJobListItemId != null &&
    !t.isMandatory &&
    t.type != DropsheetTaskType.furnitureMove &&
    t.type != DropsheetTaskType.pickUp &&
    taskPoint(t) != null &&
    ClientAddressPin.isCallOutJobType(
        (t.typeData['jobType'] as String?) ?? '');

/// Who can be on a job's crew: people dropped off, and the driver when he
/// works it himself (Distribute).
bool isCrewStop(DropsheetTask t) =>
    t.type == DropsheetTaskType.dropOff ||
    t.type == DropsheetTaskType.distribute;

/// A job and the crew dropped at it, both in run order.
class JobSite {
  final DropsheetTask job;
  final List<DropsheetTask> crew;
  const JobSite(this.job, this.crew);

  Set<String> get taskIds => {job.id, for (final t in crew) t.id};
}

/// The job sites of one driver's run, keyed by the id of every task in them
/// (job and crew). Each drop-off / Distribute stop within
/// [kSharedDropRadiusM] of a job site joins the nearest one; a job nobody is
/// dropped at is not a site.
Map<String, JobSite> jobSitesInSection(DropsheetDriverSection section) {
  // Own transport people get there themselves: nothing to group.
  if (section.isOwnTransport) return {};
  final jobs = section.tasks.where(isJobSiteTask).toList();
  if (jobs.isEmpty) return {};
  final crewByJob = <String, List<DropsheetTask>>{};
  for (final t in section.tasks) {
    if (!isCrewStop(t)) continue;
    final p = taskPoint(t);
    if (p == null) continue;
    DropsheetTask? best;
    var bestD = kSharedDropRadiusM;
    for (final j in jobs) {
      final d = distanceMeters(taskPoint(j)!, p);
      if (d <= bestD) {
        bestD = d;
        best = j;
      }
    }
    if (best != null) crewByJob.putIfAbsent(best.id, () => []).add(t);
  }
  final out = <String, JobSite>{};
  for (final j in jobs) {
    final crew = crewByJob[j.id];
    if (crew == null) continue;
    final site = JobSite(j, crew);
    for (final id in site.taskIds) {
      out[id] = site;
    }
  }
  return out;
}

/// "Talent", or "Petros (driver)" when the driver works the job himself.
String crewMemberName(DropsheetTask t) {
  final name = stopPersonName(t);
  return t.type == DropsheetTaskType.distribute && name.isNotEmpty
      ? '$name (driver)'
      : name;
}

/// "Crew: Talent, Gift, Dickson" on a job site's job,
/// "Crew for Window Cleaning: Martin Vanlierde" on each of its crew, or null
/// when [task] is not on a job site.
String? jobSiteNote(DropsheetTask task, Map<String, JobSite> sites) {
  final site = sites[task.id];
  if (site == null) return null;
  if (site.job.id == task.id) {
    // Details already lists everyone on the job ("Team: …").
    if (task.withNames.isNotEmpty) return null;
    final names =
        site.crew.map(crewMemberName).where((n) => n.isNotEmpty).toList();
    return names.isEmpty ? null : 'Crew: ${names.join(', ')}';
  }
  final job = site.job.job.trim();
  return 'Crew for ${job.isEmpty ? site.job.contact.trim() : job}';
}
