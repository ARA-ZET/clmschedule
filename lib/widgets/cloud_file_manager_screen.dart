// widgets/cloud_file_manager_screen.dart
//
// Full-screen Cloud Storage file browser.
// Shows folder tree under Distribution/, lets users navigate, open files
// in the Track Editor, delete files, and upload new ones.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';

import '../providers/cloud_file_manager_provider.dart';
import '../providers/cloud_transfer_provider.dart';
import '../services/gpx_storage_service.dart';

class CloudFileManagerScreen extends riverpod.ConsumerStatefulWidget {
  /// Optional callback when a file is selected to open in the track editor.
  /// Receives (fileName, fileBytes, fullStoragePath).
  final void Function(String fileName, Uint8List bytes, String sourcePath)?
      onOpenInTrackEditor;

  /// Optional initial folder path to open directly (e.g. the cloud folder
  /// linked to a shareable map, or `Distribution/2026/Apr 2026`). Must be
  /// under [CloudFileManagerProvider.rootPath]. If null, the browser opens
  /// at the root.
  final String? initialPath;

  const CloudFileManagerScreen({
    super.key,
    this.onOpenInTrackEditor,
    this.initialPath,
  });

  @override
  riverpod.ConsumerState<CloudFileManagerScreen> createState() =>
      _CloudFileManagerScreenState();
}

