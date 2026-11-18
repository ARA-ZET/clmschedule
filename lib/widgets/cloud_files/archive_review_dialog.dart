// widgets/cloud_files/archive_review_dialog.dart
//
// The hand-off of a month/year archive to the user:
//   1. download the ZIP(s) the server built,
//   2. extract them into their own Google Drive folder,
//   3. confirm — only then are the originals removed from Cloud Files.
// Nothing is removed until step 3, and each ZIP stays downloadable here as a
// safety copy for 30 days afterwards.
//
// ArchivesDialog lists every archive still waiting for that confirmation
// (and recent finished ones), so a user can come back to it later.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/cloud_archive_service.dart';
import '../../utils/web_file_download.dart';

Future<void> showArchiveReviewDialog(
  BuildContext context,
  String batchId, {
  VoidCallback? onRemoved,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) =>
        _ArchiveReviewDialog(batchId: batchId, onRemoved: onRemoved),
  );
}

Future<void> showArchivesDialog(BuildContext context,
    {VoidCallback? onRemoved}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _ArchivesDialog(onRemoved: onRemoved),
  );
}

/// Downloads started in this app session, so the review can say which ZIPs
/// have not been saved yet.
final Set<String> _downloadedThisSession = {};

Future<void> _download(CloudArchive a) async {
  if (a.zipUrl == null) return;
  _downloadedThisSession.add(a.id);
  await triggerUrlDownload(a.zipUrl!, a.zipName ?? '${a.name}.zip');
}

class _ArchiveReviewDialog extends StatefulWidget {
  final String batchId;
  final VoidCallback? onRemoved;
  const _ArchiveReviewDialog({required this.batchId, this.onRemoved});

  @override
  State<_ArchiveReviewDialog> createState() => _ArchiveReviewDialogState();
}

class _ArchiveReviewDialogState extends State<_ArchiveReviewDialog> {
  late final Stream<List<CloudArchive>> _stream =
      CloudArchiveService().watchBatch(widget.batchId);
  bool _saved = false;
  bool _busy = false;
  String? _error;
  List<ArchiveRemoval>? _results;

  Future<void> _downloadAll(List<CloudArchive> ready) async {
    for (final a in ready) {
      await _download(a);
      // Browsers drop rapid back-to-back downloads; space them out.
      await Future<void>.delayed(const Duration(milliseconds: 900));
    }
    if (mounted) setState(() {});
  }

