// widgets/cloud_file_manager_screen.dart
//
// Full-screen Cloud Storage file browser laid out like Google Drive: a search
// pill, breadcrumb folder menu, "+ New" and filter chips, a sortable
// Name / Location / Date modified / File size table (or a grid), right-click
// and ⋮ menus, a details panel, and a bottom-right activity card.
//
// Besides browsing it opens tracks in the Track Editor, uploads, renames,
// copies/moves, deletes, downloads (one file directly; several files or
// folders as one ZIP built server-side), and archives whole months or years:
// the raw files go into a ZIP the user saves to their own Google Drive, and
// only the compiled map JSON stays here so maps keep loading (see
// services/cloud_archive_service.dart).
import 'package:clmschedule/utils/text_search.dart';
import 'package:clmschedule/widgets/app_toast.dart';
import 'dart:async';
import '../recycle_bin/recycle_bin_entry.dart';
import '../recycle_bin/recycle_bin_screen.dart';
import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show HitTestResult, RenderMetaData;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:gpx/gpx.dart';

import '../providers/cloud_file_manager_provider.dart';
import '../providers/job_list_provider.dart';
import '../services/cloud_archive_service.dart';
import '../services/gpx_storage_service.dart';
import '../utils/browser_file_drop.dart';
import '../utils/web_file_download.dart';
import 'cloud_files/cloud_activity.dart';
import 'cloud_files/cloud_entry.dart';
import 'cloud_files/archive_review_dialog.dart';

class CloudFileManagerScreen extends StatefulWidget {
  /// Optional callback when a file is selected to open in the track editor.
  /// Receives (fileName, fileBytes, fullStoragePath).
  final void Function(String fileName, Uint8List bytes, String sourcePath)?
      onOpenInTrackEditor;

  /// Optional initial folder path to open at, e.g.
  /// `"Distribution/2026/Apr 2026"`. When omitted the browser starts at
  /// the Distribution root.
  final String? initialPath;

  const CloudFileManagerScreen({
    super.key,
    this.onOpenInTrackEditor,
    this.initialPath,
  });

  @override
  State<CloudFileManagerScreen> createState() => _CloudFileManagerScreenState();
}

enum _ViewMode { list, grid }

enum _Act {
  open,
  openEditor,
  preview,
  viewImage,
  download,
  rename,
  copy,
  move,
  archive,
  archiveZip,
  showInFolder,
  info,
  select,
  delete,
}

class _MenuEntry {
  final _Act act;
  final IconData icon;
  final String label;
  final bool danger;
  const _MenuEntry(this.act, this.icon, this.label, {this.danger = false});
}

class _CloudFileManagerScreenState extends State<CloudFileManagerScreen> {
  final CloudFileManagerProvider _provider = CloudFileManagerProvider();
  final CloudActivity _activity = CloudActivity();
  final CloudArchiveService _archives = CloudArchiveService();

  // Remembered for the session, like Drive remembers your layout.
  static _ViewMode _viewMode = _ViewMode.list;
  static bool _detailsOpen = false;
  static SortField _sort = SortField.name;
  static bool _ascending = true;

  TypeFilter _typeFilter = TypeFilter.any;
  ModifiedFilter _modifiedFilter = ModifiedFilter.any;
  LocationFilter _locationFilter = LocationFilter.any;

  /// Selected [CloudEntry.key]s.
  final Set<String> _selected = {};
  String? _anchorKey;
  String? _hoverKey;

  /// Row the arrow keys move from (the last clicked or arrowed-to row).
  String? _cursorKey;
  final ScrollController _listController = ScrollController();

  /// Download URLs for grid thumbnails, fetched once per image.
  final Map<String, Future<String?>> _thumbUrls = {};

  final TextEditingController _searchController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();
  final FocusNode _contentFocus = FocusNode(debugLabel: 'cloudFilesContent');
  Timer? _searchDebounce;
  bool _searchScoped = false;

  StreamSubscription<List<CloudArchive>>? _openArchivesSub;
  StreamSubscription<List<CloudArchive>>? _doneArchivesSub;

  /// Archives still building or waiting for the user to confirm removal.
  List<CloudArchive> _openArchives = const [];

  /// Month folder path → its most recent finished archive.
  Map<String, CloudArchive> _archivedMonths = const {};

  /// Waypoint counts of `_compiled_waypoints.json` files, by full path.
  /// A null value means the fetch failed.
  final Map<String, int?> _waypointCounts = {};
  final Set<String> _waypointFetchesInFlight = {};

  static const String _compiledWaypointsFileName = '_compiled_waypoints.json';

  bool get _searching => _searchController.text.trim().isNotEmpty;

  /// Files dragged in from the computer (web only; null elsewhere).
  BrowserFileDrop? _fileDrop;

  /// True while files from the computer hover over the page.
  bool _dragActive = false;

  /// The folder row or tile under those files; null means the open folder.
  String? _dropFolder;

  @override
  void initState() {
    super.initState();
    _fileDrop = listenForFileDrops(
      onOver: _onDragOver,
      onLeave: _onDragLeave,
      onDrop: _onDrop,
    );
    _provider.addListener(_onProviderChanged);
    _searchFocusNode.addListener(_onSearchFocusChanged);
    final start = widget.initialPath?.trim();
    if (start != null && start.isNotEmpty) {
      _provider.navigateToPath(start);
    } else {
      _provider.goToCurrentMonth();
    }
    _openArchivesSub = _archives.watchOpen().listen(
      (open) {
        if (mounted) setState(() => _openArchives = open);
      },
      onError: (Object e) => debugPrint('watchOpen archives: $e'),
    );
    _doneArchivesSub = _archives.watchArchived().listen(
      (done) {
        final byFolder = <String, CloudArchive>{};
        for (final a in done) {
          final prev = byFolder[a.folderPath];
          if (prev == null ||
              (a.archivedAt ?? DateTime(0))
                  .isAfter(prev.archivedAt ?? DateTime(0))) {
            byFolder[a.folderPath] = a;
          }
        }
        if (mounted) setState(() => _archivedMonths = byFolder);
      },
      onError: (Object e) => debugPrint('watchArchived: $e'),
    );
  }

  @override
  void dispose() {
    _fileDrop?.dispose();
    _provider.removeListener(_onProviderChanged);
    _openArchivesSub?.cancel();
    _doneArchivesSub?.cancel();
    _activity.dispose();
    _searchDebounce?.cancel();
    _searchController.dispose();
    _searchFocusNode.removeListener(_onSearchFocusChanged);
    _searchFocusNode.dispose();
    _contentFocus.dispose();
    _listController.dispose();
    super.dispose();
  }

  void _onSearchFocusChanged() {
    if (mounted) setState(() {});
  }

  void _onProviderChanged() {
    if (!mounted) return;
    if (_selected.isNotEmpty && !_searching) {
      final keys = _folderEntries().map((e) => e.key).toSet();
      _selected.removeWhere((k) => !keys.contains(k));
    }
    setState(() {});
  }

  // ── Archive status ──────────────────────────────────────────────────────

  /// Open archives of [path] itself or, for a year, of its months.
  List<CloudArchive> _openArchivesFor(String path) => _openArchives
      .where((a) => a.folderPath == path || a.folderPath.startsWith('$path/'))
      .toList();

  int get _openBatchCount => _openArchives.map((a) => a.batchId).toSet().length;

  /// "Archived 19 Oct" for a month, "3 months archived" for a year.
  String? _archiveNoteFor(String path) {
    if (!CloudArchiveService.isArchivableFolder(path)) return null;
    final month = _archivedMonths[path];
    if (month != null) {
      return 'Archived ${formatDriveDate(month.archivedAt)}';
    }
    final n = _archivedMonths.keys.where((k) => k.startsWith('$path/')).length;
    return n == 0 ? null : '$n month${n == 1 ? '' : 's'} archived';
  }

  // ── Entries ─────────────────────────────────────────────────────────────

  List<CloudEntry> _folderEntries() => [
        for (final f in _provider.folders)
          CloudEntry.folder(
            f,
            stats: _provider.folderStats[f.fullPath],
            archiveNote: _archiveNoteFor(f.fullPath),
          ),
        for (final f in _provider.files) CloudEntry.file(f),
        for (final a in _provider.archivedFiles) CloudEntry.archived(a),
      ];

  List<CloudEntry> _searchEntries() => [
        for (final r in _provider.searchResults)
          if (r.archived)
            CloudEntry.archived(
              ArchivedFileEntry(
                name: r.name,
                folderPath: r.folderPath,
                sizeBytes: r.sizeBytes,
                archivedAt: r.updatedAt,
                archiveId: r.archiveId,
                zipName: r.zipName,
              ),
              searchFolder: r.folderPath,
            )
          else
            CloudEntry.file(
              StorageFileItem(
                name: r.name,
                fullPath: r.fullPath,
                lastModified: r.updatedAt,
                sizeBytes: r.sizeBytes,
              ),
              searchFolder: r.folderPath,
            ),
      ];

  List<CloudEntry> _visibleEntries() => filterAndSort(
        _searching ? _searchEntries() : _folderEntries(),
        type: _typeFilter,
        modified: _modifiedFilter,
        location: _locationFilter,
        sort: _sort,
        ascending: _ascending,
      );

  List<CloudEntry> get _selectedEntries {
    final all = _searching ? _searchEntries() : _folderEntries();
    return all.where((e) => _selected.contains(e.key)).toList();
  }

  CloudEntry get _currentFolderEntry => CloudEntry.folder(
        StorageFolderItem(
            name: _provider.currentName, fullPath: _provider.currentPath),
      );

  bool get _filtersActive =>
      _typeFilter != TypeFilter.any ||
      _modifiedFilter != ModifiedFilter.any ||
      _locationFilter != LocationFilter.any;

  void _clearFilters() => setState(() {
        _typeFilter = TypeFilter.any;
        _modifiedFilter = ModifiedFilter.any;
        _locationFilter = LocationFilter.any;
      });

  // ── Selection ───────────────────────────────────────────────────────────

  void _clearSelection() {
    if (_selected.isEmpty) return;
    setState(() {
      _selected.clear();
      _anchorKey = null;
    });
  }

  void _selectAll() => setState(() {
        _selected
          ..clear()
          ..addAll(_visibleEntries().map((e) => e.key));
      });

  void _toggle(CloudEntry e) => setState(() {
        if (!_selected.remove(e.key)) _selected.add(e.key);
        _anchorKey = e.key;
      });

  /// Desktop click: select; Ctrl/⌘ toggles; Shift extends from the anchor.
  void _onRowTap(CloudEntry e, List<CloudEntry> visible, bool wide) {
    _contentFocus.requestFocus();
    _cursorKey = e.key;
    if (!wide) {
      if (_selected.isNotEmpty) {
        _toggle(e);
      } else {
        _open(e);
      }
      return;
    }
    final kb = HardwareKeyboard.instance;
    setState(() {
      if (kb.isShiftPressed && _anchorKey != null) {
        final a = visible.indexWhere((x) => x.key == _anchorKey);
        final b = visible.indexWhere((x) => x.key == e.key);
        if (a >= 0 && b >= 0) {
          final lo = a < b ? a : b, hi = a < b ? b : a;
          _selected.addAll(visible.sublist(lo, hi + 1).map((x) => x.key));
          return;
        }
      }
      if (kb.isControlPressed || kb.isMetaPressed) {
        if (!_selected.remove(e.key)) _selected.add(e.key);
        _anchorKey = e.key;
        return;
      }
      _selected
        ..clear()
        ..add(e.key);
      _anchorKey = e.key;
    });
  }

  /// Arrow-key navigation: move the cursor row by [delta] (clamped), select
  /// it — or, with [extend], everything from the anchor to it — and scroll
  /// it into view.
  void _moveCursor(int delta, {bool extend = false}) {
    final visible = _visibleEntries();
    if (visible.isEmpty) return;
    final cur = visible.indexWhere((e) => e.key == (_cursorKey ?? _anchorKey));
    final next = cur < 0
        ? (delta > 0 ? 0 : visible.length - 1)
        : (cur + delta).clamp(0, visible.length - 1);
    final key = visible[next].key;
    setState(() {
      _cursorKey = key;
      final anchor = visible.indexWhere((e) => e.key == _anchorKey);
      if (extend && anchor >= 0) {
        final lo = anchor < next ? anchor : next;
        final hi = anchor < next ? next : anchor;
        _selected
          ..clear()
          ..addAll(visible.sublist(lo, hi + 1).map((e) => e.key));
      } else {
        _selected
          ..clear()
          ..add(key);
        _anchorKey = key;
      }
    });
    _ensureRowVisible(next);
  }

