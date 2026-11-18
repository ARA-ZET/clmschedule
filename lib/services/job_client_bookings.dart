/// What a schedule job's clients are booked for on the Job List — each
/// client's job type and appointment time — so a map can draw every point
/// of the job as the work done there: a bin for a junk collection, a sofa
/// for a furniture move, "SOLAR CLEANING 09:30" for a booked call-out.
///
/// Print Map and the distributor work areas map both draw their pins from
/// this, so the two maps show the same thing.
library;

import 'package:cloud_firestore/cloud_firestore.dart' show FirebaseFirestore;

import '../models/custom_job_type.dart';
import '../models/custom_polygon.dart';
import '../models/job.dart';
import '../models/job_list_item.dart';
import '../providers/job_type_provider.dart';
import '../utils/distribution_lag.dart';
import '../utils/map_pin_icons.dart';
import 'client_address_pin.dart';
import 'job_list_service.dart';

class JobClientBookings {
  /// The schedule job's clients.
  final List<String> clients;

  /// Job type id of each client's Job List job, by client key
  /// ([jobListClientKey]).
  final Map<String, String> typeIds;

  /// Appointment start ("09:30") of each client's Job List job, by client
  /// key. Jobs with no time of day are left out.
  final Map<String, String> times;

  const JobClientBookings({
    this.clients = const [],
    this.typeIds = const {},
    this.times = const {},
  });

  /// Nothing known yet: pins show their category pictures.
  static const none = JobClientBookings();

  /// [job]'s bookings from its paired Job List jobs (client key → item, as
  /// [pairJobsWithJobListItems] gives them).
  factory JobClientBookings.fromPairing(
          Job job, Map<String, JobListItem> paired) =>
      JobClientBookings(
        clients: job.clients,
        typeIds: {for (final e in paired.entries) e.key: e.value.jobTypeId},
        times: {
          for (final e in paired.entries)
            if (e.value.resolvedTimeSlot case final t when t != '00:00')
              e.key: t,
        },
      );

  /// The bookings of every job in [jobs], by job id, from one Job List
  /// lookup covering all their clients.
  static Future<Map<String, JobClientBookings>> load(List<Job> jobs) async {
    final withClients = [
      for (final j in jobs)
        if (j.clients.any((c) => c.trim().isNotEmpty)) j,
    ];
    if (withClients.isEmpty) return const {};
    final items = await JobListService(FirebaseFirestore.instance)
        .getJobListItemsForClients({
      for (final j in withClients) ...j.clients,
    }, {
      for (final j in withClients) ...[
        DateTime(j.date.year, j.date.month - 1),
        DateTime(j.date.year, j.date.month),
        DateTime(j.date.year, j.date.month, j.date.day + 7),
      ],
    });
    final pairing = pairJobsWithJobListItems(jobs: withClients, items: items);
    return {
      for (final j in withClients)
        j.id: JobClientBookings.fromPairing(j, pairing[j.id] ?? const {}),
    };
  }

  /// Keys of the clients booked for a Junk & Stuff or Happy Sun job.
  Set<String> get _callOutClients => {
        for (final key in clients.map(jobListClientKey))
          if (typeIds[key] case final t?
              when ClientAddressPin.isCallOutJobType(t))
            key,
      };

  /// The Junk & Stuff or Happy Sun job done at [point]: its client's job
  /// for a client address pin, otherwise the job's one call-out job type
  /// when all its clients share it. Null for CLM work and mixed jobs.
  CustomJobType? jobTypeFor(CustomPolygon point) {
    String? id;
    if (ClientAddressPin.isAutoPin(point)) {
      id = typeIds[ClientAddressPin.pinnedClientKey(point)];
    }
    if (id == null) {
      final types = {for (final key in _callOutClients) typeIds[key]!};
      if (types.length == 1) id = types.single;
    }
    if (id == null || !ClientAddressPin.isCallOutJobType(id)) return null;
    return _jobType(id);
  }

  /// The appointment time of the job done at [point], for job types booked
  /// by the time slot: its client's for a client address pin, otherwise
  /// the job's one call-out client's. Null when there is none to show.
  String? timeFor(CustomPolygon point, CustomJobType? jobType) {
    if (jobType == null || !jobType.needsTimeSlot) return null;
    String? client;
    if (ClientAddressPin.isAutoPin(point)) {
      client = ClientAddressPin.pinnedClientKey(point);
    } else {
      final callOut = _callOutClients;
      if (callOut.length == 1) client = callOut.single;
    }
    return client == null ? null : times[client];
  }

  /// The pin [point] is drawn as.
  MapPinStyle styleFor(CustomPolygon point) {
    final jobType = jobTypeFor(point);
    return MapPinStyle.forPoint(point,
        jobType: jobType, time: timeFor(point, jobType));
  }

  /// Where [point]'s pin stacks ([PinLayer]).
  int layerFor(CustomPolygon point) {
    if (point.pointCategory == PointCategory.dropoff) return PinLayer.dropOff;
    return jobTypeFor(point) != null ? PinLayer.callOut : PinLayer.point;
  }

  /// The loaded job type, or the built-in default before job types load.
  static CustomJobType? _jobType(String id) {
    final loaded = JobTypeProvider.instance?.getJobTypeById(id);
    if (loaded != null) return loaded;
    for (final t in CustomJobType.getDefaults()) {
      if (t.id == id) return t;
    }
    return null;
  }
}
