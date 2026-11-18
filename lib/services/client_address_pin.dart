/// The client's address as a map point on a schedule job, for Job List jobs
/// worked at the client's house — every Junk & Stuff and Happy Sun job type
/// ([ClientAddressPin.isCallOutJobType]).
///
/// A worker added to such a job on the Schedule (press + in their row, pick
/// the client) used to have no point at all, so their dropsheet drop-off had
/// no location. The address is copied from the matching Job List job — its
/// geocoded address point when it has one — onto the schedule job, where it
/// becomes the drop-off point like any other map point.
///
/// Pins added here carry [kClientAddressPinPrefix] + the client in their
/// description. That is how they are told apart from points someone placed:
/// a job holding anything else (a polygon, a hand-placed point, a linked
/// area) is never pinned — except a drop-off point, which only says where
/// the driver leaves the worker, not where the client is.
library;

import 'package:google_maps_flutter/google_maps_flutter.dart' show LatLng;

import '../models/company.dart';
import '../models/custom_job_type.dart';
import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../models/job_list_item.dart';
import '../providers/job_type_provider.dart';
import '../shareable_maps/services/map_link_service.dart';
import '../utils/distribution_lag.dart';


/// Description prefix of an automatic pin; the client name follows it.
const String kClientAddressPinPrefix = 'Client address from Job List: ';

class ClientAddressPin {
  ClientAddressPin._();

  static bool isAutoPin(CustomPolygon p) =>
      p.isPoint && p.description.startsWith(kClientAddressPinPrefix);

  /// [p] marked as [client]'s address pin, so it leaves with the client.
  static CustomPolygon asAutoPin(CustomPolygon p, String client) =>
      p.copyWith(description: '$kClientAddressPinPrefix${client.trim()}');

  /// Junk & Stuff and Happy Sun jobs are done at the client's address, so
  /// only they get a geocoded address pin on their schedule jobs. CLM
  /// distribution and community jobs are worked over areas.
  static bool isCallOutJobType(String jobTypeId) {
    final company = _companyOf(jobTypeId);
    return company == Company.junkAndStuffId || company == Company.happySunId;
  }

  /// The company owning [jobTypeId]; the built-in defaults stand in while
  /// job types have not loaded (or in tests, where there is no provider).
  static String? _companyOf(String jobTypeId) {
    final loaded = JobTypeProvider.instance?.getJobTypeById(jobTypeId);
    if (loaded != null) return loaded.resolvedCompanyId;
    for (final t in CustomJobType.getDefaults()) {
      if (t.id == jobTypeId) return t.resolvedCompanyId;
    }
    return null;
  }

  /// Client key ([jobListClientKey]) the auto pin [p] was added for.
  static String pinnedClientKey(CustomPolygon p) =>
      jobListClientKey(p.description.substring(kClientAddressPinPrefix.length));

  /// Client keys of [job]'s clients that have no auto pin yet.
  static Set<String> unpinnedClientKeys(Job job) {
    final pinned = {
      for (final p in job.workMaps)
        if (isAutoPin(p)) pinnedClientKey(p),
    };
    return {
      for (final c in job.clients)
        if (jobListClientKey(c).isNotEmpty &&
            !pinned.contains(jobListClientKey(c)))
          jobListClientKey(c),
    };
  }

  /// Whether [job] may be given client address pins: it has a client without
  /// one, and holds nothing placed by hand — only earlier auto pins and
  /// drop-off points.
  static bool needsPin(Job job) =>
      job.areaLinks.isEmpty &&
      job.workMaps.every((p) => isAutoPin(p) || _isDropOff(p)) &&
      unpinnedClientKeys(job).isNotEmpty;

  static bool _isDropOff(CustomPolygon p) =>
      p.isPoint && p.pointCategory == PointCategory.dropoff;

  /// The Job List job each of [job]'s unpinned clients belongs to, keyed by
  /// client key — only items of a call-out type ([isCallOutJobType]), paired by
  /// the app's usual rule ([pairJobsWithJobListItems]).
  static Map<String, JobListItem> matchItems(
      Job job, Iterable<JobListItem> items) {
    final wanted = unpinnedClientKeys(job);
    if (wanted.isEmpty) return const {};
    final pairing = pairJobsWithJobListItems(
      jobs: [job],
      items:
          items.where((i) => isCallOutJobType(i.jobTypeId)),
    );
    return {
      for (final e in (pairing[job.id] ?? const {}).entries)
        if (wanted.contains(e.key)) e.key: e.value,
    };
  }

  /// [item]'s own geocoded address point, when it has one.
  static CustomPolygon? pointFromItem(JobListItem item) {
    for (final p in item.customPolygons) {
      if (p.isPoint && p.points.isNotEmpty) return p;
    }
    return null;
  }