  void _ensureRowVisible(int index) {
    if (_viewMode != _ViewMode.list || !_listController.hasClients) return;
    final extent = MediaQuery.sizeOf(context).width >= 760 ? 48.0 : 64.0;
    final pos = _listController.position;
    final top = index * extent;
    final bottom = top + extent;
    double? target;
    if (top < pos.pixels) {
      target = top;
    } else if (bottom > pos.pixels + pos.viewportDimension - 8) {
      target = bottom - pos.viewportDimension + 8;
    }
    if (target == null) return;
    _listController.animateTo(
      target.clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOut,
    );
  }

  void _goUp() {
    if (_searching || _provider.isAtRoot) return;
    _selected.clear();
    _cursorKey = null;
    _provider.goToBreadcrumb(_provider.breadcrumbs.length - 2);
  }

  void _renameSelected() {
    final sel = _selectedEntries;
    if (sel.length != 1) return;
    final e = sel.first;
    if (e.isFolder) {
      _renameFolder(e.folder!);
    } else if (e.isLiveFile && e.searchFolder == null) {
      _renameFile(e.file!);
    }
  }

  // ── Search ──────────────────────────────────────────────────────────────

  void _onSearchChanged(String value) {
    if (!_searchScoped && value.trim().isNotEmpty) {
      _provider.beginSearch();
      _searchScoped = true;
    }
    _selected.clear();
    setState(() {});
    _searchDebounce?.cancel();
    // Names are filtered in memory after the first fetch, so a short pause
    // is enough to skip mid-word keystrokes.
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      _provider.search(value);
    });
  }

  void _closeSearch() {
    _searchDebounce?.cancel();
    _searchController.clear();
    _searchFocusNode.unfocus();
    _searchScoped = false;
    _selected.clear();
    _provider.clearSearch();
    setState(() {});
  }

  String get _searchScopeLabel {
    final scope =
        _searchScoped ? _provider.searchScopeFolderPath : _provider.currentPath;
    if (scope == CloudFileManagerProvider.rootPath) return 'Distribution';
    final slash = scope.lastIndexOf('/');
    return slash >= 0 ? scope.substring(slash + 1) : scope;
  }

  Future<void> _showInFolder(CloudEntry e) async {
    final folder = e.searchFolder;
    _closeSearch();
    if (folder != null) await _provider.navigateToPath(folder);
    if (!mounted) return;
    setState(() {
      _selected
        ..clear()
        ..add(e.key);
    });
  }

  // ── Waypoint counts ─────────────────────────────────────────────────────

  void _ensureWaypointCount(StorageFileItem file) {
    if (_waypointCounts.containsKey(file.fullPath)) return;
    if (!_waypointFetchesInFlight.add(file.fullPath)) return;
    _fetchWaypointCount(file);
  }

  Future<void> _fetchWaypointCount(StorageFileItem file) async {
    try {
      final content = await _provider.downloadFileAsString(file);
      int? count;
      if (content != null && content.isNotEmpty) {
        final decoded = jsonDecode(content);
        if (decoded is Map<String, dynamic>) {
          final raw = decoded['waypointCount'] ?? decoded['count'];
          if (raw is num) {
            count = raw.toInt();
          } else if (decoded['waypoints'] is List) {
            count = (decoded['waypoints'] as List).length;
          }
        } else if (decoded is List) {
          count = decoded.length;
        }
      }
      if (!mounted) return;
      setState(() => _waypointCounts[file.fullPath] = count);
    } catch (e) {
      debugPrint('Waypoint count fetch failed for ${file.fullPath}: $e');
      if (!mounted) return;
      setState(() => _waypointCounts[file.fullPath] = null);
    } finally {
      _waypointFetchesInFlight.remove(file.fullPath);
    }
  }

  // ── Opening ─────────────────────────────────────────────────────────────

  void _open(CloudEntry e) {
    switch (e.kind) {
      case CloudEntryKind.folder:
        if (_searching) _closeSearch();
        _selected.clear();
        _anchorKey = null;
        _provider.openFolder(e.folder!);
        break;
      case CloudEntryKind.archived:
        _showInfo(e);
        break;
      case CloudEntryKind.file:
        if (e.canOpenInTrackEditor) {
          _openFile(e.file!);
        } else if (e.type == CloudFileType.image) {
          _viewImage(e.file!);
        } else {
          _showInfo(e);
        }
        break;
    }
  }

  Future<void> _openFile(StorageFileItem file) async {
    final bytes = await _provider.downloadFile(file);
    if (bytes == null) {
      _snack('Failed to download file', error: true);
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

  Future<void> _viewImage(StorageFileItem file) async {
    final String url;
    try {
      url = await FirebaseStorage.instance.ref(file.fullPath).getDownloadURL();
    } catch (e) {
      _snack('Could not open image: $e', error: true);
      return;
    }
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(file.name, overflow: TextOverflow.ellipsis),
              trailing: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(ctx),
              ),
            ),
            Flexible(
              child: InteractiveViewer(
                child: Image.network(
                  url,
                  fit: BoxFit.contain,
                  // An <img> element sidesteps bucket CORS on web.
                  webHtmlElementStrategy: WebHtmlElementStrategy.prefer,
                  loadingBuilder: (_, child, p) => p == null
                      ? child
                      : const SizedBox(
                          height: 240,
                          child: Center(child: CircularProgressIndicator())),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Download ────────────────────────────────────────────────────────────

  Future<void> _download(List<CloudEntry> entries) async {
    final files = entries.where((e) => e.isLiveFile).toList();
    final folders = entries.where((e) => e.isFolder).toList();
    if (files.isEmpty && folders.isEmpty) {
      _snack(
          'Archived files are in their archive ZIP — use "Download archive ZIP".');
      return;
    }
    if (files.length == 1 && folders.isEmpty) {
      await _downloadSingle(files.first.file!);
      return;
    }

    final name = folders.length == 1 && files.isEmpty
        ? folders.first.name
        : _provider.currentName;
    final count = files.length + folders.length;
    final item = _activity.start(
      icon: Icons.folder_zip_outlined,
      title: 'Preparing $name.zip',
      detail: 'Zipping $count item${count == 1 ? '' : 's'} in the cloud…',
    );
    try {
      final zip = await _archives.zip(
        files: files.map((e) => e.path).toList(),
        folders: folders.map((e) => e.path).toList(),
        name: name,
      );
      await triggerUrlDownload(zip.url, zip.fileName);
      _activity.update(
        item,
        title: 'Downloaded ${zip.fileName}',
        detail: '${zip.fileCount} files · ${formatBytes(zip.zipBytes)}',
        state: ActivityState.done,
        actionLabel: 'Download again',
        onAction: () => triggerUrlDownload(zip.url, zip.fileName),
      );
    } on FirebaseFunctionsException catch (e) {
      final notDeployed =
          const ['not-found', 'unimplemented', 'internal'].contains(e.code);
      if (notDeployed && folders.length == 1 && files.isEmpty) {
        await _downloadFolderInBrowser(folders.first.folder!, item);
      } else {
        _activity.update(item,
            title: 'Download failed · $name',
            detail: describeCloudError(e),
            state: ActivityState.error);
      }
    } catch (e) {
      _activity.update(item,
          title: 'Download failed · $name',
          detail: '$e',
          state: ActivityState.error);
    }
  }

  Future<void> _downloadSingle(StorageFileItem file) async {
    final item = _activity.start(
      icon: Icons.download,
      title: 'Downloading ${file.name}',
      detail: file.sizeLabel,
    );
    final bytes = await _provider.downloadFile(file);
    if (bytes == null) {
      _activity.update(item,
          title: 'Download failed · ${file.name}',
          detail: 'Could not read the file from Cloud Storage.',
          state: ActivityState.error);
      return;
    }
    final saved = await triggerFileDownload(
        bytes,
        file.name,
        CloudFileManagerProvider.contentTypeFor(file.name) ??
            'application/octet-stream');
    _activity.update(
      item,
      title: 'Downloaded ${file.name}',
      detail: kIsWeb ? formatBytes(bytes.length) : (saved ?? 'Save failed'),
      state:
          (!kIsWeb && saved == null) ? ActivityState.error : ActivityState.done,
    );
  }

  /// Fallback while cloudFilesZip is not deployed: zip in the browser.
  Future<void> _downloadFolderInBrowser(
      StorageFolderItem folder, ActivityItem item) async {
    _activity.update(item, detail: 'Zipping in the browser…');
    void onTask() {
      if (_provider.taskTotal > 0) {
        _activity.update(item,
            detail:
                '${_provider.taskCompleted} of ${_provider.taskTotal} files',
            progress: _provider.taskProgress);
      }
    }

    _provider.addListener(onTask);
    final zipBytes = await _provider.downloadFolderAsZip(folder);
    _provider.removeListener(onTask);
    if (zipBytes == null) {
      _activity.update(item,
          title: 'Download failed · ${folder.name}',
          detail: 'Download failed or folder is empty.',
          state: ActivityState.error);
      return;
    }
    await triggerFileDownload(
        zipBytes, '${folder.name}.zip', 'application/zip');
    _activity.update(item,
        title: 'Downloaded ${folder.name}.zip',
        detail: formatBytes(zipBytes.length),
        state: ActivityState.done);
  }

  // ── Archive ─────────────────────────────────────────────────────────────

  /// Only a whole year (`Distribution/2026`) or month can be archived.
  bool _archivable(CloudEntry e) =>
      e.isFolder && CloudArchiveService.isArchivableFolder(e.path);

  Future<void> _archive(List<CloudEntry> entries) async {
    final folders = entries.where(_archivable).toList();
    if (folders.isEmpty) {
      _snack('Archive a whole year or month — open its folder menu.');
      return;
    }
    final busy = folders.where((f) => _openArchivesFor(f.path).isNotEmpty);
    if (busy.isNotEmpty) {
      _snack('${busy.first.name} already has an archive waiting — '
          'finish it in Archives first.');
      showArchivesDialog(context, onRemoved: _provider.loadCurrentFolder);
      return;
    }
    final hasYear = folders.any((f) => f.path.split('/').length == 2);
    final what = folders.length == 1
        ? folders.first.name
        : '${folders.length} ${hasYear ? 'folders' : 'months'}';

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final scheme = Theme.of(ctx).colorScheme;
        Widget point(IconData icon, String text) => Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 18, color: scheme.primary),
                  const SizedBox(width: 10),
                  Expanded(child: Text(text)),
                ],
              ),
            );
        return AlertDialog(
          icon:
              Icon(Icons.inventory_2_outlined, color: scheme.primary, size: 32),
          title: Text('Archive $what?'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                point(
                    Icons.folder_zip_outlined,
                    'Cloud Files builds a ZIP of every raw file — GPX tracks, '
                    'photos, KML and the rest'
                    '${hasYear ? ', one ZIP per month' : ''}.'),
                point(
                    Icons.download,
                    'You download it and extract it into your own Google '
                    'Drive folder.'),
                point(
                    Icons.delete_sweep_outlined,
                    'Only when you confirm are the originals removed from '
                    'Cloud Files. Until then nothing changes.'),
                point(
                    Icons.map_outlined,
                    'Compiled map data always stays, so maps, distribution '
                    'reports and letterbox counts keep working.'),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton.icon(
              onPressed: () => Navigator.pop(ctx, true),
              icon: const Icon(Icons.folder_zip_outlined, size: 18),
              label: const Text('Create ZIP'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;

    try {
      for (final f in folders) {
        final batch = await _archives.start(f.path);
        _activity.trackArchive(batch, label: f.name, onReview: _review);
      }
      _clearSelection();
    } catch (e) {
      _snack('Could not start the archive: ${describeCloudError(e)}',
          error: true);
    }
  }

  void _review(String batchId) {
    if (!mounted) return;
    showArchiveReviewDialog(context, batchId,
        onRemoved: _provider.loadCurrentFolder);
  }

  /// The ZIP an archived file went into, while its 30-day copy lasts.
  Future<void> _downloadArchiveZip(ArchivedFileEntry a) async {
    final id = a.archiveId;
    if (id == null) {
      _snack('No archive ZIP is recorded for this file.');
      return;
    }
    try {
      final archive = await _archives.get(id);
      if (archive != null && archive.canDownload) {
        await triggerUrlDownload(
            archive.zipUrl!, archive.zipName ?? '${archive.name}.zip');
        return;
      }
      _snack('The ZIP is no longer kept here — look for '
          '"${a.zipName ?? archive?.zipName ?? 'the archive ZIP'}" in your '
          'Google Drive.');
    } catch (e) {
      _snack(describeCloudError(e), error: true);
    }
  }

  // ── Delete ──────────────────────────────────────────────────────────────

  Future<void> _confirmDelete(StorageFileItem file) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Delete "${file.name}"?\nIt goes to the Recycle Bin, '
            'where it can be restored for 30 days.'),
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
      final entryId = await _provider.deleteFile(file);
      if (entryId != null) {
        _snack('Moved "${file.name}" to the Recycle Bin');
      }
    }
  }

  Future<void> _confirmDeleteFolder(StorageFolderItem folder) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Folder'),
        content: Text(
          'Delete "${folder.name}" and everything inside it?\n\n'
          'All files and subfolders go to the Recycle Bin, where they can be '
          'restored for 30 days. Archive ZIPs already saved are not '
          'affected.',
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

    _snack(
      removed == null
          ? (_provider.error ?? 'Failed to delete folder')
          : 'Moved "${folder.name}" to the Recycle Bin ($removed '
              'file${removed == 1 ? '' : 's'})',
      error: removed == null,
    );
  }

  Future<void> _deleteMany(List<StorageFileItem> files) async {
    if (files.isEmpty) return;
    if (files.length == 1) {
      await _confirmDelete(files.first);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title:
            Text('Delete ${files.length} file${files.length == 1 ? '' : 's'}?'),
        content: const Text(
            'They go to the Recycle Bin, where they can be restored for 30 '
            'days.'),
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
      _showTaskProgressDialog();
    }
    final ok = await _provider.deleteFiles(files);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    _snack('Moved $ok of ${files.length} file(s) to the Recycle Bin',
        error: ok == 0);
    _clearSelection();
  }

  void _deleteSelected() {
    final sel = _selectedEntries;
    if (sel.isEmpty || sel.any((e) => !e.isLiveFile)) return;
    _deleteMany(sel.map((e) => e.file!).toList());
  }

  // ── Rename / Copy / Move ───────────────────────────────────────────────

  Future<void> _renameFolder(StorageFolderItem folder,
      {bool isCurrent = false}) async {
    final controller = TextEditingController(text: folder.name);

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Rename folder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'New name',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (v) => Navigator.pop(ctx, v),
            ),
            const SizedBox(height: 10),
            Text(
              'Any maps or jobs linked to this folder will be '
              'updated automatically.',
              style: TextStyle(fontSize: 12, color: Colors.grey[600]),
            ),
          ],
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
    if (newName.trim() == folder.name) return;

    _showTaskProgressDialog();
    final result = await _provider.renameFolder(folder, newName.trim());
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    if (!mounted) return;

    if (result.newPath == null) {
      _snack(_provider.error ?? 'Rename failed', error: true);
      return;
    }
    if (isCurrent) await _provider.navigateToPath(result.newPath!);
    if (!mounted) return;

    if (result.linksError != null) {
      ScaffoldMessenger.of(context).showToast(
        SnackBar(
          content: Text('Renamed "${folder.name}" → "${newName.trim()}", but '
              'the jobs and maps using it still point at the old name: '
              '${result.linksError}'),
          backgroundColor: Colors.orange,
          duration: const Duration(seconds: 10),
        ),
      );
      return;
    }

    final refParts = <String>[];
    if (result.mapsUpdated > 0) {
      refParts.add(
          '${result.mapsUpdated} map${result.mapsUpdated == 1 ? '' : 's'} updated');
    }
    if (result.jobsUpdated > 0) {
      refParts.add(
          '${result.jobsUpdated} job${result.jobsUpdated == 1 ? '' : 's'} updated');
    }
    final suffix = refParts.isEmpty ? '' : ' · ${refParts.join(', ')}';
    _snack('Renamed "${folder.name}" → "${newName.trim()}"$suffix');
  }

  Future<void> _renameFile(StorageFileItem file) async {
    final dot = file.name.lastIndexOf('.');
    final baseName = dot > 0 ? file.name.substring(0, dot) : file.name;
    final controller = TextEditingController(text: file.name);
    // Select the name without its extension, like Drive.
    controller.selection = TextSelection(
        baseOffset: 0, extentOffset: dot > 0 ? dot : file.name.length);

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
    _snack(
      resultPath == null
          ? (_provider.error ?? 'Rename failed')
          : 'Renamed "$baseName" → "${newName.trim()}"',
      error: resultPath == null,
    );
  }

  /// Prompts the user to pick a destination folder by navigating the
  /// folder tree one level at a time (lazy load), instead of loading
  /// every folder under `Distribution/` upfront. Returns the chosen
  /// folder path or `null` if cancelled.
  Future<String?> _pickDestinationFolder({
    required String title,
    required String excludeFolder,
  }) async {
    if (!mounted) return null;
    return showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: SizedBox(
          width: 520,
          height: 520,
          child: _FolderNavigatorPicker(
            title: title,
            rootPath: CloudFileManagerProvider.rootPath,
            rootLabel: 'Distribution',
            excludeFolder: excludeFolder,
            startPath: _provider.currentPath,
            listSubfolders: _provider.listSubfolders,
            onPicked: (path) => Navigator.pop(ctx, path),
            onCancel: () => Navigator.pop(ctx),
          ),
        ),
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
      _showTaskProgressDialog();
    }
    final ok = await _provider.copyFiles(files, dest);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    _snack('Copied $ok of ${files.length} file(s) to $dest', error: ok == 0);
    _clearSelection();
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
      _showTaskProgressDialog();
    }
    final ok = await _provider.moveFiles(files, dest);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();
    _snack('Moved $ok of ${files.length} file(s) to $dest', error: ok == 0);
    _clearSelection();
  }

  // ── Upload / New folder ─────────────────────────────────────────────────

  /// Any file type, like Drive — photos, PDFs and documents as well as
  /// tracks.
  Future<void> _uploadFile() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );
    if (result == null) return;
    await _uploadLocal([
      for (final f in result.files)
        if (f.bytes != null)
          LocalUploadFile(
            relativePath: f.name,
            size: f.size,
            read: () async => f.bytes!,
          ),
    ]);
  }

  /// Drive's "Folder upload": the chosen folder and everything in it,
  /// subfolders included.
  Future<void> _uploadFolder() async {
    final files = await pickFolderForUpload();
    if (files == null) return;
    await _uploadLocal(files);
  }

  /// Upload into [folder], or the open folder when null.
  Future<void> _uploadLocal(List<LocalUploadFile> files,
      {String? folder}) async {
    if (files.isEmpty) {
      _snack('Nothing to upload — no files found.', error: true);
      return;
    }
    final target = folder ?? _provider.currentPath;
    _showTaskProgressDialog();
    final ok = await _provider.uploadFiles(files, folder: target);
    if (mounted) Navigator.of(context, rootNavigator: true).pop();

    final hasGpx = files.any((f) => f.name.toLowerCase().endsWith('.gpx'));
    final tail = hasGpx ? ' Compiling tracks & waypoints in the cloud…' : '';
    _snack(
        'Uploaded $ok of ${files.length} file(s) to '
        '${target.split('/').last}.$tail',
        error: ok == 0);
  }

  // ── Drag and drop from the computer ─────────────────────────────────────

  /// Only the page on top takes drops — not one under a dialog or under a
  /// page opened from here.
  bool get _acceptsDrops =>
      mounted && (ModalRoute.of(context)?.isCurrent ?? true);

  void _onDragOver(Offset position) {
    if (!_acceptsDrops) {
      _onDragLeave();
      return;
    }
    final folder = _folderPathAt(position);
    if (!_dragActive || folder != _dropFolder) {
      setState(() {
        _dragActive = true;
        _dropFolder = folder;
      });
    }
  }

  void _onDragLeave() {
    if (!mounted || !_dragActive) return;
    setState(() {
      _dragActive = false;
      _dropFolder = null;
    });
  }

  Future<void> _onDrop(
      Offset position, Future<List<LocalUploadFile>> pending) async {
    final folder = _acceptsDrops
        ? (_folderPathAt(position) ?? _provider.currentPath)
        : null;
    _onDragLeave();
    if (folder == null) return;
    final files = await pending;
    if (!mounted) return;
    await _uploadLocal(files, folder: folder);
  }

  /// The folder row or tile at [position], found by hit-testing for the
  /// [_FolderDropTarget] each one carries. The browser does not send pointer
  /// moves during a file drag, so hover state cannot answer this.
  String? _folderPathAt(Offset position) {
    final result = HitTestResult();
    WidgetsBinding.instance
        .hitTestInView(result, position, View.of(context).viewId);
    for (final hit in result.path) {
      final target = hit.target;
      if (target is RenderMetaData && target.metaData is _FolderDropTarget) {
        return (target.metaData as _FolderDropTarget).path;
      }
    }
    return null;
  }

  /// Outline and label shown while files hover over the page.
  Widget _buildDropOverlay() {
    final scheme = Theme.of(context).colorScheme;
    final target = (_dropFolder ?? _provider.currentPath).split('/').last;
    return IgnorePointer(
      child: Stack(
        children: [
          if (_dropFolder == null)
            Positioned.fill(
              child: Container(
                margin: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: scheme.primary.withValues(alpha: 0.05),
                  border: Border.all(color: scheme.primary, width: 2),
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 24,
            child: Center(
              child: Material(
                color: scheme.primary,
                elevation: 4,
                borderRadius: BorderRadius.circular(24),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.cloud_upload_outlined,
                          color: scheme.onPrimary, size: 20),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Drop to upload to $target',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: scheme.onPrimary,
                              fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Show a non-dismissable progress dialog driven by the provider's
  /// bulk-task state. The caller is responsible for closing the dialog
  /// (with `Navigator.of(context, rootNavigator: true).pop()`) once the
  /// awaited bulk operation completes.
  void _showTaskProgressDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => _TaskProgressDialog(provider: _provider),
    );
  }

  Future<void> _createFolder() async {
    final level = _provider.currentLevel;
    final label = _provider.newFolderLabel;
    final baseSuggestions = _provider.suggestedFolderNames;

    // At the month level (creating a client folder) merge in distinct
    // client names from the JobList, excluding folders that already exist
    // here so the user only sees actionable suggestions. The merged list
    // becomes the source for live, query-driven filtering inside the dialog.
    final allSuggestions = <String>[];
    final seenLower = <String>{};
    for (final s in baseSuggestions) {
      final t = s.trim();
      if (t.isEmpty) continue;
      if (seenLower.add(t.toLowerCase())) allSuggestions.add(t);
    }
    if (level == FolderLevel.month) {
      final existingLower =
          _provider.folders.map((f) => f.name.toLowerCase()).toSet();
      try {
        final container = riverpod.ProviderScope.containerOf(
          context,
          listen: false,
        );
        final clients = container
            .read(jobListRiverpod)
            .allJobListItems
            .map((j) => j.client.trim())
            .where((c) => c.isNotEmpty)
            .toList();
        for (final c in clients) {
          final lower = c.toLowerCase();
          if (existingLower.contains(lower)) continue;
          if (seenLower.add(lower)) allSuggestions.add(c);
        }
      } catch (e) {
        debugPrint('createFolder: could not read joblist clients: $e');
      }
    }

    final controller = TextEditingController(
      text: baseSuggestions.isNotEmpty ? baseSuggestions.first : '',
    );

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final query = controller.text.trim().toLowerCase();
          // Filter the merged list against whatever the user typed. When
          // the field is empty we show every suggestion.
          final filtered = query.isEmpty
              ? allSuggestions
              : TextSearch(query).rank(allSuggestions, (s) => [s]);
          return AlertDialog(
            title: Text('New $label'),
            content: SizedBox(
              width: 360,
              child: Column(
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
                      hintText: baseSuggestions.isNotEmpty
                          ? baseSuggestions.first
                          : null,
                    ),
                    onChanged: (_) => setLocal(() {}),
                    onSubmitted: (v) => Navigator.pop(ctx, v),
                  ),
                  if (allSuggestions.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    Text(
                      filtered.isEmpty
                          ? 'No matching suggestions'
                          : 'Suggestions:',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.grey[600],
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (filtered.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 200),
                        child: SingleChildScrollView(
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: filtered
                                .take(80)
                                .map(
                                  (s) => ActionChip(
                                    label: Text(
                                      s,
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                    onPressed: () => Navigator.pop(ctx, s),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                )
                                .toList(),
                          ),
                        ),
                      ),
                    ],
                  ],
                ],
              ),
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
          );
        },
      ),
    );

    if (name != null && name.trim().isNotEmpty) {
      final success = await _provider.createFolder(name.trim());
      if (!success) {
        _snack(_provider.error ?? 'Failed to create folder', error: true);
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
      case FolderLevel.sub:
        return 'Create a subfolder';
    }
  }

  // ── GPX preview ─────────────────────────────────────────────────────────

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

  void _snack(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showToast(
      SnackBar(
        content: Text(message),
        backgroundColor: error ? Theme.of(context).colorScheme.error : null,
      ),
    );
  }

  // ── Menus ───────────────────────────────────────────────────────────────

  List<_MenuEntry?> _menuFor(CloudEntry e) {
    switch (e.kind) {
      case CloudEntryKind.folder:
        return [
          const _MenuEntry(_Act.open, Icons.folder_open, 'Open'),
          const _MenuEntry(_Act.download, Icons.download, 'Download'),
          const _MenuEntry(
              _Act.rename, Icons.drive_file_rename_outline, 'Rename'),
          null,
          if (_archivable(e))
            _MenuEntry(_Act.archive, Icons.inventory_2_outlined,
                'Archive ${e.path.split('/').length == 2 ? 'year' : 'month'}…'),
          const _MenuEntry(_Act.info, Icons.info_outline, 'Folder information'),
          null,
          const _MenuEntry(_Act.delete, Icons.delete_outline, 'Delete',
              danger: true),
        ];
      case CloudEntryKind.file:
        return [
          if (e.canOpenInTrackEditor)
            const _MenuEntry(_Act.openEditor, Icons.edit_location_alt,
                'Open in Track Editor'),
          if (e.type == CloudFileType.gpx)
            const _MenuEntry(_Act.preview, Icons.query_stats, 'Preview'),
          if (e.type == CloudFileType.image)
            const _MenuEntry(_Act.viewImage, Icons.image_outlined, 'View'),
          if (e.searchFolder != null)
            const _MenuEntry(
                _Act.showInFolder, Icons.drive_folder_upload, 'Show in folder'),
          const _MenuEntry(_Act.download, Icons.download, 'Download'),
          if (e.searchFolder == null) ...[
            const _MenuEntry(
                _Act.rename, Icons.drive_file_rename_outline, 'Rename'),
            null,
            const _MenuEntry(_Act.copy, Icons.file_copy_outlined, 'Copy to…'),
            const _MenuEntry(
                _Act.move, Icons.drive_file_move_outline, 'Move to…'),
          ],
          null,
          const _MenuEntry(_Act.info, Icons.info_outline, 'File information'),
          const _MenuEntry(_Act.select, Icons.check_box_outlined, 'Select'),
          if (e.searchFolder == null) ...[
            null,
            const _MenuEntry(_Act.delete, Icons.delete_outline, 'Delete',
                danger: true),
          ],
        ];
      case CloudEntryKind.archived:
        return [
          const _MenuEntry(_Act.archiveZip, Icons.folder_zip_outlined,
              'Download archive ZIP'),
          if (e.searchFolder != null)
            const _MenuEntry(
                _Act.showInFolder, Icons.drive_folder_upload, 'Show in folder'),
          null,
          const _MenuEntry(_Act.info, Icons.info_outline, 'File information'),
          const _MenuEntry(_Act.select, Icons.check_box_outlined, 'Select'),
        ];
    }
  }

  List<_MenuEntry?> _menuForSelection(List<CloudEntry> sel) {
    final live = sel.every((e) => e.isLiveFile && e.searchFolder == null);
    return [
      if (sel.any((e) => e.isLiveFile || e.isFolder))
        const _MenuEntry(_Act.download, Icons.download, 'Download'),
      if (live) ...[
        const _MenuEntry(_Act.copy, Icons.file_copy_outlined, 'Copy to…'),
        const _MenuEntry(_Act.move, Icons.drive_file_move_outline, 'Move to…'),
      ],
      null,
      if (sel.any(_archivable))
        const _MenuEntry(_Act.archive, Icons.inventory_2_outlined, 'Archive…'),
      if (live) ...[
        null,
        const _MenuEntry(_Act.delete, Icons.delete_outline, 'Delete',
            danger: true),
      ],
    ];
  }

  Future<void> _showMenuAt(List<_MenuEntry?> entries, Offset global,
      List<CloudEntry> targets) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final local = overlay.globalToLocal(global);
    final scheme = Theme.of(context).colorScheme;
    // Drop leading/trailing/double dividers left by conditional items.
    final cleaned = <_MenuEntry?>[];
    for (final m in entries) {
      if (m == null && (cleaned.isEmpty || cleaned.last == null)) continue;
      cleaned.add(m);
    }
    while (cleaned.isNotEmpty && cleaned.last == null) {
      cleaned.removeLast();
    }
    final act = await showMenu<_Act>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(local.dx, local.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      items: [
        for (final m in cleaned)
          if (m == null)
            const PopupMenuDivider()
          else
            PopupMenuItem<_Act>(
              value: m.act,
              height: 40,
              child: Row(
                children: [
                  Icon(m.icon,
                      size: 20,
                      color: m.danger ? scheme.error : scheme.onSurfaceVariant),
                  const SizedBox(width: 14),
                  Text(m.label,
                      style: TextStyle(color: m.danger ? scheme.error : null)),
                ],
              ),
            ),
      ],
    );
    if (act != null) _perform(act, targets);
  }

  void _onContextMenu(CloudEntry e, Offset global) {
    if (_selected.length > 1 && _selected.contains(e.key)) {
      final sel = _selectedEntries;
      _showMenuAt(_menuForSelection(sel), global, sel);
      return;
    }
    setState(() {
      _selected
        ..clear()
        ..add(e.key);
      _anchorKey = e.key;
    });
    _showMenuAt(_menuFor(e), global, [e]);
  }

  void _perform(_Act act, List<CloudEntry> targets) {
    if (targets.isEmpty) return;
    final e = targets.first;
    final liveFiles =
        targets.where((t) => t.isLiveFile).map((t) => t.file!).toList();
    switch (act) {
      case _Act.open:
        _open(e);
        break;
      case _Act.openEditor:
        if (e.file != null) _openFile(e.file!);
        break;
      case _Act.preview:
        if (e.file != null) _previewGpxFile(e.file!);
        break;
      case _Act.viewImage:
        if (e.file != null) _viewImage(e.file!);
        break;
      case _Act.download:
        _download(targets);
        break;
      case _Act.rename:
        if (e.isFolder) {
          _renameFolder(e.folder!);
        } else if (e.file != null) {
          _renameFile(e.file!);
        }
        break;
      case _Act.copy:
        _copyFiles(liveFiles);
        break;
      case _Act.move:
        _moveFiles(liveFiles);
        break;
      case _Act.archive:
        _archive(targets);
        break;
      case _Act.archiveZip:
        if (e.archived != null) _downloadArchiveZip(e.archived!);
        break;
      case _Act.showInFolder:
        _showInFolder(e);
        break;
      case _Act.info:
        _showInfo(e);
        break;
      case _Act.select:
        _toggle(e);
        break;
      case _Act.delete:
        if (e.isFolder) {
          _confirmDeleteFolder(e.folder!);
        } else {
          _deleteMany(liveFiles);
        }
        break;
    }
  }

  void _showInfo(CloudEntry e) {
    final width = MediaQuery.sizeOf(context).width;
    if (width >= 1000) {
      setState(() {
        _detailsOpen = true;
        if (e.path != _provider.currentPath) {
          _selected
            ..clear()
            ..add(e.key);
        }
      });
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.7,
        child: _buildDetailsFor([e], onClose: () => Navigator.pop(ctx)),
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phone = MediaQuery.sizeOf(context).width < 760;
    final showFab = phone && !_searching && _selected.isEmpty;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: _buildAppBar(scheme),
      // Drive on phones: "New" lives in a corner button, not the toolbar.
      floatingActionButton: showFab
          ? FloatingActionButton.extended(
              onPressed: _showNewSheet,
              icon: const Icon(Icons.add),
              label: const Text('New'),
            )
          : null,
      body: LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 760;
          final canShowDetails = c.maxWidth >= 1000;
          final showDetails = _detailsOpen && canShowDetails;
          return Stack(
            children: [
              Positioned.fill(
                child: Row(
                  children: [
                    Expanded(child: _buildMain(wide, c.maxWidth)),
                    if (canShowDetails)
                      // Slides open/closed instead of popping in.
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 220),
                        curve: Curves.easeOutCubic,
                        width: showDetails ? 341 : 0,
                        child: ClipRect(
                          child: OverflowBox(
                            alignment: Alignment.centerLeft,
                            minWidth: 341,
                            maxWidth: 341,
                            child: Row(
                              children: [
                                VerticalDivider(
                                    width: 1, color: scheme.outlineVariant),
                                SizedBox(
                                  width: 340,
                                  child: _buildDetailsFor(
                                    _selected.isEmpty
                                        ? [_currentFolderEntry]
                                        : _selectedEntries,
                                    current: _selected.isEmpty,
                                    onClose: () =>
                                        setState(() => _detailsOpen = false),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              Positioned(
                right: 16,
                // Clear of the phone "New" button.
                bottom: showFab ? 88 : 16,
                left: wide ? null : 16,
                child: CloudActivityPanel(activity: _activity),
              ),
            ],
          );
        },
      ),
    );
  }

  void _showNewSheet() {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(_newFolderText),
              onTap: () {
                Navigator.pop(ctx);
                _createFolder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Upload files'),
              subtitle: const Text('Photos, tracks, PDFs — any file'),
              onTap: () {
                Navigator.pop(ctx);
                _uploadFile();
              },
            ),
            if (canPickFolderForUpload)
              ListTile(
                leading: const Icon(Icons.drive_folder_upload_outlined),
                title: const Text('Folder upload'),
                onTap: () {
                  Navigator.pop(ctx);
                  _uploadFolder();
                },
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _buildAppBar(ColorScheme scheme) {
    return AppBar(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      titleSpacing: 0,
      toolbarHeight: 64,
      title: Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            height: 46,
            decoration: BoxDecoration(
              color: _searchFocusNode.hasFocus
                  ? scheme.surfaceContainerLowest
                  : scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(28),
              boxShadow: _searchFocusNode.hasFocus
                  ? [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 2,
                          offset: const Offset(0, 1)),
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 4)),
                    ]
                  : const [],
            ),
            child: Row(
              children: [
                const SizedBox(width: 6),
                IconButton(
                  icon: Icon(_searching ? Icons.arrow_back : Icons.search),
                  tooltip: _searching ? 'Close search' : 'Search',
                  onPressed: _searching
                      ? _closeSearch
                      : () => _searchFocusNode.requestFocus(),
                ),
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    focusNode: _searchFocusNode,
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(fontSize: 16),
                    decoration: InputDecoration(
                      hintText: 'Search in $_searchScopeLabel',
                      border: InputBorder.none,
                      isDense: true,
                    ),
                    onSubmitted: (_) => _contentFocus.requestFocus(),
                    onChanged: _onSearchChanged,
                  ),
                ),
                if (_searching)
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Clear search',
                    onPressed: _closeSearch,
                  ),
                const SizedBox(width: 6),
              ],
            ),
          ),
        ),
      ),
      actions: [
        IconButton(
          tooltip: _openBatchCount == 0
              ? 'Archives'
              : 'Archives · $_openBatchCount waiting',
          icon: Badge(
            isLabelVisible: _openBatchCount > 0,
            label: Text('$_openBatchCount'),
            child: const Icon(Icons.inventory_2_outlined),
          ),
          onPressed: () => showArchivesDialog(context,
              onRemoved: _provider.loadCurrentFolder),
        ),
        const RecentlyDeletedButton(tab: RecycleBinTab.cloudFiles),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: _provider.loadCurrentFolder,
        ),
        const SizedBox(width: 8),
      ],
    );
  }

  Widget _buildMain(bool wide, double width) {
    final visible = _visibleEntries();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _searching ? _buildSearchHeader(visible.length) : _buildHeader(wide),
        // Same height either way, so swapping never shifts the list.
        SizedBox(
          height: 56,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 150),
            reverseDuration: const Duration(milliseconds: 100),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.centerLeft,
              children: [...previous, if (current != null) current],
            ),
            transitionBuilder: (child, a) => FadeTransition(
              opacity: a,
              child: ScaleTransition(
                  alignment: Alignment.centerLeft,
                  scale: Tween(begin: 0.98, end: 1.0).animate(a),
                  child: child),
            ),
            child: _selected.isNotEmpty
                ? KeyedSubtree(
                    key: const ValueKey('selection'),
                    child: _buildSelectionBar(wide))
                : KeyedSubtree(
                    key: const ValueKey('toolbar'), child: _buildToolbar(wide)),
          ),
        ),
        SizedBox(
          height: 2,
          child:
              (_provider.isLoading || (_searching && _provider.isSearchLoading))
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null,
        ),
        Expanded(
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): _clearSelection,
              const SingleActivator(LogicalKeyboardKey.delete): _deleteSelected,
              const SingleActivator(LogicalKeyboardKey.keyA, control: true):
                  _selectAll,
              const SingleActivator(LogicalKeyboardKey.keyA, meta: true):
                  _selectAll,
              const SingleActivator(LogicalKeyboardKey.enter): () {
                final sel = _selectedEntries;
                if (sel.length == 1) _open(sel.first);
              },
              const SingleActivator(LogicalKeyboardKey.arrowDown): () =>
                  _moveCursor(1),
              const SingleActivator(LogicalKeyboardKey.arrowUp): () =>
                  _moveCursor(-1),
              const SingleActivator(LogicalKeyboardKey.arrowDown, shift: true):
                  () => _moveCursor(1, extend: true),
              const SingleActivator(LogicalKeyboardKey.arrowUp, shift: true):
                  () => _moveCursor(-1, extend: true),
              const SingleActivator(LogicalKeyboardKey.arrowRight): () {
                if (_viewMode == _ViewMode.grid) _moveCursor(1);
              },
              const SingleActivator(LogicalKeyboardKey.arrowLeft): () {
                if (_viewMode == _ViewMode.grid) _moveCursor(-1);
              },
              const SingleActivator(LogicalKeyboardKey.home): () =>
                  _moveCursor(-(1 << 30)),
              const SingleActivator(LogicalKeyboardKey.end): () =>
                  _moveCursor(1 << 30),
              const SingleActivator(LogicalKeyboardKey.arrowUp, alt: true):
                  _goUp,
              const SingleActivator(LogicalKeyboardKey.arrowUp, meta: true):
                  _goUp,
              const SingleActivator(LogicalKeyboardKey.backspace, meta: true):
                  _deleteSelected,
              const SingleActivator(LogicalKeyboardKey.f2): _renameSelected,
              const SingleActivator(LogicalKeyboardKey.slash): () =>
                  _searchFocusNode.requestFocus(),
            },
            child: Focus(
              focusNode: _contentFocus,
              autofocus: true,
              child: Stack(
                children: [
                  Positioned.fill(child: _buildContent(visible, wide, width)),
                  if (_dragActive) Positioned.fill(child: _buildDropOverlay()),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// "3 folders · 12 files · 48.2 MB · 4 archived" for the open folder.
  String? _folderSummary() {
    final folders = _provider.folders.length;
    final files = _provider.files;
    final archived = _provider.archivedFiles.length;
    if (folders == 0 && files.isEmpty && archived == 0) return null;
    final bytes = files.fold<int>(0, (n, f) => n + (f.sizeBytes ?? 0));
    String n(int v, String one) => '$v $one${v == 1 ? '' : 's'}';
    return [
      if (folders > 0) n(folders, 'folder'),
      if (files.isNotEmpty) n(files.length, 'file'),
      if (bytes > 0) formatBytes(bytes),
      if (archived > 0) '$archived archived',
    ].join(' · ');
  }

  Widget _buildHeader(bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final summary = _folderSummary();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeaderRow(wide),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          child: Padding(
            key: ValueKey(summary),
            padding: const EdgeInsets.fromLTRB(28, 0, 16, 2),
            child: Text(
              summary ?? ' ',
              style: TextStyle(
                fontSize: 12.5,
                color: scheme.onSurfaceVariant,
                fontFeatures: _tabular,
              ),
            ),
          ),
        ),
      ],
    );
  }

  static const _tabular = [FontFeature.tabularFigures()];

  /// "New client folder", "New month folder" — or just "New folder".
  String get _newFolderText {
    final label = _provider.newFolderLabel;
    return label == 'Folder'
        ? 'New folder'
        : 'New ${label.toLowerCase()} folder';
  }

  Widget _buildHeaderRow(bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final crumbs = _provider.breadcrumbs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 8, 0),
      child: Row(
        children: [
          Expanded(
            // Left-aligned like Drive; when the path is too long it scrolls
            // and starts scrolled to the current folder.
            child: LayoutBuilder(
              builder: (context, c) => SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                reverse: true,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: c.maxWidth),
                  child: Row(
                    children: [
                      for (var i = 0; i < crumbs.length - 1; i++) ...[
                        TextButton(
                          onPressed: () {
                            _selected.clear();
                            _cursorKey = null;
                            _provider.goToBreadcrumb(i);
                          },
                          style: TextButton.styleFrom(
                            foregroundColor: scheme.onSurfaceVariant,
                            textStyle: Theme.of(context)
                                .textTheme
                                .titleLarge
                                ?.copyWith(fontWeight: FontWeight.w400),
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                          ),
                          child: Text(crumbs[i].name),
                        ),
                        Icon(Icons.chevron_right,
                            color: scheme.onSurfaceVariant),
                      ],
                      _buildFolderMenuButton(crumbs.last.name),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (wide)
            SegmentedButton<_ViewMode>(
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: const [
                ButtonSegment(
                    value: _ViewMode.list,
                    icon: Icon(Icons.view_list_outlined),
                    tooltip: 'List layout'),
                ButtonSegment(
                    value: _ViewMode.grid,
                    icon: Icon(Icons.grid_view_outlined),
                    tooltip: 'Grid layout'),
              ],
              selected: {_viewMode},
              onSelectionChanged: (s) => setState(() => _viewMode = s.first),
            )
          else
            IconButton(
              tooltip:
                  _viewMode == _ViewMode.list ? 'Grid layout' : 'List layout',
              icon: Icon(_viewMode == _ViewMode.list
                  ? Icons.grid_view_outlined
                  : Icons.view_list_outlined),
              onPressed: () => setState(() => _viewMode =
                  _viewMode == _ViewMode.list
                      ? _ViewMode.grid
                      : _ViewMode.list),
            ),
          IconButton(
            tooltip: 'View details',
            isSelected: _detailsOpen,
            icon: const Icon(Icons.info_outline),
            selectedIcon: const Icon(Icons.info),
            onPressed: () {
              if (MediaQuery.sizeOf(context).width >= 1000) {
                setState(() => _detailsOpen = !_detailsOpen);
              } else {
                final sel = _selectedEntries;
                _showInfo(sel.length == 1 ? sel.first : _currentFolderEntry);
              }
            },
          ),
        ],
      ),
    );
  }

  /// The current folder's name with a ▾ menu of folder actions (Drive's
  /// "Dailies ▾").
  Widget _buildFolderMenuButton(String name) {
    final scheme = Theme.of(context).colorScheme;
    final atRoot = _provider.isAtRoot;
    final current = _currentFolderEntry;
    final archivable = _archivable(current);
    MenuItemButton item(IconData icon, String label, VoidCallback onPressed,
            {bool danger = false}) =>
        MenuItemButton(
          leadingIcon:
              Icon(icon, color: danger ? scheme.error : null, size: 20),
          onPressed: onPressed,
          child: Text(label,
              style: TextStyle(color: danger ? scheme.error : null)),
        );
    return MenuAnchor(
      alignmentOffset: const Offset(0, 4),
      menuChildren: [
        item(Icons.create_new_folder_outlined, _newFolderText, _createFolder),
        item(Icons.upload_file, 'Upload files', _uploadFile),
        if (canPickFolderForUpload)
          item(Icons.drive_folder_upload_outlined, 'Folder upload',
              _uploadFolder),
        if (!atRoot) ...[
          const Divider(height: 1),
          item(Icons.download, 'Download folder', () => _download([current])),
          if (archivable)
            item(
                Icons.inventory_2_outlined,
                'Archive this ${_provider.depth == 2 ? 'year' : 'month'}…',
                () => _archive([current])),
          const Divider(height: 1),
          item(Icons.drive_file_rename_outline, 'Rename',
              () => _renameFolder(current.folder!, isCurrent: true)),
        ],
        item(
            Icons.inventory_2,
            'Archives…',
            () => showArchivesDialog(context,
                onRemoved: _provider.loadCurrentFolder)),
        item(
            Icons.info_outline, 'Folder information', () => _showInfo(current)),
        item(Icons.refresh, 'Refresh', _provider.loadCurrentFolder),
      ],
      builder: (context, controller, _) => TextButton(
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
        style: TextButton.styleFrom(
          foregroundColor: scheme.onSurface,
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          textStyle:
              Theme.of(context).textTheme.headlineSmall?.copyWith(fontSize: 22),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(name),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchHeader(int count) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 16, 4),
      child: Text.rich(
        TextSpan(children: [
          const TextSpan(
              text: 'Search results ', style: TextStyle(fontSize: 20)),
          TextSpan(
            text: _provider.isSearchLoading
                ? 'in $_searchScopeLabel…'
                : '· $count in $_searchScopeLabel',
            style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant),
          ),
        ]),
      ),
    );
  }

  Widget _buildToolbar(bool wide) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Row(
        children: [
          if (!_searching && wide) ...[
            MenuAnchor(
              menuChildren: [
                MenuItemButton(
                  leadingIcon: const Icon(Icons.create_new_folder_outlined),
                  onPressed: _createFolder,
                  child: Text(_newFolderText),
                ),
                MenuItemButton(
                  leadingIcon: const Icon(Icons.upload_file),
                  onPressed: _uploadFile,
                  child: const Text('Upload files'),
                ),
                if (canPickFolderForUpload)
                  MenuItemButton(
                    leadingIcon:
                        const Icon(Icons.drive_folder_upload_outlined),
                    onPressed: _uploadFolder,
                    child: const Text('Folder upload'),
                  ),
              ],
              builder: (context, controller, _) => FilledButton.tonalIcon(
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(Icons.add),
                label: const Text('New'),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
                height: 24,
                child: VerticalDivider(
                    width: 1,
                    color: Theme.of(context).colorScheme.outlineVariant)),
            const SizedBox(width: 12),
          ],
          _FilterMenuChip<TypeFilter>(
            value: _typeFilter,
            any: TypeFilter.any,
            values: TypeFilter.values,
            label: typeFilterLabel,
            icon: typeFilterIcon,
            onChanged: (v) => setState(() => _typeFilter = v),
          ),
          const SizedBox(width: 8),
          _FilterMenuChip<ModifiedFilter>(
            value: _modifiedFilter,
            any: ModifiedFilter.any,
            values: ModifiedFilter.values,
            label: modifiedFilterLabel,
            onChanged: (v) => setState(() => _modifiedFilter = v),
          ),
          const SizedBox(width: 8),
          _FilterMenuChip<LocationFilter>(
            value: _locationFilter,
            any: LocationFilter.any,
            values: LocationFilter.values,
            label: locationFilterLabel,
            icon: (f) => f == LocationFilter.archived
                ? Icons.inventory_2_outlined
                : Icons.cloud_outlined,
            onChanged: (v) => setState(() => _locationFilter = v),
          ),
          if (_filtersActive) ...[
            const SizedBox(width: 4),
            TextButton(
                onPressed: _clearFilters, child: const Text('Clear filters')),
          ],
        ],
      ),
    );
  }

  Widget _buildSelectionBar(bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final sel = _selectedEntries;
    final canDownload = sel.any((e) => e.isLiveFile || e.isFolder);
    final onlyLiveFiles = sel.isNotEmpty &&
        sel.every((e) => e.isLiveFile && e.searchFolder == null);
    final canArchive = sel.any(_archivable);
    final single = sel.length == 1 ? sel.first : null;

    Widget action(IconData icon, String tip, VoidCallback? onPressed) =>
        IconButton(
          icon: Icon(icon, size: 20),
          tooltip: tip,
          onPressed: onPressed,
          visualDensity: VisualDensity.compact,
        );

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
      child: Container(
        height: 44,
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(24),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              action(Icons.close, 'Clear selection', _clearSelection),
              Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Text('${sel.length} selected',
                    style: const TextStyle(
                        fontWeight: FontWeight.w500, fontFeatures: _tabular)),
              ),
              action(Icons.download, 'Download',
                  canDownload ? () => _download(sel) : null),
              action(
                  Icons.drive_file_move_outline,
                  'Move to…',
                  onlyLiveFiles
                      ? () => _moveFiles(sel.map((e) => e.file!).toList())
                      : null),
              action(
                  Icons.file_copy_outlined,
                  'Copy to…',
                  onlyLiveFiles
                      ? () => _copyFiles(sel.map((e) => e.file!).toList())
                      : null),
              if (canArchive)
                action(Icons.inventory_2_outlined, 'Archive…',
                    () => _archive(sel)),
              if (single?.isArchived ?? false)
                action(Icons.folder_zip_outlined, 'Download archive ZIP',
                    () => _downloadArchiveZip(single!.archived!)),
              action(Icons.delete_outline, 'Delete',
                  onlyLiveFiles ? _deleteSelected : null),
              action(Icons.info_outline, 'Details',
                  single == null ? null : () => _showInfo(single)),
              action(Icons.select_all, 'Select all', _selectAll),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent(List<CloudEntry> visible, bool wide, double width) {
    final scheme = Theme.of(context).colorScheme;
    if (!_searching && _provider.error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: scheme.error),
            const SizedBox(height: 12),
            Text(_provider.error!, style: TextStyle(color: scheme.error)),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _provider.loadCurrentFolder,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }
    final loading =
        _searching ? _provider.isSearchLoading : _provider.isLoading;
    final String phase;
    final Widget content;
    if (visible.isEmpty && loading) {
      phase = 'loading';
      content = _SkeletonList(wide: wide);
    } else if (visible.isEmpty) {
      phase = 'empty';
      content = _buildEmptyState();
    } else {
      phase = 'items';
      content = GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _clearSelection,
        child: _viewMode == _ViewMode.grid
            ? _buildGrid(visible, wide)
            : _buildList(visible, wide, width),
      );
    }
    // A new folder, layout or state fades up in place; refreshing the same
    // folder keeps the same key, so rows update without a flash.
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 90),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeIn,
      layoutBuilder: (current, previous) => Stack(
        alignment: Alignment.topCenter,
        children: [...previous, if (current != null) current],
      ),
      transitionBuilder: (child, a) => FadeTransition(
        opacity: a,
        child: SlideTransition(
          position:
              Tween(begin: const Offset(0, 0.01), end: Offset.zero).animate(a),
          child: child,
        ),
      ),
      child: KeyedSubtree(
        key: ValueKey(
            '${_searching ? 'search' : _provider.currentPath}|${_viewMode.name}|$phase'),
        child: content,
      ),
    );
  }

  Widget _buildEmptyState() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final filtered = _filtersActive;
    final (IconData icon, String title, String subtitle) = _searching
        ? (
            Icons.search_off,
            'No files match "${_searchController.text.trim()}"',
            'Check the spelling, or search from Distribution to look in every '
                'folder.',
          )
        : filtered
            ? (
                Icons.filter_alt_off_outlined,
                'Nothing matches these filters',
                'Try a different type or date, or clear the filters.',
              )
            : (
                Icons.folder_open_outlined,
                'This folder is empty',
                kIsWeb
                    ? 'Drag files or folders here, or use Upload. Create a '
                        'folder to organise them.'
                    : 'Upload files, or create a folder to organise them.',
              );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 112,
                height: 112,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHigh,
                  shape: BoxShape.circle,
                ),
                child: Icon(icon,
                    size: 52, color: scheme.primary.withValues(alpha: 0.75)),
              ),
              const SizedBox(height: 20),
              Text(title,
                  textAlign: TextAlign.center,
                  style:
                      text.titleMedium?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              Text(subtitle,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium
                      ?.copyWith(color: scheme.onSurfaceVariant, height: 1.4)),
              const SizedBox(height: 20),
              if (filtered)
                FilledButton.tonal(
                    onPressed: _clearFilters,
                    child: const Text('Clear filters'))
              else if (!_searching)
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.tonalIcon(
                      icon: const Icon(Icons.upload_file, size: 18),
                      label: const Text('Upload files'),
                      onPressed: _uploadFile,
                    ),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.create_new_folder_outlined,
                          size: 18),
                      label: Text(_newFolderText),
                      onPressed: _createFolder,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }

  // ── List layout ─────────────────────────────────────────────────────────

  Widget _buildList(List<CloudEntry> visible, bool wide, double width) {
    final scheme = Theme.of(context).colorScheme;
    final showLocation = wide && width >= 900;
    return Column(
      children: [
        if (wide) _buildTableHeader(visible, showLocation),
        if (wide) Divider(height: 1, color: scheme.outlineVariant),
        Expanded(
          child: ListView.builder(
            controller: _listController,
            padding: const EdgeInsets.only(bottom: 120),
            itemCount: visible.length,
            itemExtent: wide ? 48 : 64,
            itemBuilder: (context, i) => wide
                ? _buildWideRow(visible[i], visible, showLocation)
                : _buildNarrowRow(visible[i], visible),
          ),
        ),
      ],
    );
  }

  Widget _buildTableHeader(List<CloudEntry> visible, bool showLocation) {
    final scheme = Theme.of(context).colorScheme;
    final style = TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: scheme.onSurfaceVariant);
    final allSelected =
        visible.isNotEmpty && visible.every((e) => _selected.contains(e.key));
    Widget sortable(String label, SortField field) {
      final active = _sort == field;
      return InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => setState(() {
          if (active) {
            _ascending = !_ascending;
          } else {
            _sort = field;
            _ascending = field == SortField.name;
          }
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(label,
                  style:
                      style.copyWith(color: active ? scheme.onSurface : null)),
              if (active) ...[
                const SizedBox(width: 4),
                Icon(_ascending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 16, color: scheme.primary),
              ],
            ],
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: SizedBox(
        height: 44,
        child: Row(
          children: [
            SizedBox(
              width: 48,
              child: _selected.isEmpty
                  ? null
                  : Checkbox(
                      value: allSelected
                          ? true
                          : (_selected.isEmpty ? false : null),
                      tristate: true,
                      onChanged: (_) =>
                          allSelected ? _clearSelection() : _selectAll(),
                    ),
            ),
            Expanded(
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: sortable('Name', SortField.name))),
            if (showLocation)
              SizedBox(
                  width: 170,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child:
                        Text(_searching ? 'Folder' : 'Location', style: style),
                  )),
            SizedBox(
                width: 150,
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: sortable('Date modified', SortField.modified))),
            SizedBox(
                width: 110,
                child: Align(
                    alignment: Alignment.centerLeft,
                    child: sortable('File size', SortField.size))),
            SizedBox(width: 48, child: _buildSortMenu()),
          ],
        ),
      ),
    );
  }

  Widget _buildSortMenu() {
    MenuItemButton option(String label, SortField f) => MenuItemButton(
          leadingIcon: Icon(_sort == f ? Icons.check : null, size: 18),
          onPressed: () => setState(() {
            _sort = f;
            _ascending = f == SortField.name;
          }),
          child: Text(label),
        );
    return MenuAnchor(
      menuChildren: [
        option('Name', SortField.name),
        option('Date modified', SortField.modified),
        option('File size', SortField.size),
        const Divider(height: 1),
        MenuItemButton(
          leadingIcon: Icon(_ascending ? Icons.check : null, size: 18),
          onPressed: () => setState(() => _ascending = true),
          child: Text(
              _sort == SortField.name ? 'A to Z' : 'Oldest / smallest first'),
        ),
        MenuItemButton(
          leadingIcon: Icon(!_ascending ? Icons.check : null, size: 18),
          onPressed: () => setState(() => _ascending = false),
          child: Text(
              _sort == SortField.name ? 'Z to A' : 'Newest / largest first'),
        ),
      ],
      builder: (context, controller, _) => IconButton(
        icon: const Icon(Icons.sort),
        tooltip: 'Sort',
        onPressed: () =>
            controller.isOpen ? controller.close() : controller.open(),
      ),
    );
  }

  /// Hover, click/double-click, right-click and long-press for one item, on
  /// a Material surface so hover and press get ink rather than a hard swap.
  /// Rows are not focus stops themselves: the arrow keys move the selection
  /// (see [_moveCursor]) while the list keeps focus.
  Widget _interactive(
    CloudEntry e,
    List<CloudEntry> visible,
    bool wide,
    Widget Function(bool selected, bool hovered) builder, {
    double radius = 10,
    Color? baseColor,
    EdgeInsetsGeometry margin = EdgeInsets.zero,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final selected = _selected.contains(e.key);
    final hovered = _hoverKey == e.key;
    final dropPath = e.isFolder ? e.folder?.fullPath : null;
    final dropHere = _dragActive && dropPath != null && dropPath == _dropFolder;
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(radius),
      side: dropHere
          ? BorderSide(color: scheme.primary, width: 2)
          : BorderSide.none,
    );
    final row = Padding(
      padding: margin,
      child: Material(
        color: dropHere
            ? scheme.primaryContainer
            : selected
                ? scheme.secondaryContainer
                : (baseColor ?? Colors.transparent),
        shape: shape,
        clipBehavior: Clip.antiAlias,
        animationDuration: const Duration(milliseconds: 120),
        child: InkWell(
          customBorder: shape,
          canRequestFocus: false,
          mouseCursor: SystemMouseCursors.click,
          hoverColor: scheme.onSurface.withValues(alpha: 0.05),
          highlightColor: scheme.onSurface.withValues(alpha: 0.06),
          splashColor: scheme.primary.withValues(alpha: 0.10),
          onHover: (h) {
            if (h && _hoverKey != e.key) {
              setState(() => _hoverKey = e.key);
            } else if (!h && _hoverKey == e.key) {
              setState(() => _hoverKey = null);
            }
          },
          onTap: () => _onRowTap(e, visible, wide),
          onDoubleTap: wide ? () => _open(e) : null,
          onLongPress: () => _toggle(e),
          onSecondaryTapDown: (d) => _onContextMenu(e, d.globalPosition),
          child: builder(selected, hovered),
        ),
      ),
    );
    if (dropPath == null) return row;
    // Lets a file drag from the computer find the folder under it.
    return MetaData(
      metaData: _FolderDropTarget(dropPath),
      behavior: HitTestBehavior.translucent,
      child: row,
    );
  }

  /// One-click actions that appear on a hovered row, like Drive's.
  Widget _quickActions(CloudEntry e) {
    Widget b(IconData icon, String tip, VoidCallback onPressed) => IconButton(
          icon: Icon(icon, size: 19),
          tooltip: tip,
          onPressed: onPressed,
          style: IconButton.styleFrom(
            minimumSize: const Size(36, 36),
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        );
    final buttons = <Widget>[
      if (e.canOpenInTrackEditor)
        b(Icons.edit_location_alt_outlined, 'Open in Track Editor',
            () => _openFile(e.file!)),
      if (e.isLiveFile || e.isFolder)
        b(Icons.download_outlined, 'Download', () => _download([e])),
      if (e.isLiveFile && e.searchFolder == null)
        b(Icons.drive_file_rename_outline, 'Rename',
            () => _renameFile(e.file!)),
      if (_archivable(e))
        b(Icons.inventory_2_outlined, 'Archive…', () => _archive([e])),
      if (e.isArchived)
        b(Icons.folder_zip_outlined, 'Download archive ZIP',
            () => _downloadArchiveZip(e.archived!)),
    ];
    return Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }

  /// The name, with its full text on hover when it is cut off.
  Widget _nameText(CloudEntry e, TextStyle style) => Tooltip(
        message: e.name,
        waitDuration: const Duration(milliseconds: 700),
        child: Text(e.name,
            maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
      );

  Widget _kebab(CloudEntry e) {
    return Builder(
      builder: (bctx) => IconButton(
        icon: const Icon(Icons.more_vert, size: 20),
        tooltip: 'More actions',
        onPressed: () {
          final box = bctx.findRenderObject() as RenderBox;
          _onContextMenu(
              e, box.localToGlobal(box.size.bottomLeft(Offset.zero)));
        },
      ),
    );
  }

  Widget _entryIcon(CloudEntry e, {double size = 24}) {
    final scheme = Theme.of(context).colorScheme;
    final icon = Icon(cloudTypeIcon(e.type),
        size: size, color: cloudTypeColor(e.type, scheme));
    if (!e.inArchive) return icon;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        icon,
        Positioned(
          right: -4,
          bottom: -4,
          child: Container(
            padding: const EdgeInsets.all(1),
            decoration:
                BoxDecoration(color: scheme.surface, shape: BoxShape.circle),
            child: Icon(Icons.inventory_2,
                size: size * 0.55, color: scheme.tertiary),
          ),
        ),
      ],
    );
  }

  /// Small tags after the name: busy job, waypoint count, compiled marker.
  List<Widget> _nameBadges(CloudEntry e) {
    final scheme = Theme.of(context).colorScheme;
    Widget pill(String text, {Widget? leading, String? tooltip}) {
      final chip = Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 4)],
            Text(text,
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ],
        ),
      );
      return tooltip == null ? chip : Tooltip(message: tooltip, child: chip);
    }

    final out = <Widget>[];
    final open = e.isFolder ? _openArchivesFor(e.path) : const <CloudArchive>[];
    if (open.any((a) => a.isBuilding || a.isRemoving)) {
      out.add(pill(
        open.any((a) => a.isRemoving) ? 'Removing…' : 'Zipping…',
        leading: const SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5)),
      ));
    } else if (open.any((a) => a.isReady)) {
      out.add(pill('ZIP ready',
          leading:
              Icon(Icons.folder_zip_outlined, size: 12, color: scheme.primary),
          tooltip: 'Download it and confirm in Archives to remove the '
              'originals'));
    }
    if (e.archiveNote != null) {
      out.add(pill(e.archiveNote!,
          leading: Icon(Icons.inventory_2_outlined,
              size: 12, color: scheme.onSurfaceVariant)));
    } else if (e.isFolder &&
        (e.stats?.archivedFiles ?? 0) > 0 &&
        !e.inArchive) {
      out.add(pill('${e.stats!.archivedFiles} archived',
          tooltip: 'Some files in this folder were moved into an archive ZIP'));
    }
    if (e.isCompiled) {
      final count =
          e.name == _compiledWaypointsFileName ? _waypointCounts[e.path] : null;
      out.add(pill(count != null ? '$count waypoints' : 'Map data',
          tooltip: 'Compiled from the GPX files — maps load this. '
              'It stays in Cloud Files when the folder is archived.'));
    }
    return out;
  }

  Widget _locationCell(CloudEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final String text;
    final IconData icon;
    if (e.searchFolder != null) {
      text = e.searchFolder!
          .replaceFirst('${CloudFileManagerProvider.rootPath}/', '');
      icon = e.isArchived ? Icons.inventory_2_outlined : Icons.folder_outlined;
    } else if (e.isArchived || e.inArchive) {
      text = 'Archived (ZIP)';
      icon = Icons.inventory_2_outlined;
    } else if (e.isFolder &&
        ((e.stats?.archivedFiles ?? 0) > 0 || e.archiveNote != null)) {
      text = 'Cloud + archive';
      icon = Icons.cloud_sync_outlined;
    } else {
      text = 'Cloud Files';
      icon = Icons.cloud_outlined;
    }
    return Row(
      children: [
        Icon(icon, size: 16, color: scheme.onSurfaceVariant),
        const SizedBox(width: 6),
        Flexible(
          child: Text(text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant)),
        ),
      ],
    );
  }

  String _sizeText(CloudEntry e) {
    if (e.isFolder) {
      final s = e.stats;
      if (s == null || s.totalBytes == 0) return '—';
      return formatBytes(s.liveBytes > 0 ? s.liveBytes : s.archivedBytes);
    }
    return formatBytes(e.sizeBytes);
  }

  Widget _buildWideRow(
      CloudEntry e, List<CloudEntry> visible, bool showLocation) {
    final scheme = Theme.of(context).colorScheme;
    final muted = TextStyle(
        fontSize: 13, color: scheme.onSurfaceVariant, fontFeatures: _tabular);
    return _interactive(
      e,
      visible,
      true,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      (selected, hovered) {
        final showCheck = selected || hovered || _selected.isNotEmpty;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: selected || hovered
              ? null
              : BoxDecoration(
                  border: Border(
                      bottom: BorderSide(
                          color: scheme.outlineVariant.withValues(alpha: 0.5),
                          width: 0.5))),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Center(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 120),
                    transitionBuilder: (c, a) => FadeTransition(
                        opacity: a,
                        child: ScaleTransition(
                            scale: Tween(begin: 0.8, end: 1.0).animate(a),
                            child: c)),
                    child: showCheck
                        ? Checkbox(
                            key: const ValueKey('check'),
                            value: selected,
                            onChanged: (_) => _toggle(e),
                          )
                        : KeyedSubtree(
                            key: const ValueKey('icon'), child: _entryIcon(e)),
                  ),
                ),
              ),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: _nameText(
                        e,
                        TextStyle(
                          fontSize: 14,
                          fontWeight:
                              e.isFolder ? FontWeight.w500 : FontWeight.normal,
                        ),
                      ),
                    ),
                    ..._nameBadges(e),
                  ],
                ),
              ),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 120),
                child: hovered && _selected.length <= 1
                    ? KeyedSubtree(
                        key: const ValueKey('quick'), child: _quickActions(e))
                    : const SizedBox.shrink(),
              ),
              if (showLocation)
                SizedBox(
                  width: 170,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 6, right: 8),
                    child: _locationCell(e),
                  ),
                ),
              SizedBox(
                width: 150,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Tooltip(
                    message: formatFullDate(e.modified),
                    waitDuration: const Duration(milliseconds: 500),
                    child: Text(formatDriveDate(e.modified), style: muted),
                  ),
                ),
              ),
              SizedBox(
                width: 110,
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(_sizeText(e), style: muted),
                ),
              ),
              SizedBox(width: 48, child: _kebab(e)),
            ],
          ),
        );
      },
    );
  }

  Widget _buildNarrowRow(CloudEntry e, List<CloudEntry> visible) {
    final scheme = Theme.of(context).colorScheme;
    final parts = <String>[
      if (e.searchFolder != null)
        e.searchFolder!
            .replaceFirst('${CloudFileManagerProvider.rootPath}/', ''),
      if (e.modified != null) formatDriveDate(e.modified),
      if (!e.isFolder || (e.stats?.totalBytes ?? 0) > 0) _sizeText(e),
      if (e.isArchived) 'Archived',
    ];
    return _interactive(e, visible, false, radius: 0, (selected, _) {
      return Container(
        padding: const EdgeInsets.only(left: 12),
        child: Row(
          children: [
            SizedBox(
              width: 44,
              child: Center(
                child: _selected.isNotEmpty
                    ? Checkbox(value: selected, onChanged: (_) => _toggle(e))
                    : _entryIcon(e, size: 26),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: _nameText(e, const TextStyle(fontSize: 14)),
                      ),
                      ..._nameBadges(e),
                    ],
                  ),
                  if (parts.isNotEmpty)
                    Text(parts.join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            fontSize: 12,
                            color: scheme.onSurfaceVariant,
                            fontFeatures: _tabular)),
                ],
              ),
            ),
            _kebab(e),
          ],
        ),
      );
    });
  }

  // ── Grid layout ─────────────────────────────────────────────────────────

  Widget _buildGrid(List<CloudEntry> visible, bool wide) {
    final folders = visible.where((e) => e.isFolder).toList();
    final files = visible.where((e) => !e.isFolder).toList();
    final scheme = Theme.of(context).colorScheme;
    Widget section(String title) => SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
            child: Text(title,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    color: scheme.onSurfaceVariant)),
          ),
        );
    return CustomScrollView(
      slivers: [
        if (folders.isNotEmpty) ...[
          section('Folders'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 280,
                mainAxisExtent: 52,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: folders.length,
              itemBuilder: (_, i) =>
                  _buildFolderTile(folders[i], visible, wide),
            ),
          ),
        ],
        if (files.isNotEmpty) ...[
          section('Files'),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 240,
                mainAxisExtent: 212,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
              ),
              itemCount: files.length,
              itemBuilder: (_, i) => _buildFileCard(files[i], visible, wide),
            ),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 120)),
      ],
    );
  }

  Widget _buildFolderTile(CloudEntry e, List<CloudEntry> visible, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    return _interactive(
      e,
      visible,
      wide,
      radius: 12,
      baseColor: scheme.surfaceContainerHigh,
      (selected, hovered) => Padding(
        padding: const EdgeInsets.only(left: 14),
        child: Row(
          children: [
            _entryIcon(e),
            const SizedBox(width: 12),
            Expanded(
              child: _nameText(e, const TextStyle(fontWeight: FontWeight.w500)),
            ),
            _kebab(e),
          ],
        ),
      ),
    );
  }

  Future<String?> _thumbUrl(String path) => _thumbUrls.putIfAbsent(path, () {
        // Any failure — sync or async — just leaves the type icon showing.
        try {
          return FirebaseStorage.instance
              .ref(path)
              .getDownloadURL()
              .then<String?>((u) => u)
              .catchError((Object _) => null);
        } catch (_) {
          return Future<String?>.value(null);
        }
      });

  /// What a file card shows: a photo's own thumbnail, else its type icon.
  Widget _cardPreview(CloudEntry e) {
    final scheme = Theme.of(context).colorScheme;
    final icon = Center(
      child: Icon(cloudTypeIcon(e.type),
          size: 52,
          color: cloudTypeColor(e.type, scheme)
              .withValues(alpha: e.isArchived ? 0.45 : 0.9)),
    );
    if (!(e.isLiveFile && e.type == CloudFileType.image)) return icon;
    return FutureBuilder<String?>(
      future: _thumbUrl(e.path),
      builder: (context, snap) {
        final url = snap.data;
        if (url == null) return icon;
        return Image.network(
          url,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          cacheWidth: 480,
          errorBuilder: (_, __, ___) => icon,
          frameBuilder: (context, child, frame, sync) => AnimatedOpacity(
            opacity: sync || frame != null ? 1 : 0,
            duration: const Duration(milliseconds: 200),
            child: child,
          ),
        );
      },
    );
  }

  Widget _buildFileCard(CloudEntry e, List<CloudEntry> visible, bool wide) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final badges = _nameBadges(e);
    // Concentric corners: 16 outside = 8 inside + 8 padding.
    return _interactive(
      e,
      visible,
      wide,
      radius: 16,
      baseColor: scheme.surfaceContainerHigh,
      (selected, hovered) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 0, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 44,
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  _entryIcon(e, size: 20),
                  const SizedBox(width: 10),
                  Expanded(child: _nameText(e, const TextStyle(fontSize: 13))),
                  _kebab(e),
                ],
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: scheme.surface,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  // Neutral hairline so photos don't bleed into the card.
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: (dark ? Colors.white : Colors.black)
                            .withValues(alpha: 0.08)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            _cardPreview(e),
                            if (badges.isNotEmpty)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: badges),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(10, 6, 8, 7),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${formatDriveDate(e.modified)} · ${_sizeText(e)}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 11,
                                    color: scheme.onSurfaceVariant,
                                    fontFeatures: _tabular),
                              ),
                            ),
                            if (e.isArchived)
                              Icon(Icons.inventory_2_outlined,
                                  size: 15, color: scheme.tertiary),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Details panel ───────────────────────────────────────────────────────

  Widget _buildDetailsFor(List<CloudEntry> entries,
      {bool current = false, required VoidCallback onClose}) {
    final scheme = Theme.of(context).colorScheme;
    final titleStyle = TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);

    Widget field(String label, String value, {Widget? trailing}) => Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: titleStyle),
              const SizedBox(height: 2),
              Row(
                children: [
                  Expanded(
                      child: SelectableText(value,
                          style: const TextStyle(fontSize: 14))),
                  if (trailing != null) trailing,
                ],
              ),
            ],
          ),
        );

    if (entries.length > 1) {
      final bytes = entries.fold<int>(0, (s, e) => s + (e.sizeBytes ?? 0));
      return _detailsShell(
        icon: Icon(Icons.library_add_check_outlined,
            size: 64, color: scheme.onSurfaceVariant),
        title: '${entries.length} items selected',
        onClose: onClose,
        children: [
          field('Folders', '${entries.where((e) => e.isFolder).length}'),
          field('Files in Cloud Files',
              '${entries.where((e) => e.isLiveFile).length}'),
          field(
              'Archived files', '${entries.where((e) => e.isArchived).length}'),
          field('Size of selected files', formatBytes(bytes)),
        ],
      );
    }

    final e = entries.first;
    final children = <Widget>[];
    if (e.isFolder) {
      final s = e.stats;
      if (current) {
        final live = _provider.files;
        final archived = _provider.archivedFiles;
        children
          ..add(field('Subfolders', '${_provider.folders.length}'))
          ..add(field('Files in Cloud Files',
              '${live.length} · ${formatBytes(live.fold<int>(0, (n, f) => n + (f.sizeBytes ?? 0)))}'))
          ..add(field('Archived files',
              '${archived.length} · ${formatBytes(archived.fold<int>(0, (n, f) => n + (f.sizeBytes ?? 0)))}'));
      } else if (s != null) {
        children
          ..add(field('Files in Cloud Files',
              '${s.liveFiles} · ${formatBytes(s.liveBytes)}'))
          ..add(field('Archived files',
              '${s.archivedFiles} · ${formatBytes(s.archivedBytes)}'))
          ..add(field('Last upload', formatFullDate(s.lastModified)));
      }
      children.add(field('Location',
          e.path.replaceFirst('${CloudFileManagerProvider.rootPath}/', '')));
      if (e.archiveNote != null) children.add(field('Archive', e.archiveNote!));
      final open = _openArchivesFor(e.path);
      if (open.isNotEmpty) {
        children.add(field(
            'Archive in progress',
            open.any((a) => a.isBuilding)
                ? 'Building the ZIP…'
                : open.any((a) => a.isRemoving)
                    ? 'Removing originals…'
                    : 'ZIP ready — waiting for you to confirm'));
      }
    } else {
      children
        ..add(field('Type', cloudTypeLabel(e)))
        ..add(field('Size', formatBytes(e.sizeBytes)))
        ..add(field(
            'Location',
            (e.searchFolder ?? dirname(e.path))
                .replaceFirst('${CloudFileManagerProvider.rootPath}/', '')))
        ..add(field(
            'Stored in',
            e.isArchived
                ? 'Archive ZIP${e.archived!.zipName == null ? '' : ' — ${e.archived!.zipName}'}'
                : 'Cloud Files (Firebase Storage)'));
      if (e.isArchived) {
        final a = e.archived!;
        children
          ..add(field('Last modified', formatFullDate(a.originalUpdated)))
          ..add(field('Archived', formatFullDate(a.archivedAt)));
        children.add(Text(
          'Removed from Cloud Files when its month was archived. To edit it '
          'again, upload it back into this folder from your Google Drive copy.',
          style: titleStyle,
        ));
      } else {
        children.add(field('Modified', formatFullDate(e.modified)));
      }
      if (e.name == _compiledWaypointsFileName && e.file != null) {
        _ensureWaypointCount(e.file!);
        final known = _waypointCounts.containsKey(e.path);
        children.add(field(
            'Waypoints',
            known
                ? (_waypointCounts[e.path]?.toString() ?? 'Could not read')
                : 'Counting…'));
      }
      if (e.isCompiled) {
        children.add(Text(
          'Compiled from this folder\'s GPX files. Maps, reports and '
          'letterbox counts load this file, so it stays here when the '
          'folder is archived.',
          style: titleStyle,
        ));
      }
    }

    final actions = <Widget>[
      if (e.canOpenInTrackEditor)
        FilledButton.tonalIcon(
          onPressed: () => _openFile(e.file!),
          icon: const Icon(Icons.edit_location_alt, size: 18),
          label: const Text('Open in Track Editor'),
        ),
      if (e.isArchived)
        FilledButton.tonalIcon(
          onPressed: () => _downloadArchiveZip(e.archived!),
          icon: const Icon(Icons.folder_zip_outlined, size: 18),
          label: const Text('Download archive ZIP'),
        ),
      if (_archivable(e) && _openArchivesFor(e.path).isEmpty)
        FilledButton.tonalIcon(
          onPressed: () => _archive([e]),
          icon: const Icon(Icons.inventory_2_outlined, size: 18),
          label: Text(
              'Archive ${e.path.split('/').length == 2 ? 'year' : 'month'}'),
        ),
      if (e.isLiveFile ||
          (e.isFolder && !_provider.isAtRoot) ||
          (e.isFolder && !current))
        OutlinedButton.icon(
          onPressed: () => _download([e]),
          icon: const Icon(Icons.download, size: 18),
          label: const Text('Download'),
        ),
    ];

    return _detailsShell(
      icon: SizedBox(
          width: 72, height: 72, child: Center(child: _entryIcon(e, size: 64))),
      title: e.name,
      onClose: onClose,
      children: [
        ...children,
        if (actions.isNotEmpty) ...[
          const SizedBox(height: 4),
          Wrap(spacing: 8, runSpacing: 8, children: actions),
        ],
      ],
    );
  }

  Widget _detailsShell({
    required Widget icon,
    required String title,
    required VoidCallback onClose,
    required List<Widget> children,
  }) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surface,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 12, 120),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w500)),
              ),
              IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Close details',
                  onPressed: onClose),
            ],
          ),
          const SizedBox(height: 12),
          Container(
            height: 150,
            margin: const EdgeInsets.only(right: 8, bottom: 20),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(child: icon),
          ),
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ],
      ),
    );
  }
}