  Future<void> _remove(List<CloudArchive> ready) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final results =
          await CloudArchiveService().confirm(ready.map((a) => a.id).toList());
      if (!mounted) return;
      setState(() => _results = results);
      widget.onRemoved?.call();
    } catch (e) {
      if (mounted) setState(() => _error = describeCloudError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _discard(List<CloudArchive> ready) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard this archive?'),
        content: const Text(
            'The ZIP is deleted and nothing is removed from Cloud Files.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await CloudArchiveService().discard(ready.map((a) => a.id).toList());
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = describeCloudError(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return StreamBuilder<List<CloudArchive>>(
      stream: _stream,
      builder: (context, snap) {
        final docs = snap.data ?? const <CloudArchive>[];
        final parent = docs.where((d) => d.id == widget.batchId).firstOrNull;
        final parts = docs.where((d) => !d.isYearParent).toList();
        final ready = parts.where((p) => p.isReady).toList();
        final building =
            parts.any((p) => p.isBuilding) || (parent?.isBuilding ?? false);
        final title = parent == null ? 'Archive' : 'Archive ${parent.name}';
        final notDownloaded =
            ready.where((a) => !_downloadedThisSession.contains(a.id)).toList();

        Widget step(int n, String heading, Widget body) => Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CircleAvatar(
                    radius: 12,
                    backgroundColor: scheme.primaryContainer,
                    child: Text('$n',
                        style: TextStyle(
                            fontSize: 12, color: scheme.onPrimaryContainer)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(heading,
                            style:
                                const TextStyle(fontWeight: FontWeight.w600)),
                        const SizedBox(height: 6),
                        body,
                      ],
                    ),
                  ),
                ],
              ),
            );

        final results = _results;
        return AlertDialog(
          icon:
              Icon(Icons.inventory_2_outlined, color: scheme.primary, size: 32),
          title: Text(title),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!snap.hasData)
                    const Center(child: CircularProgressIndicator())
                  else if (results != null)
                    _ResultSummary(results: results, parts: parts)
                  else ...[
                    step(
                      1,
                      parts.length > 1
                          ? 'Download the ZIPs (one per month)'
                          : 'Download the ZIP',
                      Column(
                        children: [
                          if (parts.isEmpty && building)
                            const _BuildingRow(label: 'Finding months…'),
                          for (final a in parts) _PartRow(archive: a),
                          if (ready.length > 1)
                            Align(
                              alignment: Alignment.centerLeft,
                              child: TextButton.icon(
                                onPressed: () => _downloadAll(ready),
                                icon: const Icon(Icons.download, size: 18),
                                label: Text('Download all ${ready.length}'),
                              ),
                            ),
                        ],
                      ),
                    ),
                    step(
                      2,
                      'Save it in Google Drive',
                      Text(
                        'Extract ${parts.length > 1 ? 'each ZIP' : 'the ZIP'} '
                        'into whichever Google Drive folder you keep '
                        'archives in (for example Distribution › '
                        '${parts.isEmpty ? 'year' : parts.first.folderPath.split('/')[1]}). '
                        'It holds the month folder with every client\'s '
                        'tracks, photos and other files. Photos already in an '
                        'earlier archive are not included again.',
                        style: TextStyle(color: scheme.onSurfaceVariant),
                      ),
                    ),
                    step(
                      3,
                      'Remove the originals from Cloud Files',
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Compiled map data stays, so maps, distribution '
                            'reports and letterbox counts keep working. '
                            'Photos are copied into the ZIP and also stay in '
                            'Cloud Files — reports link clients to them. The '
                            'ZIP stays downloadable here for 30 days.',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                          CheckboxListTile(
                            contentPadding: EdgeInsets.zero,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: _saved,
                            onChanged: ready.isEmpty || _busy
                                ? null
                                : (v) => setState(() => _saved = v ?? false),
                            title: const Text(
                                'I\'ve saved the ZIP in Google Drive and checked it opens'),
                          ),
                          if (notDownloaded.isNotEmpty && _saved)
                            Text(
                              'Not downloaded in this window: '
                              '${notDownloaded.map((a) => a.name).join(', ')}',
                              style: TextStyle(color: scheme.tertiary),
                            ),
                        ],
                      ),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: scheme.error)),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (results == null && ready.isNotEmpty)
              TextButton(
                onPressed: _busy ? null : () => _discard(ready),
                child: const Text('Discard archive'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  Text(results == null && ready.isNotEmpty ? 'Later' : 'Close'),
            ),
            if (results == null)
              FilledButton.icon(
                onPressed: _saved && ready.isNotEmpty && !_busy
                    ? () => _remove(ready)
                    : null,
                icon: _busy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.delete_sweep_outlined, size: 18),
                label: const Text('Remove originals'),
              ),
          ],
        );
      },
    );
  }
}

class _BuildingRow extends StatelessWidget {
  final String label;
  final double? progress;
  const _BuildingRow({required this.label, this.progress});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            SizedBox(
                width: 18,
                height: 18,
                child:
                    CircularProgressIndicator(strokeWidth: 2, value: progress)),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      );
}

