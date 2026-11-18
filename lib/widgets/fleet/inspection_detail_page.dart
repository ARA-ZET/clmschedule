// widgets/fleet/inspection_detail_page.dart
//
// One vehicle inspection as the driver submitted it: times, odometer, fuel,
// where it was done, the review flags, every checklist answer with its
// photos, and the Approve / Reject / Redo actions.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart' show DateFormat, NumberFormat;
import 'package:url_launcher/url_launcher.dart';

import '../../models/dropsheet_task_type_config.dart';
import '../../models/vehicle_inspection.dart';
import '../../services/vehicle_inspection_service.dart';
import '../../utils/friendly_error.dart';
import '../../utils/schedule_time.dart';
import '../app_toast.dart';
import 'fleet_dashboard.dart' show FleetColors;

class InspectionDetailPage extends StatefulWidget {
  final VehicleInspection inspection;
  final List<VehicleInspection> history;
  final DepotConfig depot;
  final VehicleInspectionService service;

  const InspectionDetailPage({
    super.key,
    required this.inspection,
    required this.history,
    required this.depot,
    required this.service,
  });

  @override
  State<InspectionDetailPage> createState() => _InspectionDetailPageState();
}

class _InspectionDetailPageState extends State<InspectionDetailPage> {
  late VehicleInspection _inspection = widget.inspection;
  bool _busy = false;

  VehicleInspectionService get _service => widget.service;