String dirname(String path) {
  final slash = path.lastIndexOf('/');
  return slash > 0 ? path.substring(0, slash) : path;
}

/// Placeholder rows while a folder loads, gently pulsing — so the page keeps
/// its shape instead of flashing blank. Holds still when the platform asks
/// for reduced motion.
class _SkeletonList extends StatefulWidget {
  final bool wide;
  const _SkeletonList({required this.wide});

  @override
  State<_SkeletonList> createState() => _SkeletonListState();
}

class _SkeletonListState extends State<_SkeletonList>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  static const _widths = [0.55, 0.35, 0.7, 0.45, 0.6, 0.4, 0.5, 0.3];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.value = 1;
    } else if (!_pulse.isAnimating) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.surfaceContainerHighest;
    Widget bar(double w, double h, [double r = 6]) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
              color: color, borderRadius: BorderRadius.circular(r)),
        );
    return FadeTransition(
      opacity: Tween(begin: 0.45, end: 1.0)
          .animate(CurvedAnimation(parent: _pulse, curve: Curves.easeInOut)),
      child: ListView(
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.only(top: widget.wide ? 45 : 0),
        children: [
          for (final f in _widths)
            SizedBox(
              height: widget.wide ? 48 : 64,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    SizedBox(width: 48, child: Center(child: bar(22, 22))),
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                            widthFactor: f, child: bar(double.infinity, 12)),
                      ),
                    ),
                    if (widget.wide) ...[
                      SizedBox(
                          width: 150,
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: bar(64, 12))),
                      SizedBox(
                          width: 110,
                          child: Align(
                              alignment: Alignment.centerLeft,
                              child: bar(44, 12))),
                      const SizedBox(width: 48),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Drive-style filter chip: an outlined "Type ▾" that becomes a filled
/// "GPX tracks ✕" once a value is picked.
class _FilterMenuChip<T> extends StatelessWidget {
  final T value;
  final T any;
  final List<T> values;
  final String Function(T) label;
  final IconData Function(T)? icon;
  final ValueChanged<T> onChanged;

  const _FilterMenuChip({
    required this.value,
    required this.any,
    required this.values,
    required this.label,
    required this.onChanged,
    this.icon,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = value != any;
    return MenuAnchor(
      menuChildren: [
        for (final v in values)
          if (v != any)
            MenuItemButton(
              leadingIcon: icon == null
                  ? Icon(v == value ? Icons.check : null, size: 18)
                  : Icon(icon!(v), size: 18),
              trailingIcon: icon != null && v == value
                  ? const Icon(Icons.check, size: 18)
                  : null,
              onPressed: () => onChanged(v),
              child: Text(label(v)),
            ),
      ],
      builder: (context, controller, _) => Material(
        color: active ? scheme.secondaryContainer : Colors.transparent,
        shape: StadiumBorder(
          side: active
              ? BorderSide.none
              : BorderSide(color: scheme.outline.withValues(alpha: 0.7)),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: Padding(
            // ~36 px tall: a comfortable target without looking chunky.
            padding: const EdgeInsets.fromLTRB(14, 8, 10, 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (active && icon != null) ...[
                  Icon(icon!(value), size: 16),
                  const SizedBox(width: 6),
                ],
                Text(label(value), style: const TextStyle(fontSize: 13)),
                const SizedBox(width: 4),
                if (active)
                  InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => onChanged(any),
                    child: const Icon(Icons.close, size: 16),
                  )
                else
                  const Icon(Icons.arrow_drop_down, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A modal progress dialog driven by [CloudFileManagerProvider]'s
/// bulk-task state (label, total/completed counts, current file name).
/// Used for upload, copy, move, and delete batches so the user always
/// sees what's happening and how far along it is.
class _TaskProgressDialog extends StatefulWidget {
  final CloudFileManagerProvider provider;
  const _TaskProgressDialog({required this.provider});

  @override
  State<_TaskProgressDialog> createState() => _TaskProgressDialogState();
}

class _TaskProgressDialogState extends State<_TaskProgressDialog> {
  @override
  void initState() {
    super.initState();
    widget.provider.addListener(_onChanged);
  }

  @override
  void dispose() {
    widget.provider.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    final total = p.taskTotal;
    final done = p.taskCompleted;
    final label = p.taskLabel.isEmpty ? 'Working\u2026' : p.taskLabel;
    final progress = p.taskProgress;
    final indeterminate = total == 0;

    return PopScope(
      canPop: false,
      child: AlertDialog(
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: indeterminate ? null : progress,
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    indeterminate ? '\u2026' : '$done of $total',
                    style: const TextStyle(
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                  if (!indeterminate)
                    Text('${(progress * 100).toStringAsFixed(0)}%'),
                ],
              ),
              if (p.taskCurrentItem.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  p.taskCurrentItem,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black54,
                    fontSize: 12,
                  ),
                ),
              ],
              if (p.taskDetail.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  p.taskDetail,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black45,
                    fontSize: 11,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Folder picker that lazily loads one folder level at a time, mirroring
/// the file manager's own navigation. Each level is fetched via
/// [listSubfolders] only when the user opens that folder, so we never
/// pre-load the entire `Distribution/` tree.
class _FolderNavigatorPicker extends StatefulWidget {
  final String title;
  final String rootPath;
  final String rootLabel;

  /// Folder path that is the *source* of the move/copy. The picker
  /// disables it (and forbids picking it) so the user can't pick the
  /// same folder as the destination. Subfolders of it are still allowed.
  final String excludeFolder;

  /// Initial folder to open at. Falls back to the root if it's blank or
  /// not under [rootPath].
  final String startPath;

  final Future<List<StorageFolderItem>> Function(String folderPath)
      listSubfolders;

  final void Function(String pickedPath) onPicked;
  final VoidCallback onCancel;

  const _FolderNavigatorPicker({
    required this.title,
    required this.rootPath,
    required this.rootLabel,
    required this.excludeFolder,
    required this.startPath,
    required this.listSubfolders,
    required this.onPicked,
    required this.onCancel,
  });

  @override
  State<_FolderNavigatorPicker> createState() => _FolderNavigatorPickerState();
}

class _FolderNavigatorPickerState extends State<_FolderNavigatorPicker> {
  /// Current folder being browsed.
  late String _currentPath;

  /// Subfolders of the current path. Null while loading.
  List<StorageFolderItem>? _subfolders;
  String? _error;
  bool _loading = false;

  /// Tiny per-level cache so back/forward through the same path doesn't
  /// re-hit Storage. Cleared when the dialog closes (state goes away).
  final Map<String, List<StorageFolderItem>> _cache = {};

  @override
  void initState() {
    super.initState();
    final start = widget.startPath.isNotEmpty &&
            (widget.startPath == widget.rootPath ||
                widget.startPath.startsWith('${widget.rootPath}/'))
        ? widget.startPath
        : widget.rootPath;
    _currentPath = start;
    _load(start);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final cached = _cache[path];
    if (cached != null) {
      setState(() {
        _currentPath = path;
        _subfolders = cached;
        _loading = false;
      });
      return;
    }
    try {
      final folders = await widget.listSubfolders(path);
      if (!mounted) return;
      _cache[path] = folders;
      setState(() {
        _currentPath = path;
        _subfolders = folders;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// Path segments from the root → current. Used for breadcrumbs.
  List<({String name, String path})> _breadcrumbs() {
    final out = <({String name, String path})>[];
    out.add((name: widget.rootLabel, path: widget.rootPath));
    if (_currentPath == widget.rootPath) return out;
    final tail = _currentPath.substring(widget.rootPath.length + 1);
    final parts = tail.split('/');
    var acc = widget.rootPath;
    for (final p in parts) {
      acc = '$acc/$p';
      out.add((name: p, path: acc));
    }
    return out;
  }

  void _goUp() {
    if (_currentPath == widget.rootPath) return;
    final slash = _currentPath.lastIndexOf('/');
    final parent =
        slash > 0 ? _currentPath.substring(0, slash) : widget.rootPath;
    _load(parent);
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = _breadcrumbs();
    final canSelectHere = _currentPath != widget.excludeFolder;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title
          Row(
            children: [
              Expanded(
                child: Text(
                  widget.title,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ),
              IconButton(
                tooltip: 'Up',
                onPressed:
                    _currentPath == widget.rootPath || _loading ? null : _goUp,
                icon: const Icon(Icons.arrow_upward),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Breadcrumbs
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: Row(
              children: [
                for (var i = 0; i < crumbs.length; i++) ...[
                  if (i > 0)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2),
                      child: Icon(Icons.chevron_right,
                          size: 16, color: Colors.grey),
                    ),
                  InkWell(
                    onTap: _loading || crumbs[i].path == _currentPath
                        ? null
                        : () => _load(crumbs[i].path),
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      child: Text(
                        crumbs[i].name,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: i == crumbs.length - 1
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: i == crumbs.length - 1
                              ? Colors.black87
                              : Colors.blue.shade700,
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const Divider(height: 16),
          // Folder list
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(
                        child: Text('Failed to load: $_error',
                            style: TextStyle(color: Colors.red.shade400)),
                      )
                    : (_subfolders == null || _subfolders!.isEmpty)
                        ? Center(
                            child: Text(
                              'No subfolders here. Use “Select this folder” to pick the current folder.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey.shade600),
                            ),
                          )
                        : ListView.builder(
                            itemCount: _subfolders!.length,
                            itemBuilder: (_, i) {
                              final folder = _subfolders![i];
                              final isSource =
                                  folder.fullPath == widget.excludeFolder;
                              return ListTile(
                                dense: true,
                                leading: Icon(Icons.folder,
                                    color: isSource
                                        ? Colors.grey
                                        : Colors.amber.shade700,
                                    size: 20),
                                title: Text(
                                  folder.name,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color:
                                        isSource ? Colors.grey : Colors.black87,
                                    fontStyle: isSource
                                        ? FontStyle.italic
                                        : FontStyle.normal,
                                  ),
                                ),
                                subtitle: isSource
                                    ? const Text('Source folder',
                                        style: TextStyle(fontSize: 10))
                                    : null,
                                trailing:
                                    const Icon(Icons.chevron_right, size: 18),
                                onTap: () => _load(folder.fullPath),
                              );
                            },
                          ),
          ),
          const SizedBox(height: 8),
          // Action row: Cancel / Select this folder
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: widget.onCancel,
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: canSelectHere && !_loading
                    ? () => widget.onPicked(_currentPath)
                    : null,
                icon: const Icon(Icons.check, size: 18),
                label: Text(
                  _currentPath == widget.rootPath
                      ? 'Select Distribution'
                      : 'Select this folder',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Marks a folder row or tile as a drop target for files dragged in from the
/// computer; see `_folderPathAt`.
class _FolderDropTarget {
  final String path;
  const _FolderDropTarget(this.path);
}