class _CloudFileManagerScreenState
    extends riverpod.ConsumerState<CloudFileManagerScreen> {
  final CloudFileManagerProvider _provider = CloudFileManagerProvider();

  /// Cache of waypoint counts for _compiled_waypoints.json files,
  /// keyed by the file's fullPath. A null value means the fetch failed.
  final Map<String, int?> _waypointCounts = {};

  /// Paths currently being fetched for waypoint counts (to avoid re-fetch).
  final Set<String> _waypointFetchesInFlight = {};

  /// Selection mode — when true the screen shows a multi-select action bar
  /// and taps on file tiles toggle selection instead of opening.
  bool _selectionMode = false;

  /// Full paths of currently selected files.
  final Set<String> _selectedFilePaths = {};

  static const String _compiledWaypointsFileName = '_compiled_waypoints.json';

  List<StorageFileItem> get _selectedFiles => _provider.files
      .where((f) => _selectedFilePaths.contains(f.fullPath))
      .toList();

  @override
  void initState() {
    super.initState();
    _provider.addListener(_onProviderChanged);
    final initial = widget.initialPath;
    if (initial != null && initial.trim().isNotEmpty) {
      _provider.navigateToPath(initial.trim());
    } else {
      _provider.loadCurrentFolder();
    }
    // Refresh the current folder whenever a background transfer touches it.
    ref.listenManual(cloudTransferRiverpod, (prev, next) {
      final dirty = next.consumeDirtyFolders();
      if (dirty.isEmpty) return;
      if (dirty.contains(_provider.currentPath)) {
        _provider.loadCurrentFolder();
      }
    });
  }

  @override
  void dispose() {
    _provider.removeListener(_onProviderChanged);
    super.dispose();
  }

  void _onProviderChanged() {
    if (mounted) {
      // Prune any selections that no longer exist in the current folder.
      if (_selectedFilePaths.isNotEmpty) {
        final visible = _provider.files.map((f) => f.fullPath).toSet();
        _selectedFilePaths.removeWhere((p) => !visible.contains(p));
        if (_selectedFilePaths.isEmpty) _selectionMode = false;
      }
      setState(() {});
    }
    _scheduleWaypointCountFetches();
  }

  void _toggleSelection(StorageFileItem file) {
    setState(() {
      if (_selectedFilePaths.contains(file.fullPath)) {
        _selectedFilePaths.remove(file.fullPath);
        if (_selectedFilePaths.isEmpty) _selectionMode = false;
      } else {
        _selectedFilePaths.add(file.fullPath);
        _selectionMode = true;
      }
    });
  }

  void _enterSelectionMode([StorageFileItem? initial]) {
    setState(() {
      _selectionMode = true;
      if (initial != null) _selectedFilePaths.add(initial.fullPath);
    });
  }

  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selectedFilePaths.clear();
    });
  }

  void _selectAllVisible() {
    setState(() {
      for (final f in _provider.files) {
        _selectedFilePaths.add(f.fullPath);
      }
      if (_selectedFilePaths.isNotEmpty) _selectionMode = true;
    });
  }

  /// Lazily fetch waypoint counts for any _compiled_waypoints.json files in
  /// the current folder that we haven't already loaded or attempted.
  void _scheduleWaypointCountFetches() {
    for (final file in _provider.files) {
      if (file.name != _compiledWaypointsFileName) continue;
      if (_waypointCounts.containsKey(file.fullPath)) continue;
      if (_waypointFetchesInFlight.contains(file.fullPath)) continue;
      _waypointFetchesInFlight.add(file.fullPath);
      _fetchWaypointCount(file);
    }
  }

  Future<void> _fetchWaypointCount(StorageFileItem file) async {
    try {
      final content = await _provider.downloadFileAsString(file);
      int? count;
      if (content != null && content.isNotEmpty) {
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          final raw = decoded['waypointCount'] ?? decoded['count'];
          if (raw is int) {
            count = raw;
          } else if (raw is num) {
            count = raw.toInt();
          } else if (decoded['waypoints'] is List) {
            count = (decoded['waypoints'] as List).length;
          }
        } else if (decoded is List) {
          count = decoded.length;
        }
      }
      if (!mounted) return;
      setState(() {
        _waypointCounts[file.fullPath] = count;
      });
    } catch (e) {
      debugPrint('Waypoint count fetch failed for ${file.fullPath}: $e');
      if (!mounted) return;
      setState(() {
        _waypointCounts[file.fullPath] = null;
      });
    } finally {
      _waypointFetchesInFlight.remove(file.fullPath);
    }
  }

  // ── File type helpers ───────────────────────────────────────────────────

  IconData _iconForFile(StorageFileItem file) {
    switch (file.extension) {
      case 'gpx':
        return Icons.route;
      case 'kml':
        return Icons.map;
      case 'kmz':
        return Icons.map_outlined;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
        return Icons.image;
      case 'pdf':
        return Icons.picture_as_pdf;
      default:
        return Icons.insert_drive_file;
    }
  }

  Color _colorForFile(StorageFileItem file) {
    switch (file.extension) {
      case 'gpx':
        return Colors.green;
      case 'kml':
      case 'kmz':
        return Colors.blue;
      case 'png':
      case 'jpg':
      case 'jpeg':
      case 'webp':
        return Colors.orange;
      default:
        return Colors.grey;
    }
  }

  bool _canOpenInTrackEditor(StorageFileItem file) {
    return ['gpx', 'kml', 'kmz'].contains(file.extension);
  }

  // ── Actions ─────────────────────────────────────────────────────────────

  Future<void> _openFile(StorageFileItem file) async {
    if (!_canOpenInTrackEditor(file)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Cannot open ${file.extension} files')),
        );
      }
      return;
    }

    final bytes = await _provider.downloadFile(file);
    if (bytes == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to download file')),
        );
      }
      return;
    }

    if (widget.onOpenInTrackEditor != null) {
      widget.onOpenInTrackEditor!(file.name, bytes, file.fullPath);
    } else if (mounted) {
      // Return file data to caller
      Navigator.of(context)
          .pop((fileName: file.name, bytes: bytes, sourcePath: file.fullPath));
    }
  }

  Future<void> _confirmDelete(StorageFileItem file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Delete "${file.name}"?\nThis cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _provider.deleteFile(file);
    }
  }

  Future<void> _confirmDeleteFolder(StorageFolderItem folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder'),
        content: Text(
          'Delete "${folder.name}" and everything inside it?\n\n'
          'All files and subfolders will be permanently removed. '
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete folder'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Show a blocking progress indicator while the recursive delete runs.
    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }
    final removed = await _provider.deleteFolder(folder);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();

    if (mounted) {
      final msg = removed == null
          ? (_provider.error ?? 'Failed to delete folder')
          : 'Deleted "${folder.name}" ($removed file${removed == 1 ? '' : 's'})';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(msg),
          backgroundColor: removed == null ? Colors.red : null,
        ),
      );
    }
  }

  // ── Rename / Copy / Move ───────────────────────────────────────────────

  Future<void> _renameFile(StorageFileItem file) async {
    final dot = file.name.lastIndexOf('.');
    final originalExt = dot > 0 ? file.name.substring(dot) : '';
    final controller = TextEditingController(text: file.name);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename file'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    if (newName == null) return;
    var sanitized = newName.trim();
    if (sanitized.isEmpty) return;
    // Re-attach original extension if the user stripped it off.
    if (originalExt.isNotEmpty &&
        !sanitized.toLowerCase().endsWith(originalExt.toLowerCase())) {
      sanitized = '$sanitized$originalExt';
    }
    if (sanitized == file.name) return;

    final resultPath = await _provider.renameFile(file, sanitized);
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            Icon(
              resultPath == null ? Icons.error_outline : Icons.check_circle,
              color: Colors.white,
              size: 18,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(resultPath == null
                  ? (_provider.error ?? 'Rename failed')
                  : 'Renamed to "$sanitized"'),
            ),
          ],
        ),
        backgroundColor: resultPath == null ? Colors.red : Colors.green,
      ),
    );
  }

  /// Prompts the user to navigate to a destination folder under
  /// `Distribution/`. Returns the chosen folder path or `null` if cancelled.
  /// Uses a hierarchical browser (same folder tree as the main screen) rather
  /// than a flat list of all folders.
  Future<String?> _pickDestinationFolder({
    required CloudTransferOp op,
    required String startFolder,
    required String excludeFolder,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _FolderPickerDialog(
        op: op,
        startFolder: startFolder,
        excludeFolder: excludeFolder,
      ),
    );
  }

  Future<void> _copyFiles(List<StorageFileItem> files) async {
    if (files.isEmpty) return;
    final srcFolder = _provider.currentPath;
    final dest = await _pickDestinationFolder(
      op: CloudTransferOp.copy,
      startFolder: srcFolder,
      excludeFolder: srcFolder,
    );
    if (dest == null || !mounted) return;

    final snapshot = List<StorageFileItem>.from(files);
    ref.read(cloudTransferRiverpod).enqueue(
          op: CloudTransferOp.copy,
          files: snapshot,
          destinationFolder: dest,
        );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Copying ${snapshot.length} file${snapshot.length == 1 ? '' : 's'} '
          'to $dest — you can keep browsing.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    _exitSelectionMode();
  }

  Future<void> _moveFiles(List<StorageFileItem> files) async {
    if (files.isEmpty) return;
    final srcFolder = _provider.currentPath;
    final dest = await _pickDestinationFolder(
      op: CloudTransferOp.move,
      startFolder: srcFolder,
      excludeFolder: srcFolder,
    );
    if (dest == null || !mounted) return;

    final snapshot = List<StorageFileItem>.from(files);
    ref.read(cloudTransferRiverpod).enqueue(
          op: CloudTransferOp.move,
          files: snapshot,
          destinationFolder: dest,
        );

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Moving ${snapshot.length} file${snapshot.length == 1 ? '' : 's'} '
          'to $dest — you can keep browsing.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    _exitSelectionMode();
  }

  Future<void> _deleteMany(List<StorageFileItem> files) async {
    if (files.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            Text('Delete ${files.length} file${files.length == 1 ? '' : 's'}?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }
    final ok = await _provider.deleteFiles(files);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Deleted $ok of ${files.length} file(s)'),
        backgroundColor: ok == 0 ? Colors.red : null,
      ),
    );
    _exitSelectionMode();
  }

  Future<void> _uploadFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowMultiple: true,
      allowedExtensions: ['kml', 'gpx', 'kmz'],
      withData: true,
    );
    if (result == null) return;

    for (final file in result.files) {
      if (file.bytes == null) continue;
      await _provider.uploadFile(
        file.name,
        file.bytes!,
        _contentType(file.name),
      );
    }
  }

  String? _contentType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    switch (ext) {
      case 'gpx':
        return 'application/gpx+xml';
      case 'kml':
        return 'application/vnd.google-earth.kml+xml';
      case 'kmz':
        return 'application/vnd.google-earth.kmz';
      default:
        return null;
    }
  }

  Future<void> _createFolder() async {
    final level = _provider.currentLevel;
    final label = _provider.newFolderLabel;
    final suggestions = _provider.suggestedFolderNames;

    final controller = TextEditingController(
      text: suggestions.isNotEmpty ? suggestions.first : '',
    );

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('New $label'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _hintForLevel(level),
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              decoration: InputDecoration(
                labelText: '$label name',
                border: const OutlineInputBorder(),
                hintText: suggestions.isNotEmpty ? suggestions.first : null,
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            if (suggestions.length > 1) ...[
              const SizedBox(height: 12),
              Text('Suggestions:',
                  style: TextStyle(
                      fontSize: 11,
                      color: Colors.grey[600],
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: suggestions
                    .map(
                      (s) => ActionChip(
                        label: Text(s, style: const TextStyle(fontSize: 12)),
                        onPressed: () => Navigator.pop(ctx, s),
                        visualDensity: VisualDensity.compact,
                      ),
                    )
                    .toList(),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (name != null && name.trim().isNotEmpty) {
      final success = await _provider.createFolder(name.trim());
      if (!success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_provider.error ?? 'Failed to create folder'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _hintForLevel(FolderLevel level) {
    switch (level) {
      case FolderLevel.root:
        return 'Create a year folder (e.g. 2026)';
      case FolderLevel.year:
        return 'Create a month folder (e.g. Apr 2026)';
      case FolderLevel.month:
        return 'Enter the client or distributor name';
      case FolderLevel.client:
        return 'Create a round folder (e.g. Round 1)';
      case FolderLevel.round:
      case FolderLevel.sub:
        return 'Create a subfolder';
    }
  }

  Future<void> _previewGpxFile(StorageFileItem file) async {
    final content = await _provider.downloadFileAsString(file);
    if (content == null || !mounted) return;

    try {
      final gpx = GpxReader().fromString(content);
      final tracks = gpx.trks.length;
      final waypoints = gpx.wpts.length;
      final totalPoints = gpx.trks.fold<int>(
          0,
          (sum, t) =>
              sum + t.trksegs.fold(0, (s, seg) => s + seg.trkpts.length));

      if (!mounted) return;
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(file.name),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _infoRow(Icons.route, 'Tracks', '$tracks'),
              _infoRow(Icons.location_on, 'Waypoints', '$waypoints'),
              _infoRow(Icons.timeline, 'Track points', '$totalPoints'),
              if (gpx.metadata?.time != null)
                _infoRow(Icons.calendar_today, 'Date',
                    gpx.metadata!.time.toString().split('.').first),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            if (widget.onOpenInTrackEditor != null)
              FilledButton.icon(
                onPressed: () {
                  Navigator.pop(ctx);
                  _openFile(file);
                },
                icon: const Icon(Icons.edit, size: 18),
                label: const Text('Open in Track Editor'),
              ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('Preview error: $e');
    }
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 18, color: Colors.grey[600]),
          const SizedBox(width: 8),
          Text('$label: ', style: const TextStyle(fontWeight: FontWeight.w600)),
          Flexible(child: Text(value)),
        ],
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: _selectionMode
          ? _buildSelectionAppBar()
          : AppBar(
              backgroundColor: colorScheme.inversePrimary,
              title: const Text('Cloud Files',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              actions: [
                if (_provider.files.isNotEmpty)
                  IconButton(
                    icon: const Icon(Icons.check_box_outlined),
                    tooltip: 'Select files',
                    onPressed: () => _enterSelectionMode(),
                  ),
                IconButton(
                  icon: const Icon(Icons.create_new_folder),
                  tooltip: 'New ${_provider.newFolderLabel}',
                  onPressed: _createFolder,
                ),
                IconButton(
                  icon: const Icon(Icons.upload_file),
                  tooltip: 'Upload file',
                  onPressed: _uploadFile,
                ),
                IconButton(
                  icon: const Icon(Icons.refresh),
                  tooltip: 'Refresh',
                  onPressed: _provider.loadCurrentFolder,
                ),
              ],
            ),
      body: Column(
        children: [
          _buildBreadcrumbs(colorScheme),
          const Divider(height: 1),
          Expanded(
            child: _provider.isLoading
                ? const Center(child: CircularProgressIndicator())
                : _provider.error != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.error_outline,
                                size: 48, color: Colors.red[300]),
                            const SizedBox(height: 12),
                            Text(_provider.error!,
                                style: TextStyle(color: Colors.red[700])),
                            const SizedBox(height: 12),
                            OutlinedButton(
                              onPressed: _provider.loadCurrentFolder,
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : _buildFolderContents(),
          ),
        ],
      ),
      bottomNavigationBar: const _TransferProgressBanner(),
    );
  }

  PreferredSizeWidget _buildSelectionAppBar() {
    final count = _selectedFilePaths.length;
    final allSelected =
        _provider.files.isNotEmpty && count == _provider.files.length;
    return AppBar(
      backgroundColor: Colors.blueGrey[800],
      foregroundColor: Colors.white,
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'Exit selection',
        onPressed: _exitSelectionMode,
      ),
      title: Text('$count selected'),
      actions: [
        IconButton(
          icon: Icon(allSelected ? Icons.deselect : Icons.select_all),
          tooltip: allSelected ? 'Clear selection' : 'Select all',
          onPressed: allSelected ? _exitSelectionMode : _selectAllVisible,
        ),
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy selected',
          onPressed: count == 0 ? null : () => _copyFiles(_selectedFiles),
        ),
        IconButton(
          icon: const Icon(Icons.drive_file_move),
          tooltip: 'Move selected',
          onPressed: count == 0 ? null : () => _moveFiles(_selectedFiles),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'Delete selected',
          onPressed: count == 0 ? null : () => _deleteMany(_selectedFiles),
        ),
      ],
    );
  }

  Widget _buildBreadcrumbs(ColorScheme colorScheme) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            InkWell(
              onTap: _provider.isAtRoot ? null : () => _provider.goToRoot(),
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                child: Icon(Icons.cloud,
                    size: 20,
                    color: _provider.isAtRoot
                        ? colorScheme.primary
                        : Colors.grey[600]),
              ),
            ),
            for (int i = 0; i < _provider.breadcrumbs.length; i++) ...[
              Icon(Icons.chevron_right, size: 18, color: Colors.grey[400]),
              InkWell(
                onTap: i == _provider.breadcrumbs.length - 1
                    ? null
                    : () => _provider.goToBreadcrumb(i),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Text(
                    _provider.breadcrumbs[i].name,
                    style: TextStyle(
                      fontWeight: i == _provider.breadcrumbs.length - 1
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color: i == _provider.breadcrumbs.length - 1
                          ? colorScheme.primary
                          : Colors.grey[700],
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFolderContents() {
    final hasContent =
        _provider.folders.isNotEmpty || _provider.files.isNotEmpty;

    if (!hasContent) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.folder_open, size: 64, color: Colors.grey[300]),
            const SizedBox(height: 12),
            Text('Empty folder',
                style: TextStyle(color: Colors.grey[500], fontSize: 16)),
            const SizedBox(height: 8),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.create_new_folder, size: 18),
                  label: Text('New ${_provider.newFolderLabel}'),
                  onPressed: _createFolder,
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.upload_file, size: 18),
                  label: const Text('Upload File'),
                  onPressed: _uploadFile,
                ),
              ],
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(8),
      children: [
        // Folders first
        for (final folder in _provider.folders) _buildFolderTile(folder),
        if (_provider.folders.isNotEmpty && _provider.files.isNotEmpty)
          Divider(color: Colors.grey[300], height: 16),
        // Then files
        for (final file in _provider.files) _buildFileTile(file),
      ],
    );
  }

  Widget _buildFolderTile(StorageFolderItem folder) {
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        leading: const Icon(Icons.folder, color: Colors.amber, size: 32),
        title: Text(folder.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Delete folder',
              color: Colors.red[300],
              onPressed: () => _confirmDeleteFolder(folder),
            ),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => _provider.openFolder(folder),
      ),
    );
  }

  Widget _buildFileTile(StorageFileItem file) {
    final canOpen = _canOpenInTrackEditor(file);
    final isCompiledWaypoints = file.name == _compiledWaypointsFileName;
    final waypointCount =
        isCompiledWaypoints ? _waypointCounts[file.fullPath] : null;
    final waypointFetchPending =
        isCompiledWaypoints && !_waypointCounts.containsKey(file.fullPath);
    final isSelected = _selectedFilePaths.contains(file.fullPath);

    final subtitleParts = <String>[
      file.extension.toUpperCase(),
      if (file.lastModified != null)
        DateFormat('dd MMM yyyy HH:mm').format(file.lastModified!),
      if (file.sizeLabel != null) file.sizeLabel!,
    ];
    if (isCompiledWaypoints) {
      if (waypointCount != null) {
        subtitleParts.add('waypoints: $waypointCount');
      } else if (waypointFetchPending) {
        subtitleParts.add('waypoints: …');
      }
    }

    final leading = _selectionMode
        ? Checkbox(
            value: isSelected,
            onChanged: (_) => _toggleSelection(file),
          )
        : Icon(_iconForFile(file), color: _colorForFile(file), size: 28);

    return Card(
      elevation: 0,
      color: isSelected ? Colors.blue[50] : Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: isSelected ? Colors.blue.shade300 : Colors.grey.shade200,
        ),
      ),
      child: ListTile(
        leading: leading,
        title: Text(file.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          subtitleParts.join('  ·  '),
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        trailing: _selectionMode
            ? null
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (file.extension == 'gpx')
                    IconButton(
                      icon: const Icon(Icons.info_outline, size: 20),
                      tooltip: 'Preview',
                      onPressed: () => _previewGpxFile(file),
                    ),
                  if (canOpen)
                    IconButton(
                      icon: const Icon(Icons.open_in_new, size: 20),
                      tooltip: 'Open in Track Editor',
                      color: Colors.blue,
                      onPressed: () => _openFile(file),
                    ),
                  PopupMenuButton<_FileAction>(
                    tooltip: 'More',
                    icon: const Icon(Icons.more_vert, size: 20),
                    onSelected: (action) {
                      switch (action) {
                        case _FileAction.rename:
                          _renameFile(file);
                          break;
                        case _FileAction.copy:
                          _copyFiles([file]);
                          break;
                        case _FileAction.move:
                          _moveFiles([file]);
                          break;
                        case _FileAction.delete:
                          _confirmDelete(file);
                          break;
                        case _FileAction.select:
                          _enterSelectionMode(file);
                          break;
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(
                        value: _FileAction.rename,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.drive_file_rename_outline),
                          title: Text('Rename'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _FileAction.copy,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.copy),
                          title: Text('Copy to…'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _FileAction.move,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.drive_file_move),
                          title: Text('Move to…'),
                        ),
                      ),
                      PopupMenuItem(
                        value: _FileAction.select,
                        child: ListTile(
                          dense: true,
                          leading: Icon(Icons.check_box_outlined),
                          title: Text('Select'),
                        ),
                      ),
                      PopupMenuDivider(),
                      PopupMenuItem(
                        value: _FileAction.delete,
                        child: ListTile(
                          dense: true,
                          leading:
                              Icon(Icons.delete_outline, color: Colors.red),
                          title: Text('Delete',
                              style: TextStyle(color: Colors.red)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
        onTap: _selectionMode
            ? () => _toggleSelection(file)
            : (canOpen ? () => _openFile(file) : null),
        onLongPress: () => _toggleSelection(file),
      ),
    );
  }
}

enum _FileAction { rename, copy, move, delete, select }

// ════════════════════════════════════════════════════════════════════════════
// Folder picker — hierarchical navigator for Move / Copy destination.
// ════════════════════════════════════════════════════════════════════════════

class _FolderPickerDialog extends StatefulWidget {
  final CloudTransferOp op;
  final String startFolder;
  final String excludeFolder;

  const _FolderPickerDialog({
    required this.op,
    required this.startFolder,
    required this.excludeFolder,
  });

  @override
  State<_FolderPickerDialog> createState() => _FolderPickerDialogState();
}

class _FolderPickerDialogState extends State<_FolderPickerDialog> {
  final GpxStorageService _storage = GpxStorageService();
  static const String _root = CloudFileManagerProvider.rootPath;

  late List<({String path, String name})> _breadcrumbs;
  List<StorageFolderItem> _folders = [];
  bool _loading = false;
  String? _error;
  bool _creating = false;

  String get _currentPath => _breadcrumbs.last.path;

  @override
  void initState() {
    super.initState();
    _breadcrumbs = _buildCrumbs(_root);
    _load();
  }

  List<({String path, String name})> _buildCrumbs(String fullPath) {
    final crumbs = <({String path, String name})>[
      (path: _root, name: 'Distribution'),
    ];
    if (fullPath == _root) return crumbs;
    final tail = fullPath.startsWith('$_root/')
        ? fullPath.substring(_root.length + 1)
        : fullPath;
    final segments = tail.split('/').where((s) => s.isNotEmpty).toList();
    var acc = _root;
    for (final seg in segments) {
      acc = '$acc/$seg';
      crumbs.add((path: acc, name: seg));
    }
    return crumbs;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final folders = await _storage.listSubfolders(_currentPath);
      folders
          .sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      if (!mounted) return;
      setState(() {
        _folders = folders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Failed to load folders: $e';
        _loading = false;
      });
    }
  }

  void _openFolder(StorageFolderItem folder) {
    setState(() {
      _breadcrumbs.add((path: folder.fullPath, name: folder.name));
    });
    _load();
  }

  void _jumpTo(int crumbIndex) {
    setState(() {
      _breadcrumbs = _breadcrumbs.sublist(0, crumbIndex + 1);
    });
    _load();
  }

  Future<void> _createSubfolder() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final trimmed = name?.trim();
    if (trimmed == null || trimmed.isEmpty) return;
    setState(() => _creating = true);
    try {
      await _storage.createFolder('$_currentPath/$trimmed');
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Create failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final opLabel =
        widget.op == CloudTransferOp.copy ? 'Copy here' : 'Move here';
    final opColor = widget.op == CloudTransferOp.copy
        ? Colors.blue[700]
        : Colors.deepOrange[700];
    final isExcluded = _currentPath == widget.excludeFolder;
    final isRoot = _currentPath == _root;

    return AlertDialog(
      title: Row(
        children: [
          Icon(widget.op == CloudTransferOp.copy
              ? Icons.file_copy
              : Icons.drive_file_move),
          const SizedBox(width: 8),
          Text(widget.op == CloudTransferOp.copy
              ? 'Copy to folder'
              : 'Move to folder'),
        ],
      ),
      contentPadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      content: SizedBox(
        width: 520,
        height: 460,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Breadcrumbs ─────────────────────────────────────────────
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (int i = 0; i < _breadcrumbs.length; i++) ...[
                    if (i > 0)
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 2),
                        child: Icon(Icons.chevron_right,
                            size: 18, color: Colors.grey),
                      ),
                    InkWell(
                      onTap: i == _breadcrumbs.length - 1
                          ? null
                          : () => _jumpTo(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 4),
                        child: Text(
                          _breadcrumbs[i].name,
                          style: TextStyle(
                            fontWeight: i == _breadcrumbs.length - 1
                                ? FontWeight.bold
                                : FontWeight.w500,
                            color: i == _breadcrumbs.length - 1
                                ? Colors.black87
                                : Colors.blue[700],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const Divider(height: 12),
            // ── Folder list ─────────────────────────────────────────────
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _error != null
                      ? Center(
                          child: Text(_error!,
                              style: TextStyle(color: Colors.red[700])))
                      : _folders.isEmpty
                          ? Center(
                              child: Text('No subfolders here',
                                  style: TextStyle(color: Colors.grey[500])))
                          : ListView.builder(
                              itemCount: _folders.length,
                              itemBuilder: (_, i) {
                                final f = _folders[i];
                                return ListTile(
                                  dense: true,
                                  leading: const Icon(Icons.folder,
                                      color: Colors.amber),
                                  title: Text(f.name,
                                      style: const TextStyle(fontSize: 13)),
                                  trailing:
                                      const Icon(Icons.chevron_right, size: 18),
                                  onTap: () => _openFolder(f),
                                );
                              },
                            ),
            ),
            // ── Current-folder summary ──────────────────────────────────
            Container(
              margin: const EdgeInsets.only(top: 4),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: [
                  const Icon(Icons.my_location,
                      size: 14, color: Colors.black54),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _currentPath,
                      style:
                          const TextStyle(fontSize: 11, color: Colors.black54),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!isRoot)
          TextButton.icon(
            onPressed: () => _jumpTo(_breadcrumbs.length - 2),
            icon: const Icon(Icons.arrow_upward, size: 16),
            label: const Text('Up'),
          ),
        TextButton.icon(
          onPressed: _creating ? null : _createSubfolder,
          icon: _creating
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.create_new_folder, size: 16),
          label: const Text('New folder'),
        ),
        const Spacer(),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed:
              isExcluded ? null : () => Navigator.pop(context, _currentPath),
          icon: Icon(widget.op == CloudTransferOp.copy
              ? Icons.file_copy
              : Icons.drive_file_move),
          label: Text(opLabel),
          style: FilledButton.styleFrom(backgroundColor: opColor),
        ),
      ],
      actionsPadding: const EdgeInsets.fromLTRB(8, 4, 16, 8),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Transfer progress banner — shown at the bottom of the cloud screen while
// any copy/move job is running. Tapping expands a detailed list.
// ════════════════════════════════════════════════════════════════════════════

class _TransferProgressBanner extends riverpod.ConsumerWidget {
  const _TransferProgressBanner();

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    final queue = ref.watch(cloudTransferRiverpod);
    final jobs = queue.jobs;
    if (jobs.isEmpty) return const SizedBox.shrink();

    return Material(
      color: Colors.white,
      elevation: 6,
      child: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: Colors.grey.shade300)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final job in jobs) _JobRow(job: job, queue: queue),
              if (jobs.any((j) => j.isTerminal))
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: queue.dismissAllDone,
                    icon: const Icon(Icons.clear_all, size: 14),
                    label: const Text('Clear finished',
                        style: TextStyle(fontSize: 11)),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _JobRow extends StatelessWidget {
  final CloudTransferJob job;
  final CloudTransferProvider queue;
  const _JobRow({required this.job, required this.queue});

  @override
  Widget build(BuildContext context) {
    final destShort = job.destinationFolder.split('/').last;
    Color barColor;
    IconData icon;
    String statusText;
    switch (job.status) {
      case CloudTransferStatus.pending:
      case CloudTransferStatus.running:
        barColor =
            job.op == CloudTransferOp.copy ? Colors.blue : Colors.deepOrange;
        icon = job.op == CloudTransferOp.copy
            ? Icons.file_copy
            : Icons.drive_file_move;
        final current = job.currentFileName;
        statusText = current != null
            ? '${job.label} ${job.completed + 1}/${job.total}: $current '
                '→ $destShort'
            : '${job.label} ${job.completed}/${job.total} → $destShort';
        break;
      case CloudTransferStatus.done:
        barColor = job.failed == 0 ? Colors.green : Colors.orange;
        icon = job.failed == 0 ? Icons.check_circle : Icons.warning_amber;
        statusText = job.failed == 0
            ? '${job.op == CloudTransferOp.copy ? "Copied" : "Moved"} '
                '${job.completed} file${job.completed == 1 ? '' : 's'} to '
                '$destShort'
            : '${job.completed}/${job.total} done · ${job.failed} failed '
                '($destShort)';
        break;
      case CloudTransferStatus.error:
        barColor = Colors.red;
        icon = Icons.error_outline;
        statusText = job.error ?? 'Transfer failed';
        break;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: InkWell(
        onTap:
            job.failures.isEmpty ? null : () => _showFailureSheet(context, job),
        child: Row(
          children: [
            Icon(icon, size: 16, color: barColor),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(statusText,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),
                      ),
                      if (job.failures.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Text(
                            'tap for details',
                            style: TextStyle(
                                fontSize: 10,
                                color: Colors.red.shade700,
                                fontStyle: FontStyle.italic),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: job.isTerminal ? 1 : job.progress,
                      minHeight: 3,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation(barColor),
                    ),
                  ),
                ],
              ),
            ),
            if (job.isTerminal)
              IconButton(
                icon: const Icon(Icons.close, size: 16),
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
                constraints:
                    const BoxConstraints.tightFor(width: 28, height: 28),
                tooltip: 'Dismiss',
                onPressed: () => queue.dismiss(job),
              ),
          ],
        ),
      ),
    );
  }

  void _showFailureSheet(BuildContext context, CloudTransferJob job) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.warning_amber, color: Colors.orange.shade800),
                  const SizedBox(width: 8),
                  Text(
                    '${job.failures.length} failed',
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: job.failures.length,
                  itemBuilder: (_, i) {
                    final f = job.failures[i];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.error_outline,
                          color: Colors.red, size: 18),
                      title: Text(f.fileName,
                          style: const TextStyle(fontSize: 13)),
                      subtitle: Text(f.message,
                          style: TextStyle(
                              fontSize: 11, color: Colors.red.shade800)),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