  Future<void> _review(InspectionReviewStatus status) async {
    String comment = '';
    if (status == InspectionReviewStatus.rejected) {
      final controller = TextEditingController();
      final entered = await showDialog<String>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Reject inspection'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(
              hintText: 'What was wrong? (the driver is told this)',
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(dialogContext, controller.text),
                child: const Text('Reject')),
          ],
        ),
      );
      controller.dispose();
      if (entered == null) return;
      comment = entered;
    }
    await _run(() async {
      await _service.setReview(_inspection.id,
          status: status, comment: comment);
      if (mounted) {
        setState(() {
          _inspection = _withReview(
              _inspection, InspectionReview(status: status, comment: comment));
        });
      }
    }, action: 'save the review');
  }

  Future<void> _redo() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Ask the driver to redo it?'),
        content: const Text(
          'This deletes the inspection and its photos so the driver can do '
          'it again in clmgpx. It cannot be undone.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _run(() async {
      await _service.deleteForRedo(_inspection);
      if (mounted) Navigator.of(context).pop();
    }, action: 'delete the inspection');
  }

  Future<void> _run(Future<void> Function() body,
      {required String action}) async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await body();
    } catch (e) {
      messenger.showToast(
          SnackBar(content: Text(friendlyFirebaseError(e, action: action))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final i = _inspection;
    final theme = Theme.of(context);
    final flags = VehicleInspectionService.flagsFor(i,
        history: widget.history, depot: widget.depot);
    final timeFmt = DateFormat('HH:mm');
    String at(DateTime? t) =>
        t == null ? '—' : timeFmt.format(toScheduleCivil(t));
    final duration = i.durationSec;
    final approved = i.review.status == InspectionReviewStatus.approved;
    final rejected = i.review.status == InspectionReviewStatus.rejected;
    final depotDistance =
        widget.depot.hasCoordinates && i.lat != null && i.lng != null
            ? VehicleInspectionService.distanceM(
                i.lat!, i.lng!, widget.depot.lat!, widget.depot.lng!)
            : null;

    return Scaffold(
      appBar: AppBar(
        title: Text('${i.kind.label} · ${i.vehicleDisplay}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _ReviewBanner(review: i.review),
          if (i.photosCleared) ...[
            const SizedBox(height: 8),
            Card(
              margin: EdgeInsets.zero,
              color: theme.colorScheme.surfaceContainerHigh,
              child: ListTile(
                leading: const Icon(Icons.hide_image_outlined),
                title: Text('Photos cleared on '
                    '${DateFormat('d MMM yyyy').format(toScheduleCivil(i.photosClearedAt!))}'
                    '${i.photosClearedBy.isEmpty ? '' : ' by ${i.photosClearedBy}'}'),
                subtitle: const Text(
                    'Removed to free storage. The answers, defects and '
                    'readings are kept.'),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(spacing: 24, runSpacing: 8, children: [
            _Fact('Driver', i.driverName.isEmpty ? '—' : i.driverName),
            _Fact('Date', i.date),
            _Fact('Started', at(i.startedAt)),
            _Fact('Finished', at(i.completedAt)),
            _Fact(
                'Took',
                duration == null
                    ? '—'
                    : '${(duration / 60).toStringAsFixed(1)} min'),
            _Fact('Received', at(i.submittedAt)),
            _Fact(
                'Odometer',
                i.odometerKm == null
                    ? '—'
                    : '${NumberFormat.decimalPattern().format(i.odometerKm)} km'),
            _Fact('Fuel', i.fuelLevel.isEmpty ? '—' : i.fuelLevel),
            if (i.trailer.isNotEmpty) _Fact('Trailer', i.trailer),
          ]),
          if (i.lat != null && i.lng != null) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              icon: const Icon(Icons.place_outlined, size: 18),
              label: Text(depotDistance == null
                  ? 'Where it was done'
                  : 'Where it was done · ${depotDistance < 1000 ? '${depotDistance.round()} m' : '${(depotDistance / 1000).toStringAsFixed(1)} km'} from the depot'),
              onPressed: () => launchUrl(
                Uri.parse('https://www.google.com/maps/search/?api=1'
                    '&query=${i.lat},${i.lng}'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              color: Colors.purple.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Check this inspection',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: Colors.purple.shade800)),
                    for (final f in flags)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Row(children: [
                          Icon(Icons.flag,
                              size: 16, color: Colors.purple.shade700),
                          const SizedBox(width: 6),
                          Text(f.label),
                        ]),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (i.defects.isNotEmpty) ...[
            const SizedBox(height: 12),
            Card(
              color: i.isUnsafe ? Colors.red.shade50 : Colors.orange.shade50,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Defects reported',
                        style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: i.isUnsafe
                                ? Colors.red.shade800
                                : Colors.orange.shade900)),
                    for (final d in i.defects)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                            '${d.severity.label} — ${checklistItemLabel(d.itemId)}'
                            '${d.note.isEmpty ? '' : ': ${d.note}'}'),
                      ),
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          for (final section in kInspectionChecklist) ...[
            Text(section.title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            for (final item in section.items)
              _ItemTile(
                item: item,
                result: i.items[item.id],
                photos: [
                  for (final slot in item.photoSlots)
                    if (i.photos[slot] != null) i.photos[slot]!,
                ],
                service: _service,
              ),
            const SizedBox(height: 8),
          ],
          Text('Dashboard', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          _PhotoRow(
            photos: [
              for (final slot in [...kInspectionFixedSlots, 'spot_check'])
                if (i.photos[slot] != null) i.photos[slot]!,
            ],
            service: _service,
          ),
          if (i.spotCheckPrompt.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Spot check asked for: ${i.spotCheckPrompt}',
                  style: theme.textTheme.bodySmall),
            ),
          const SizedBox(height: 80),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            TextButton.icon(
              icon: const Icon(Icons.restart_alt),
              label: const Text('Redo'),
              onPressed: _busy ? null : _redo,
            ),
            const Spacer(),
            // Once reviewed, the chosen button says so and stays coloured;
            // the other one remains available to change the decision.
            if (rejected)
              FilledButton.icon(
                icon: const Icon(Icons.cancel),
                label: const Text('Rejected'),
                style: FilledButton.styleFrom(
                  disabledBackgroundColor: FleetColors.critical,
                  disabledForegroundColor: Colors.white,
                ),
                onPressed: null,
              )
            else
              OutlinedButton.icon(
                icon: const Icon(Icons.close),
                label: const Text('Reject'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                onPressed: _busy
                    ? null
                    : () => _review(InspectionReviewStatus.rejected),
              ),
            const SizedBox(width: 12),
            FilledButton.icon(
              icon: Icon(approved ? Icons.check_circle : Icons.check),
              label: Text(approved ? 'Approved' : 'Approve'),
              style: approved
                  ? FilledButton.styleFrom(
                      disabledBackgroundColor: FleetColors.good,
                      disabledForegroundColor: Colors.white,
                    )
                  : null,
              onPressed: _busy || approved
                  ? null
                  : () => _review(InspectionReviewStatus.approved),
            ),
          ]),
        ),
      ),
    );
  }
}

class _ReviewBanner extends StatelessWidget {
  final InspectionReview review;
  const _ReviewBanner({required this.review});

  @override
  Widget build(BuildContext context) {
    final (Color color, String text) = switch (review.status) {
      InspectionReviewStatus.approved => (
          Colors.green.shade700,
          'Approved${review.by.isEmpty ? '' : ' by ${review.by}'}'
        ),
      InspectionReviewStatus.rejected => (
          Colors.red.shade700,
          'Rejected${review.by.isEmpty ? '' : ' by ${review.by}'}'
              '${review.comment.isEmpty ? '' : ': ${review.comment}'}'
        ),
      InspectionReviewStatus.pending => (
          Colors.blue.shade700,
          'Waiting for review'
        ),
    };
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontWeight: FontWeight.w600)),
    );
  }
}

class _Fact extends StatelessWidget {
  final String label;
  final String value;
  const _Fact(this.label, this.value);

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      );
}

