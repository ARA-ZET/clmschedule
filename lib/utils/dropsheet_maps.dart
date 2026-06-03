import '../models/dropsheet_task.dart';

/// Helpers for building Google Maps links from typed dropsheet tasks
/// and for deriving short display strings (used in the Location cell).
///
/// All addresses are assumed to be in Western Cape, South Africa — that
/// suffix is appended to free-text address queries to disambiguate.
class DropsheetMaps {
  static const String _waSuffix = ', Western Cape, South Africa';

  /// Single-pin link from a coordinate.
  /// Uses the universal `?api=1&query=lat,lng` form (deep-links to the
  /// Google Maps app on mobile, opens maps.google.com on desktop).
  static String pinUrlFromLatLng(double lat, double lng) =>
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng';

  /// Single-pin link from a free-text address. Western-Cape suffix is
  /// appended automatically.
  static String pinUrlFromAddress(String address) {
    final trimmed = address.trim();
    if (trimmed.isEmpty) return '';
    final query = Uri.encodeComponent('$trimmed$_waSuffix');
    return 'https://www.google.com/maps/search/?api=1&query=$query';
  }

  /// Returns 0, 1 or 2 Maps links describing a task, in the order the
  /// driver should visit them. Empty list means "no Maps link applies".
  static List<DropsheetMapLink> linksFor(DropsheetTask task) {
    switch (task.type) {
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
        final lat = (task.typeData['lat'] as num?)?.toDouble();
        final lng = (task.typeData['lng'] as num?)?.toDouble();
        final name =
            (task.typeData['workArea'] as String?)?.trim().isNotEmpty == true
                ? task.typeData['workArea'] as String
                : (task.typeData['distributorName'] as String? ?? '');
        if (lat != null && lng != null) {
          return [
            DropsheetMapLink(label: name, url: pinUrlFromLatLng(lat, lng))
          ];
        }
        return const [];
      case DropsheetTaskType.collection:
      case DropsheetTaskType.jobReturn:
      case DropsheetTaskType.pickFlyers:
        final addr = (task.typeData['address'] as String?)?.trim() ?? '';
        if (addr.isEmpty) return const [];
        return [DropsheetMapLink(label: addr, url: pinUrlFromAddress(addr))];
      case DropsheetTaskType.furnitureMove:
        final loading =
            (task.typeData['loadingAddress'] as String?)?.trim() ?? '';
        final offload =
            (task.typeData['offloadAddress'] as String?)?.trim() ?? '';
        final out = <DropsheetMapLink>[];
        if (loading.isNotEmpty) {
          out.add(DropsheetMapLink(
              label: 'Loading: $loading', url: pinUrlFromAddress(loading)));
        }
        if (offload.isNotEmpty) {
          out.add(DropsheetMapLink(
              label: 'Offloading: $offload', url: pinUrlFromAddress(offload)));
        }
        return out;
      case DropsheetTaskType.custom:
        final addr = (task.typeData['address'] as String?)?.trim() ?? '';
        if (addr.isEmpty) return const [];
        return [DropsheetMapLink(label: addr, url: pinUrlFromAddress(addr))];
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
        return const [];
      case DropsheetTaskType.leave:
      case DropsheetTaskType.arrive:
        final lat = (task.typeData['lat'] as num?)?.toDouble();
        final lng = (task.typeData['lng'] as num?)?.toDouble();
        final label = task.location.isNotEmpty ? task.location : 'Office';
        if (lat != null && lng != null) {
          return [
            DropsheetMapLink(label: label, url: pinUrlFromLatLng(lat, lng))
          ];
        }
        if (task.location.isNotEmpty) {
          return [
            DropsheetMapLink(
                label: task.location, url: pinUrlFromAddress(task.location))
          ];
        }
        return const [];
    }
  }

  /// Short, single-line label shown in the Location cell of the row.
  /// For typed tasks this is derived from [DropsheetTask.typeData];
  /// for `custom` tasks we fall back to [DropsheetTask.location].
  static String locationLabel(DropsheetTask task) {
    switch (task.type) {
      case DropsheetTaskType.dropOff:
      case DropsheetTaskType.pickUp:
        final wa = (task.typeData['workArea'] as String?)?.trim();
        if (wa != null && wa.isNotEmpty) return wa;
        return (task.typeData['distributorName'] as String?) ?? task.location;
      case DropsheetTaskType.collection:
      case DropsheetTaskType.jobReturn:
      case DropsheetTaskType.pickFlyers:
        return (task.typeData['address'] as String?) ?? task.location;
      case DropsheetTaskType.furnitureMove:
        final l = (task.typeData['loadingAddress'] as String?) ?? '';
        final o = (task.typeData['offloadAddress'] as String?) ?? '';
        if (l.isEmpty && o.isEmpty) return task.location;
        if (l.isEmpty) return 'Offloading: $o';
        if (o.isEmpty) return 'Loading: $l';
        return 'Loading: $l · Offloading: $o';
      case DropsheetTaskType.inspect:
      case DropsheetTaskType.pack:
      case DropsheetTaskType.leave:
      case DropsheetTaskType.arrive:
      case DropsheetTaskType.custom:
        final addr = (task.typeData['address'] as String?)?.trim() ?? '';
        if (addr.isNotEmpty) {
          return task.location.isNotEmpty ? task.location : addr;
        }
        return task.location;
    }
  }

  /// Default `job` label for typed tasks where the user hasn't customised it.
  static String defaultJobLabel(DropsheetTaskType type) {
    return type.displayName;
  }
}

class DropsheetMapLink {
  final String label;
  final String url;
  const DropsheetMapLink({required this.label, required this.url});
}