  /// The address the job is done at: `area` unless it is a map link, else
  /// the collection address.
  static String addressText(JobListItem item) {
    final area = item.area.trim();
    if (area.isNotEmpty && !isMapLinkOrUrl(area)) return area;
    final col = item.collectionAddress.trim();
    if (col.isNotEmpty) return col;
    return area; // area even if it's a URL (last resort)
  }

  /// True if [text] looks like a URL or a shareable-map link rather than a
  /// street address.
  static bool isMapLinkOrUrl(String text) {
    final v = text.trim().toLowerCase();
    if (v.isEmpty) return false;
    return v.startsWith('http://') ||
        v.startsWith('https://') ||
        MapLinkService.containsShareUrl(v) ||
        v.contains('google.com/maps') ||
        v.contains('maps.app.goo.gl') ||
        v.contains('goo.gl/maps');
  }

  /// A pin for [item] at [position] (a geocoded address — used when the item
  /// has no point of its own).
  static CustomPolygon pointAt(JobListItem item, LatLng position) {
    final category = _companyOf(item.jobTypeId) == Company.happySunId
        ? PointCategory.cleaning
        : item.jobTypeId == 'furnitureMove'
            ? PointCategory.loading
            : PointCategory.pickup;
    return CustomPolygon(
      name: addressText(item),
      description: '',
      points: [position],
      color: category.color,
      type: MapElementType.point,
      pointCategory: category,
    );
  }

  /// [job] with a pin for each of [pins] (client key → pin from its Job List
  /// job). Drop-off points stay; auto pins for clients no longer on the job
  /// are dropped, and a
  /// work area that is unnamed — or only named after earlier auto pins — is
  /// set to the pinned addresses.
  static Job apply(Job job, Map<String, (JobListItem, CustomPolygon)> pins) {
    final clientKeys = job.clients.map(jobListClientKey).toSet();
    final kept = [
      for (final p in job.workMaps)
        if (!isAutoPin(p) ||
            (clientKeys.contains(pinnedClientKey(p)) &&
                !pins.containsKey(pinnedClientKey(p))))
          p,
    ];
    final added = [
      for (final (item, pin) in pins.values)
        asAutoPin(
          pin.copyWith(
              name: pin.name.trim().isEmpty ? addressText(item) : pin.name),
          item.client,
        ),
    ];
    final workMaps = [...kept, ...added];

    final oldPinNames = {
      for (final p in job.workMaps)
        if (isAutoPin(p)) p.name.trim().toLowerCase(),
    };
    final unnamed = job.workingAreas.every((a) {
      final t = a.trim().toLowerCase();
      return t.isEmpty || t == 'to be assigned' || oldPinNames.contains(t);
    });
    final names = [
      for (final p in workMaps)
        if (isAutoPin(p) && p.name.trim().isNotEmpty) p.name.trim(),
    ];

    return job.copyWith(
      workMaps: workMaps,
      workingAreas: unnamed && names.isNotEmpty ? names : null,
      dropOffPoint: null,
    );
  }

  /// [job] without the auto pins of clients no longer on it — a client taken
  /// off a schedule job takes its address pin along.
  static Job withoutStalePins(Job job) {
    final clientKeys = job.clients.map(jobListClientKey).toSet();
    return withoutPins(
        job, (p) => isAutoPin(p) && !clientKeys.contains(pinnedClientKey(p)));
  }

  /// Whether [p] is [item]'s geocoded address point copied onto a schedule
  /// job before pins were marked with their client: an unlabelled point at
  /// the same spot as one of the item's own points.
  static bool isUnmarkedItemPin(CustomPolygon p, JobListItem item) {
    if (!p.isPoint || p.points.isEmpty || p.description.trim().isNotEmpty) {
      return false;
    }
    final at = p.points.first;
    return item.customPolygons.any((q) =>
        q.isPoint &&
        q.points.isNotEmpty &&
        ((p.id != null && p.id == q.id) ||
            ((q.points.first.latitude - at.latitude).abs() < 1e-6 &&
                (q.points.first.longitude - at.longitude).abs() < 1e-6)));
  }

  /// [job] without the work maps [remove] picks, so the dropsheet and work
  /// areas stop sending the worker to a house they no longer go to. Work
  /// area names that came from those pins go too ("To be assigned" when
  /// nothing is left), and the drop-off is worked out again from what
  /// remains. [job] itself when nothing is picked.
  static Job withoutPins(Job job, bool Function(CustomPolygon) remove) {
    final removed = job.workMaps.where(remove).toList();
    if (removed.isEmpty) return job;
    final removedNames = {
      for (final p in removed)
        if (p.name.trim().isNotEmpty) p.name.trim().toLowerCase(),
    };
    final areas = [
      for (final a in job.workingAreas)
        if (!removedNames.contains(a.trim().toLowerCase())) a,
    ];
    return job.copyWith(
      workMaps: [
        for (final p in job.workMaps)
          if (!remove(p)) p,
      ],
      workingAreas: areas.isEmpty ? const ['To be assigned'] : areas,
      dropOffPoint: null,
    );
  }
}
