/// Combining two schedule jobs into one (the grid's "Add to existing" and
/// "Copy & combine" drops, and unfinished-pool items dropped on a filled
/// cell) without losing anything either side carried.
///
/// Every persisted [Job] field is accounted for here. When a field is added
/// to [Job], decide how it merges and add it to [mergeScheduleJobs] — a
/// field left to `copyWith` silently keeps only the target's value.
library;

import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../models/job_area_link.dart';
import '../models/job_linked_map.dart';

/// [incoming] folded into [target]. The result keeps [target]'s id,
/// distributor, date and status; everything else is the union of both:
///
/// * clients, each keeping its own instruction ([Job.clientInstructions] is
///   parallel to [Job.clients]); a client on both jobs gets both texts
/// * work areas and work maps — own polygons whose name collides are
///   renamed `"<name> gap"`, never dropped
/// * linked client-map areas ([Job.areaLinks]) and linked maps
/// * map instructions; drop-off / pick-up points prefer [target]'s
Job mergeScheduleJobs({required Job target, required Job incoming}) {
  final (clients, clientInstructions) = _mergeClients(target, incoming);

  // Linked areas are stored as references and resolved on read; only the
  // jobs' own areas are written back. Track which merged names came from a
  // link, so [Job.toMap] keeps leaving them out.
  final ownAreas = mergeStringsPreserveCase(
    target.ownWorkingAreas,
    incoming.ownWorkingAreas,
  );
  final ownKeys = ownAreas.map((a) => a.toLowerCase()).toSet();
  final resolvedNames = {
    ...target.resolvedAreaNames,
    ...incoming.resolvedAreaNames,
  }.where((n) => !ownKeys.contains(n.trim().toLowerCase())).toSet();
  final workingAreas =
      mergeStringsPreserveCase(ownAreas, resolvedNames.toList());

  final areaLinks = <JobAreaLink>[...target.areaLinks];
  final linkKeys = areaLinks.map((l) => l.key).toSet();
  for (final l in incoming.areaLinks) {
    if (linkKeys.add(l.key)) areaLinks.add(l);
  }

  // Own polygons merge with gap-renaming; resolved ones are display copies
  // of a link, so only add those not already shown.
  final shownIds = target.workMaps.map((p) => p.id).whereType<String>().toSet();
  final workMaps = [
    ...mergeWorkMaps(target.workMaps, incoming.ownWorkMaps),
    for (final p in incoming.workMaps)
      if (JobAreaLink.isResolved(p) && shownIds.add(p.id!)) p,
  ];

  final linkedMaps = <JobLinkedMap>[...target.effectiveLinkedMaps];
  final mapKeys = linkedMaps.map((m) => '${m.monthKey}/${m.mapId}').toSet();
  for (final m in incoming.effectiveLinkedMaps) {
    if (mapKeys.add('${m.monthKey}/${m.mapId}')) linkedMaps.add(m);
  }

  return target.copyWith(
    clients: clients,
    clientInstructions: clientInstructions,
    workingAreas: workingAreas,
    workMaps: workMaps,
    mapInstructions: mergeTextBlocks(
      target.mapInstructions,
      incoming.mapInstructions,
    ),
    dropOffPoint: target.dropOffPoint ?? incoming.dropOffPoint,
    pickUpPoint: target.pickUpPoint ?? incoming.pickUpPoint,
    areaLinks: areaLinks,
    resolvedAreaNames: resolvedNames,
    missingAreaLinkKeys: {
      ...target.missingAreaLinkKeys,
      ...incoming.missingAreaLinkKeys,
    },
  ).withLinkedMaps(linkedMaps);
}

/// Clients of both jobs, deduplicated case-insensitively, with
/// [Job.clientInstructions] kept aligned. Returns no instructions at all when
/// neither job had any, so jobs without them stay that way.
(List<String>, List<String>) _mergeClients(Job target, Job incoming) {
  final clients = <String>[];
  final instructions = <String>[];
  final indexByKey = <String, int>{};
  for (final job in [target, incoming]) {
    for (var i = 0; i < job.clients.length; i++) {
      final client = job.clients[i].trim();
      if (client.isEmpty) continue;
      final text =
          i < job.clientInstructions.length ? job.clientInstructions[i] : '';
      final existing = indexByKey[client.toLowerCase()];
      if (existing != null) {
        instructions[existing] = mergeTextBlocks(instructions[existing], text);
      } else {
        indexByKey[client.toLowerCase()] = clients.length;
        clients.add(client);
        instructions.add(text.trim());
      }
    }
  }
  final hasAny = instructions.any((t) => t.isNotEmpty);
  return (clients, hasAny ? instructions : const <String>[]);
}

/// Merge two lists of string tokens, deduplicating case-insensitively while
/// preserving the casing of the first occurrence. Empty / whitespace-only
/// entries are dropped.
List<String> mergeStringsPreserveCase(List<String> a, List<String> b) {
  final seen = <String>{};
  final out = <String>[];
  for (final v in [...a, ...b]) {
    final trimmed = v.trim();
    if (trimmed.isEmpty) continue;
    if (seen.add(trimmed.toLowerCase())) out.add(trimmed);
  }
  return out;
}

/// Combine two free-form instruction blocks without losing either side.
String mergeTextBlocks(String a, String b) {
  final lines = <String>[];
  for (final value in [a, b]) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) continue;
    if (!lines.contains(trimmed)) lines.add(trimmed);
  }
  return lines.join('\n');
}

/// Merge two polygon/work-map lists. The [target] list keeps priority.
///
/// Incoming polygons whose `(type, name)` collides with an entry already
/// present get their name suffixed so no data is lost:
///   * first collision  → `"<name> gap"`
///   * further collisions → `"<name> gap1"`, `"<name> gap2"`, … (cumulative)
///
/// Unnamed polygons are always appended as-is (no reliable way to
/// deduplicate geometry by name).
List<CustomPolygon> mergeWorkMaps(
  List<CustomPolygon> target,
  List<CustomPolygon> incoming,
) {
  String keyFor(String type, String name) => '$type::${name.trim()}';

  // Seed the "used keys" set with everything already in the target.
  final used = <String>{};
  for (final p in target) {
    final n = p.name.trim();
    if (n.isEmpty) continue;
    used.add(keyFor(p.type.toString(), n));
  }

  final merged = List<CustomPolygon>.from(target);
  for (final p in incoming) {
    final originalName = p.name.trim();
    if (originalName.isEmpty) {
      merged.add(p); // unnamed: keep, cannot dedupe safely
      continue;
    }

    final typeStr = p.type.toString();
    final originalKey = keyFor(typeStr, originalName);
    if (used.add(originalKey)) {
      merged.add(p);
      continue;
    }

    // Collision — find next free "<name> gap" / "<name> gapN" suffix.
    String candidate = '$originalName gap';
    if (used.contains(keyFor(typeStr, candidate))) {
      var n = 1;
      while (used.contains(keyFor(typeStr, '$originalName gap$n'))) {
        n++;
      }
      candidate = '$originalName gap$n';
    }
    used.add(keyFor(typeStr, candidate));
    merged.add(p.copyWith(name: candidate));
  }
  return merged;
}
