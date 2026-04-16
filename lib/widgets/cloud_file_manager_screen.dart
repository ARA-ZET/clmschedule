// widgets/cloud_file_manager_screen.dart
//
// Full-screen Cloud Storage file browser.
// Shows folder tree under Distribution/, lets users navigate, open files
// in the Track Editor, delete files, and upload new ones.
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:gpx/gpx.dart';
import 'package:intl/intl.dart';

import '../providers/cloud_file_manager_provider.dart';
import '../services/gpx_storage_service.dart';

class CloudFileManagerScreen extends StatefulWidget {
  /// Optional callback when a file is selected to open in the track editor.
  /// Receives (fileName, fileBytes).
  final void Function(String fileName, Uint8List bytes)? onOpenInTrackEditor;

  const CloudFileManagerScreen({super.key, this.onOpenInTrackEditor});

  @override
  State<CloudFileManagerScreen> createState() => _CloudFileManagerScreenState();
}

class _CloudFileManagerScreenState extends State<CloudFileManagerScreen> {
  final CloudFileManagerProvider _provider = CloudFileManagerProvider();

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
    if (mounted) setState(() {});
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
      widget.onOpenInTrackEditor!(file.name, bytes);
    } else if (mounted) {
      // Return file data to caller
      Navigator.of(context).pop((fileName: file.name, bytes: bytes));
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
      appBar: AppBar(
        backgroundColor: colorScheme.inversePrimary,
        title: const Text('Cloud Files',
            style: TextStyle(fontWeight: FontWeight.bold)),
        actions: [
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
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _provider.openFolder(folder),
      ),
    );
  }

  Widget _buildFileTile(StorageFileItem file) {
    final canOpen = _canOpenInTrackEditor(file);
    return Card(
      elevation: 0,
      color: Colors.white,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: Colors.grey.shade200),
      ),
      child: ListTile(
        leading: Icon(_iconForFile(file), color: _colorForFile(file), size: 28),
        title: Text(file.name, style: const TextStyle(fontSize: 14)),
        subtitle: Text(
          [
            file.extension.toUpperCase(),
            if (file.lastModified != null)
              DateFormat('dd MMM yyyy HH:mm').format(file.lastModified!),
          ].join('  ·  '),
          style: TextStyle(fontSize: 11, color: Colors.grey[500]),
        ),
        trailing: Row(
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
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              tooltip: 'Delete',
              color: Colors.red[300],
              onPressed: () => _confirmDelete(file),
            ),
          ],
        ),
        onTap: canOpen ? () => _openFile(file) : null,
      ),
    );
  }
}