class _PartRow extends StatelessWidget {
  final CloudArchive archive;
  const _PartRow({required this.archive});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final a = archive;
    if (a.isBuilding) {
      return _BuildingRow(
        label: a.stage == 'zipping'
            ? '${a.name} · zipping ${a.zippedFiles} of ${a.totalFiles} files'
            : '${a.name} · preparing…',
        progress: a.buildProgress,
      );
    }
    final String detail;
    switch (a.status) {
      case 'ready':
        detail = '${a.fileCount} files · ${formatBytes(a.sourceBytes)} · '
            'ZIP ${formatBytes(a.zipBytes)}'
            '${a.photoFiles == 0 ? '' : ' · ${a.photoFiles} photo${a.photoFiles == 1 ? '' : 's'} stay in Cloud Files'}';
        break;
      case 'removing':
        detail = 'Removing originals…';
        break;
      case 'archived':
        detail = 'Originals removed (${a.removedFiles} files)'
            '${a.photosKept == 0 ? '' : ' · ${a.photosKept} photo${a.photosKept == 1 ? '' : 's'} kept in Cloud Files'}';
        break;
      case 'empty':
        detail = 'Nothing new to archive — only compiled map data and '
            'photos already archived here';
        break;
      case 'error':
        detail = a.error ?? 'Failed';
        break;
      default:
        detail = a.status;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            a.isError ? Icons.error_outline : Icons.folder_zip_outlined,
            color: a.isError ? scheme.error : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(a.zipName ?? a.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
                Text(detail,
                    style: TextStyle(
                        fontSize: 12,
                        color: a.isError
                            ? scheme.error
                            : scheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (a.canDownload) _DownloadButton(archive: a),
        ],
      ),
    );
  }
}

class _DownloadButton extends StatefulWidget {
  final CloudArchive archive;
  const _DownloadButton({required this.archive});

  @override
  State<_DownloadButton> createState() => _DownloadButtonState();
}

class _DownloadButtonState extends State<_DownloadButton> {
  @override
  Widget build(BuildContext context) {
    final done = _downloadedThisSession.contains(widget.archive.id);
    return done
        ? TextButton.icon(
            onPressed: () async {
              await _download(widget.archive);
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.check, size: 18),
            label: const Text('Downloaded'),
          )
        : FilledButton.tonalIcon(
            onPressed: () async {
              await _download(widget.archive);
              if (mounted) setState(() {});
            },
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download'),
          );
  }
}

class _ResultSummary extends StatelessWidget {
  final List<ArchiveRemoval> results;
  final List<CloudArchive> parts;
  const _ResultSummary({required this.results, required this.parts});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final removed = results.fold<int>(0, (n, r) => n + r.removed);
    final kept = results.fold<int>(0, (n, r) => n + r.kept);
    final photosKept = results.fold<int>(0, (n, r) => n + r.photosKept);
    final bytes = results.fold<int>(0, (n, r) => n + r.removedBytes);
    final errors = results.where((r) => r.error != null).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.check_circle, color: Color(0xFF1E8E3E)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Removed $removed file${removed == 1 ? '' : 's'} '
                '(${formatBytes(bytes)}) from Cloud Files.',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          'Maps keep loading from the compiled data. The archived files still '
          'show in their folders, marked "Archived".',
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
        if (photosKept > 0) ...[
          const SizedBox(height: 10),
          Text(
            '$photosKept photo${photosKept == 1 ? ' is' : 's are'} in the ZIP '
            'and still in Cloud Files, so there is a copy at both ends.',
            style: TextStyle(color: scheme.onSurfaceVariant),
          ),
        ],
        if (kept > 0) ...[
          const SizedBox(height: 10),
          Text(
            '$kept file${kept == 1 ? ' was' : 's were'} changed after the ZIP '
            'was made, so ${kept == 1 ? 'it was' : 'they were'} kept in Cloud '
            'Files. Archive the month again later to include ${kept == 1 ? 'it' : 'them'}.',
            style: TextStyle(color: scheme.tertiary),
          ),
        ],
        for (final e in errors) ...[
          const SizedBox(height: 10),
          Text(
            '${parts.where((p) => p.id == e.id).firstOrNull?.name ?? e.id}: '
            '${e.error} — open Archives and confirm again to finish.',
            style: TextStyle(color: scheme.error),
          ),
        ],
      ],
    );
  }
}

// ── Archives list ─────────────────────────────────────────────────────────

