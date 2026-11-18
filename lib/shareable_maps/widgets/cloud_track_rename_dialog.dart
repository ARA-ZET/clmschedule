import 'package:clmschedule/widgets/app_toast.dart';
import 'package:flutter/material.dart';

import '../../services/gpx_storage_service.dart';
import '../models/map_polyline.dart';
import '../providers/shareable_map_provider.dart';
import '../utils/gpx_track_rename.dart';

/// Rename a track in a cloud tracks layer — e.g. fix the spelling of a
/// distributor's name — straight from the client map, by rewriting the GPX
/// in the layer's folder. Replaces the old round trip through Cloud Files →
/// Track Editor → Update.
///
/// Shows its own progress and a snackbar; returns once it has closed.
Future<void> showCloudTrackRenameDialog(
  BuildContext context, {
  required ShareableMapProvider provider,
  required String layerId,
  required MapPolyline polyline,
}) {
  return showDialog<void>(
    context: context,
    builder: (_) => _CloudTrackRenameDialog(
      provider: provider,
      layerId: layerId,
      polyline: polyline,
      messenger: ScaffoldMessenger.maybeOf(context),
    ),
  );
}

class _CloudTrackRenameDialog extends StatefulWidget {
  final ShareableMapProvider provider;
  final String layerId;
  final MapPolyline polyline;
  final ScaffoldMessengerState? messenger;

  const _CloudTrackRenameDialog({
    required this.provider,
    required this.layerId,
    required this.polyline,
    required this.messenger,
  });

  @override
  State<_CloudTrackRenameDialog> createState() =>
      _CloudTrackRenameDialogState();
}

class _CloudTrackRenameDialogState extends State<_CloudTrackRenameDialog> {
  late final String _oldBase = baseTrackName(widget.polyline.name);
  late final TextEditingController _name =
      TextEditingController(text: _oldBase);

  /// File → on-screen lines, for every file with a track called [_oldBase].
  late final Map<String, int> _filesNamed =
      widget.provider.cloudTrackFilesNamed(widget.layerId, _oldBase);

  bool _allFiles = true;
  bool _renameFiles = true;
  bool _busy = false;
  String? _error;

  String? get _thisFile => widget.polyline.sourceFile;

  Set<String> get _targetFiles => _allFiles
      ? _filesNamed.keys.where((f) => f.isNotEmpty).toSet()
      : {if (_thisFile != null) _thisFile!};

  bool get _anyFileNameHasOld => _targetFiles.any((f) => f.contains(_oldBase));

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _rename() async {
    final newBase = _name.text.trim();
    if (newBase.isEmpty || newBase == _oldBase) {
      Navigator.pop(context);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await widget.provider.renameCloudTracks(
        layerId: widget.layerId,
        oldBase: _oldBase,
        newBase: newBase,
        files: _targetFiles,
        renameFiles: _renameFiles,
      );
      if (!mounted) return;
      Navigator.pop(context);
      final renamedNote = result.filesRenamed > 0
          ? ', ${result.filesRenamed} file name(s) fixed'
          : '';
      widget.messenger?.showToast(SnackBar(
        content: Text(result.files == 0
            ? 'No track called "$_oldBase" found in the cloud files'
            : 'Renamed to "$newBase" in ${result.files} file(s)$renamedNote'),
        backgroundColor: result.files == 0 ? null : Colors.green,
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Rename failed: $e';
        });
      }
    }
  }

  /// This folder's compiled JSON predates the per-track file name — rebuild
  /// it and reload the layer, after which the rename can find the file.
  Future<void> _refreshFolder() async {
    final folder = widget.provider.cloudFolderForLayer(widget.layerId);
    if (folder == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await GpxStorageService().callCompileGpxFolder(folder);
      await widget.provider
          .loadCloudFolderTracks(folderPath: folder, force: true);
      if (!mounted) return;
      Navigator.pop(context);
      widget.messenger?.showToast(const SnackBar(
        content: Text('Folder refreshed — tap the track again to rename it'),
      ));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Refresh failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final fileCount = _filesNamed.keys.where((f) => f.isNotEmpty).length;
    final canRename = _thisFile != null;

    return AlertDialog(
      title: const Text('Rename track'),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!canRename)
              const Text(
                "This folder's track list is from before tracks recorded "
                'their file, so the file to change is unknown. Refresh the '
                'folder, then tap the track again.',
              )
            else ...[
              TextField(
                controller: _name,
                autofocus: true,
                enabled: !_busy,
                decoration: const InputDecoration(
                  labelText: 'Track name',
                  border: OutlineInputBorder(),
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _busy ? null : _rename(),
              ),
              const SizedBox(height: 8),
              Text(
                'Saved into the GPX in the cloud folder, so the new name '
                'shows everywhere this folder is used.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              if (fileCount > 1)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _allFiles,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _allFiles = v ?? true),
                  title: Text('Rename in all $fileCount files '
                      'with a track called "$_oldBase"'),
                  subtitle: _allFiles
                      ? null
                      : const Text('Only the file this track came from'),
                ),
              if (_anyFileNameHasOld)
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: _renameFiles,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _renameFiles = v ?? true),
                  title: const Text('Also fix the name in the file name'),
                  subtitle: const Text(
                      'Reports read the distributor from the file name'),
                ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(_error!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : canRename
                  ? (_name.text.trim().isEmpty ? null : _rename)
                  : _refreshFolder,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(canRename ? 'Rename' : 'Refresh folder'),
        ),
      ],
    );
  }
}
