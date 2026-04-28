// widgets/cloud_file_manager_screen.dart
//
// Full-screen Cloud Storage file browser.
// Shows folder tree under Distribution/, lets users navigate, open files
// in the Track Editor, delete files, and upload new ones.
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';

import '../providers/cloud_file_manager_provider.dart';
import '../services/gpx_storage_service.dart';

class CloudFileManagerScreen extends StatefulWidget {
  /// Optional callback when a file is selected to open in the track editor.
  /// Receives (fileName, fileBytes, fullStoragePath).
  final void Function(String fileName, Uint8List bytes, String sourcePath)?
      onOpenInTrackEditor;

  const CloudFileManagerScreen({super.key, this.onOpenInTrackEditor});

  @override
  State<CloudFileManagerScreen> createState() => _CloudFileManagerScreenState();
}

class _CloudFileManagerScreenState extends State<CloudFileManagerScreen> {
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
    _provider.loadCurrentFolder();
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
    final baseName = dot > 0 ? file.name.substring(0, dot) : file.name;
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

    if (newName == null || newName.trim().isEmpty) return;
    if (newName.trim() == file.name) return;

    final resultPath = await _provider.renameFile(file, newName.trim());
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(resultPath == null
            ? (_provider.error ?? 'Rename failed')
            : 'Renamed "$baseName" → "${newName.trim()}"'),
        backgroundColor: resultPath == null ? Colors.red : null,
      ),
    );
  }

  /// Prompts the user to pick a destination folder from every folder under
  /// `Distribution/`. Returns the chosen folder path or `null` if cancelled.
  Future<String?> _pickDestinationFolder({
    required String title,
    required String excludeFolder,
  }) async {
    List<String>? folders;
    // Load folder list in a blocking progress dialog.
    final future = _provider.listAllFolderPaths();
    if (!mounted) return null;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      folders = await future;
    } finally {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    if (!mounted) return null;

    final choices = folders
        .where((p) => p != excludeFolder)
        .toList(); // allow copy-to-self skipped later

    if (choices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No other folders available.')),
      );
      return null;
    }

    String query = '';
    return showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final filtered = query.trim().isEmpty
              ? choices
              : choices
                  .where((p) =>
                      p.toLowerCase().contains(query.trim().toLowerCase()))
                  .toList();
          return AlertDialog(
            title: Text(title),
            content: SizedBox(
              width: 480,
              height: 420,
              child: Column(
                children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: 'Filter folders…',
                      isDense: true,
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setLocal(() => query = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? Center(
                            child: Text('No matches',
                                style: TextStyle(color: Colors.grey[500])))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (_, i) {
                              final path = filtered[i];
                              return ListTile(
                                dense: true,
                                leading: const Icon(Icons.folder,
                                    color: Colors.amber, size: 20),
                                title: Text(path,
                                    style: const TextStyle(fontSize: 13)),
                                onTap: () => Navigator.pop(ctx, path),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Cancel'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _copyFiles(List<StorageFileItem> files) async {
    if (files.isEmpty) return;
    final srcFolder = _provider.currentPath;
    final dest = await _pickDestinationFolder(
      title: 'Copy ${files.length} file${files.length == 1 ? '' : 's'} to…',
      excludeFolder: srcFolder,
    );
    if (dest == null) return;

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }
    final ok = await _provider.copyFiles(files, dest);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Copied $ok of ${files.length} file(s) to $dest'),
        backgroundColor: ok == 0 ? Colors.red : Colors.green,
      ),
    );
    _exitSelectionMode();
  }

  Future<void> _moveFiles(List<StorageFileItem> files) async {
    if (files.isEmpty) return;
    final srcFolder = _provider.currentPath;
    final dest = await _pickDestinationFolder(
      title: 'Move ${files.length} file${files.length == 1 ? '' : 's'} to…',
      excludeFolder: srcFolder,
    );
    if (dest == null) return;

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      );
    }
    final ok = await _provider.moveFiles(files, dest);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Moved $ok of ${files.length} file(s) to $dest'),
        backgroundColor: ok == 0 ? Colors.red : Colors.green,
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