class _ItemTile extends StatelessWidget {
  final InspectionChecklistItem item;
  final InspectionItemResult? result;
  final List<InspectionPhoto> photos;
  final VehicleInspectionService service;

  const _ItemTile({
    required this.item,
    required this.result,
    required this.photos,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    final r = result;
    final (IconData icon, Color color, String status) = switch (r?.status) {
      InspectionItemStatus.ok => (
          Icons.check_circle,
          Colors.green.shade700,
          'OK'
        ),
      InspectionItemStatus.defect => (
          Icons.warning_amber_rounded,
          Colors.orange.shade800,
          'Defect'
        ),
      InspectionItemStatus.na => (
          Icons.remove_circle_outline,
          Colors.grey,
          'N/A'
        ),
      null => (Icons.help_outline, Colors.grey, 'Not answered'),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(child: Text(item.label)),
              Text(status,
                  style: TextStyle(color: color, fontWeight: FontWeight.w600)),
            ]),
            if (r != null && r.note.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 28),
                child: Text(r.note,
                    style: const TextStyle(fontStyle: FontStyle.italic)),
              ),
            const SizedBox(height: 8),
            _PhotoRow(photos: photos, service: service),
          ],
        ),
      ),
    );
  }
}

class _PhotoRow extends StatelessWidget {
  final List<InspectionPhoto> photos;
  final VehicleInspectionService service;
  const _PhotoRow({required this.photos, required this.service});

  @override
  Widget build(BuildContext context) {
    if (photos.isEmpty) {
      return const Text('No photo',
          style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600));
    }
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in photos) _Thumb(photo: p, service: service),
      ],
    );
  }
}

class _Thumb extends StatelessWidget {
  final InspectionPhoto photo;
  final VehicleInspectionService service;
  const _Thumb({required this.photo, required this.service});

  @override
  Widget build(BuildContext context) {
    final time = photo.capturedAt == null
        ? ''
        : DateFormat('HH:mm:ss').format(toScheduleCivil(photo.capturedAt!));
    return FutureBuilder<String?>(
      future: service.photoUrl(photo.path),
      builder: (context, snap) {
        final url = snap.data;
        final Widget image;
        if (snap.connectionState != ConnectionState.done) {
          image = const Center(
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)));
        } else if (url == null) {
          image = const Center(
              child: Text('Photo no longer stored',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11, color: Colors.grey)));
        } else {
          image = Image.network(url, fit: BoxFit.cover);
        }
        return InkWell(
          onTap: url == null
              ? null
              : () => showDialog<void>(
                    context: context,
                    builder: (dialogContext) => Dialog(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        Flexible(
                          child: InteractiveViewer(child: Image.network(url)),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Text('${inspectionSlotLabel(photo.slot)}'
                              '${time.isEmpty ? '' : ' · taken $time'}'),
                        ),
                      ]),
                    ),
                  ),
          child: Column(children: [
            Container(
              width: 140,
              height: 105,
              clipBehavior: Clip.hardEdge,
              decoration: BoxDecoration(
                color: Colors.grey.shade200,
                borderRadius: BorderRadius.circular(6),
              ),
              child: image,
            ),
            const SizedBox(height: 2),
            SizedBox(
              width: 140,
              child: Text(
                '${inspectionSlotLabel(photo.slot)}${time.isEmpty ? '' : ' · $time'}',
                style: const TextStyle(fontSize: 11),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
        );
      },
    );
  }
}

VehicleInspection _withReview(VehicleInspection i, InspectionReview review) =>
    VehicleInspection(
      id: i.id,
      date: i.date,
      kind: i.kind,
      vehicleKey: i.vehicleKey,
      vehicleLabel: i.vehicleLabel,
      plateNumber: i.plateNumber,
      trailer: i.trailer,
      driverId: i.driverId,
      driverName: i.driverName,
      distributorId: i.distributorId,
      dropsheetTaskId: i.dropsheetTaskId,
      checklistVersion: i.checklistVersion,
      startedAt: i.startedAt,
      completedAt: i.completedAt,
      submittedAt: i.submittedAt,
      odometerKm: i.odometerKm,
      fuelLevel: i.fuelLevel,
      lat: i.lat,
      lng: i.lng,
      accuracyM: i.accuracyM,
      items: i.items,
      photos: i.photos,
      spotCheckPrompt: i.spotCheckPrompt,
      defects: i.defects,
      result: i.result,
      review: review,
      appVersion: i.appVersion,
      photosClearedAt: i.photosClearedAt,
      photosClearedBy: i.photosClearedBy,
    );