class _ArchivesDialog extends StatelessWidget {
  final VoidCallback? onRemoved;
  const _ArchivesDialog({this.onRemoved});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final service = CloudArchiveService();
    return AlertDialog(
      icon: Icon(Icons.inventory_2_outlined, color: scheme.primary, size: 32),
      title: const Text('Archives'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: StreamBuilder<List<CloudArchive>>(
          stream: service.watchOpen(),
          builder: (context, openSnap) => StreamBuilder<List<CloudArchive>>(
            stream: service.watchArchived(),
            builder: (context, doneSnap) {
              if (!openSnap.hasData && !doneSnap.hasData) {
                if (openSnap.hasError || doneSnap.hasError) {
                  return Center(
                      child: Text(
                          describeCloudError(openSnap.error ?? doneSnap.error!),
                          style: TextStyle(color: scheme.error)));
                }
                return const Center(child: CircularProgressIndicator());
              }
              final open = openSnap.data ?? const <CloudArchive>[];
              final done = [...doneSnap.data ?? const <CloudArchive>[]]..sort(
                  (a, b) => (b.archivedAt ?? DateTime(0))
                      .compareTo(a.archivedAt ?? DateTime(0)));
              final batches = <String, List<CloudArchive>>{};
              for (final a in open) {
                batches.putIfAbsent(a.batchId, () => []).add(a);
              }
              if (batches.isEmpty && done.isEmpty) {
                return Center(
                  child: Text(
                    'No archives yet. Open a year or month folder\'s menu '
                    'and choose "Archive".',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: scheme.onSurfaceVariant),
                  ),
                );
              }
              Widget header(String t) => Padding(
                    padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
                    child: Text(t,
                        style: TextStyle(
                            fontWeight: FontWeight.w600,
                            color: scheme.onSurfaceVariant)),
                  );
              return ListView(
                children: [
                  if (batches.isNotEmpty) header('Waiting for you'),
                  for (final entry in batches.entries)
                    ListTile(
                      leading: Icon(
                          entry.value.any((a) => a.isBuilding)
                              ? Icons.hourglass_top
                              : Icons.inventory_2_outlined,
                          color: scheme.primary),
                      title: Text(_batchLabel(entry.value)),
                      subtitle: Text(entry.value.any((a) => a.isBuilding)
                          ? 'Building the ZIP…'
                          : '${entry.value.where((a) => a.isReady).length} '
                              'ZIP${entry.value.length == 1 ? '' : 's'} ready to '
                              'download · originals not removed yet'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => showArchiveReviewDialog(context, entry.key,
                          onRemoved: onRemoved),
                    ),
                  if (done.isNotEmpty) header('Archived'),
                  for (final a in done.take(36))
                    ListTile(
                      leading: Icon(Icons.inventory_2,
                          color: scheme.onSurfaceVariant),
                      title: Text(a.folderPath
                          .replaceFirst('Distribution/', '')
                          .replaceAll('/', ' › ')),
                      subtitle: Text(
                        '${a.removedFiles} files · '
                        '${formatBytes(a.removedBytes)}'
                        '${a.archivedAt == null ? '' : ' · ${DateFormat('d MMM yyyy').format(a.archivedAt!)}'}'
                        '${a.canDownload && a.expiresAt != null ? ' · ZIP here until ${DateFormat('d MMM').format(a.expiresAt!)}' : ''}',
                      ),
                      trailing: a.canDownload
                          ? IconButton(
                              tooltip: 'Download the ZIP again',
                              icon: const Icon(Icons.download),
                              onPressed: () => _download(a),
                            )
                          : null,
                    ),
                ],
              );
            },
          ),
        ),
      ),
      actions: [
        TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close')),
      ],
    );
  }

  static String _batchLabel(List<CloudArchive> parts) {
    final path = parts.first.folderPath;
    final segs = path.split('/');
    // Months of a year archive share the year's batch.
    if (parts.length > 1 || (parts.first.batchId != parts.first.id)) {
      return segs.length > 1 ? segs[1] : path;
    }
    return segs.skip(1).join(' › ');
  }
}
