// track_editor/widgets/te_folder_picker_dialog.dart
//
// A "pick one Storage folder and return its path" dialog for Report mode —
// deliberately not the full CloudFileManagerScreen, which is a general file
// manager with no "confirm this folder" concept. Everything inside the chosen
// folder is scanned recursively afterwards, so nothing is selected at the
// file level here.
//
// Built for speed:
//   * Every distribution folder path arrives in ONE request, names only, from
//     the Firestore file index (LetterboxFolderService) — no Storage listing,
//     no per-file metadata. Nothing loads when a folder is tapped, so there is
//     no moment where a half-loaded list lets the user confirm the wrong one.
//   * Folders are grouped under their month (`Distribution/{year}/{MMM yyyy}`),
//     newest month first, with a search box across client, round and month.
//   * "Browse storage" walks Cloud Storage directly, for a folder uploaded
//     moments ago that the index hasn't caught up with yet.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../letterbox/services/letterbox_folder_service.dart';
import '../../services/gpx_storage_service.dart';

/// Shows the picker and returns the chosen folder's full Storage path, or
/// null if the user backed out without confirming one.
Future<String?> showTEFolderPicker(
  BuildContext context, {
  String rootPath = 'Distribution',
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => TEFolderPickerDialog(rootPath: rootPath),
  );
}

// ════════════════════════════════════════════════════════════════════════════
// FOLDER TREE — pure, so grouping and search can be tested without Firebase
// ════════════════════════════════════════════════════════════════════════════

class TEFolderNode {
  final String name;
  final String path;

  /// One level down — normally `Round 1`, `Round 2`.
  final List<TEFolderNode> children;

  const TEFolderNode(this.name, this.path, [this.children = const []]);
}

class TEMonthGroup {
  /// `Sep 2026`.
  final String label;

  /// `Distribution/2026/Sep 2026` — selectable to report on the whole month.
  final String path;
  final List<TEFolderNode> folders;

  const TEMonthGroup(this.label, this.path, this.folders);
}

/// Groups indexed folder [paths] under [root] by month, newest first, client
/// folders A–Z inside each, their subfolders beneath.
///
/// [query] keeps a client when its name, its month or any of its subfolders
/// matches (case-insensitive); when only subfolders match, only those are
/// kept. Folders the report itself writes (`proof`) and system folders
/// (`_…`, `.…`) are left out.
@visibleForTesting
List<TEMonthGroup> teFolderMonthGroups(
  Iterable<String> paths, {
  String root = 'Distribution',
  String query = '',
}) {
  bool hidden(String seg) =>
      seg.startsWith('_') || seg.startsWith('.') || seg == 'proof';

  // month path → client path → child paths
  final months = <String, Map<String, Set<String>>>{};
  for (final path in paths) {
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    if (segs.length < 3 || segs[0] != root) continue;
    if (segs.skip(1).any(hidden)) continue;
    final monthPath = segs.take(3).join('/');
    final clients = months.putIfAbsent(monthPath, () => {});
    if (segs.length < 4) continue;
    final children = clients.putIfAbsent(segs.take(4).join('/'), () => {});
    if (segs.length >= 5) children.add(segs.take(5).join('/'));
  }

  final q = query.trim().toLowerCase();
  bool matches(String s) => q.isEmpty || s.toLowerCase().contains(q);
  String last(String path) => path.substring(path.lastIndexOf('/') + 1);

  final groups = <TEMonthGroup>[];
  months.forEach((monthPath, clients) {
    final label = last(monthPath);
    final monthMatches = q.isNotEmpty && matches(label);
    final folders = <TEFolderNode>[];
    for (final entry in clients.entries) {
      final name = last(entry.key);
      final children = [
        for (final c in entry.value.toList()..sort(_naturalCompare))
          TEFolderNode(last(c), c),
      ];
      if (q.isEmpty || monthMatches || matches(name)) {
        folders.add(TEFolderNode(name, entry.key, children));
        continue;
      }
      final hits = children.where((c) => matches(c.name)).toList();
      if (hits.isNotEmpty) folders.add(TEFolderNode(name, entry.key, hits));
    }
    if (folders.isEmpty && !(q.isEmpty || monthMatches)) return;
    folders.sort((a, b) => _naturalCompare(a.name, b.name));
    groups.add(TEMonthGroup(label, monthPath, folders));
  });

  groups.sort((a, b) {
    final byDate = (_monthDate(b.path) ?? DateTime(0))
        .compareTo(_monthDate(a.path) ?? DateTime(0));
    return byDate != 0 ? byDate : b.path.compareTo(a.path);
  });
  return groups;
}

final _monthFmt = DateFormat('MMM yyyy');

DateTime? _monthDate(String monthPath) {
  final label = monthPath.substring(monthPath.lastIndexOf('/') + 1);
  try {
    return _monthFmt.parseStrict(label);
  } catch (_) {
    final year = int.tryParse(monthPath.split('/').elementAtOrNull(1) ?? '');
    return year == null ? null : DateTime(year);
  }
}

/// Case-insensitive, with runs of digits compared as numbers, so `Round 10`
/// sorts after `Round 2`.
int _naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final pa = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
  final pb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final na = int.tryParse(pa[i]);
    final nb = int.tryParse(pb[i]);
    final c =
        (na != null && nb != null) ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

// ════════════════════════════════════════════════════════════════════════════
// DIALOG
// ════════════════════════════════════════════════════════════════════════════

class TEFolderPickerDialog extends StatefulWidget {
  final String rootPath;

  /// Supplies the indexed folder paths. Defaults to the Firestore file index;
  /// tests hand in a fixed list.
  final Future<List<String>> Function()? loadPaths;

  const TEFolderPickerDialog({
    super.key,
    required this.rootPath,
    @visibleForTesting this.loadPaths,
  });

  @override
  State<TEFolderPickerDialog> createState() => _TEFolderPickerDialogState();
}

class _TEFolderPickerDialogState extends State<TEFolderPickerDialog> {
  List<String>? _paths;
  bool _loading = true;
  String? _error;

  String _query = '';
  String? _selected;
  final Set<String> _openMonths = {};
  final Set<String> _openFolders = {};

  bool _browse = false;

  final TextEditingController _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _loadIndex();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadIndex() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final paths = widget.loadPaths != null
          ? await widget.loadPaths!()
          : [
              for (final f in await LetterboxFolderService().listFolderPaths())
                f.path,
            ];
      if (!mounted) return;
      final groups = teFolderMonthGroups(paths, root: widget.rootPath);
      setState(() {
        _paths = paths;
        _loading = false;
        // Open the newest month; that's where this week's report lives.
        if (groups.isNotEmpty) _openMonths.add(groups.first.path);
        // Nothing indexed at all: go straight to walking Storage.
        if (groups.isEmpty) _browse = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not load the folder list: $e';
        _loading = false;
        _browse = true;
      });
    }
  }

  String _label(String path) => path.startsWith('${widget.rootPath}/')
      ? path.substring(widget.rootPath.length + 1)
      : path;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.folder_open, size: 20),
                  const SizedBox(width: 8),
                  const Expanded(
                    child: Text(
                      'Choose a folder to report on',
                      overflow: TextOverflow.ellipsis,
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
              const Text(
                'Every GPX file in the folder and its subfolders will be '
                'scanned — round subfolders included.',
                style: TextStyle(fontSize: 12, color: Colors.black54),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: _browse
                    ? _StorageBrowser(
                        rootPath: widget.rootPath,
                        selected: _selected,
                        onSelected: (p) => setState(() => _selected = p),
                      )
                    : _indexView(),
              ),
              const Divider(height: 20),
              // The chosen path gets a line of its own: client folder names
              // are long, and squeezed beside the buttons they'd be cut off.
              Row(
                children: [
                  Icon(
                    _selected == null ? Icons.folder_outlined : Icons.folder,
                    size: 16,
                    color: _selected == null
                        ? Colors.black38
                        : Colors.amber.shade700,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _selected == null
                          ? 'No folder selected'
                          : _label(_selected!),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        color:
                            _selected == null ? Colors.black45 : Colors.black87,
                        fontWeight: _selected == null
                            ? FontWeight.normal
                            : FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                alignment: WrapAlignment.end,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (_paths != null && _paths!.isNotEmpty)
                    TextButton.icon(
                      onPressed: () => setState(() => _browse = !_browse),
                      icon: Icon(
                          _browse ? Icons.view_list : Icons.travel_explore,
                          size: 17),
                      label: Text(_browse ? 'Folder list' : 'Browse storage'),
                    ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton.icon(
                    onPressed: _selected == null
                        ? null
                        : () => Navigator.of(context).pop(_selected),
                    icon: const Icon(Icons.check, size: 18),
                    label: const Text('Use this folder'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Index view: months → client folders → rounds ─────────────────────────

  Widget _indexView() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
          child: Text(_error!, style: const TextStyle(color: Colors.red)));
    }

    final groups = teFolderMonthGroups(_paths ?? const [],
        root: widget.rootPath, query: _query);
    final searching = _query.trim().isNotEmpty;

    final rows = <Widget>[];
    for (final g in groups) {
      final open = searching || _openMonths.contains(g.path);
      rows.add(_MonthHeader(
        group: g,
        open: open,
        selected: _selected == g.path,
        onToggle: searching
            ? null
            : () => setState(() => _openMonths.contains(g.path)
                ? _openMonths.remove(g.path)
                : _openMonths.add(g.path)),
        onSelect: () => setState(() => _selected = g.path),
      ));
      if (!open) continue;
      for (final f in g.folders) {
        final folderOpen = f.children.isNotEmpty &&
            (searching || _openFolders.contains(f.path));
        rows.add(_FolderRow(
          node: f,
          depth: 1,
          selected: _selected == f.path,
          open: folderOpen,
          onSelect: () => setState(() => _selected = f.path),
          onToggle: f.children.isEmpty
              ? null
              : () => setState(() => _openFolders.contains(f.path)
                  ? _openFolders.remove(f.path)
                  : _openFolders.add(f.path)),
        ));
        if (!folderOpen) continue;
        for (final c in f.children) {
          rows.add(_FolderRow(
            node: c,
            depth: 2,
            selected: _selected == c.path,
            open: false,
            onSelect: () => setState(() => _selected = c.path),
          ));
        }
      }
    }

    return Column(
      children: [
        TextField(
          autofocus: true,
          decoration: InputDecoration(
            isDense: true,
            prefixIcon: const Icon(Icons.search, size: 20),
            hintText: 'Search client, round or month',
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
            suffixIcon: _query.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () {
                      _search.clear();
                      setState(() => _query = '');
                    },
                  ),
          ),
          controller: _search,
          onChanged: (v) => setState(() => _query = v),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: rows.isEmpty
              ? Center(
                  child: Text(
                    searching
                        ? 'No folders match "$_query"'
                        : 'No folders found',
                    style: const TextStyle(color: Colors.black45),
                  ),
                )
              : ListView.builder(
                  itemCount: rows.length,
                  itemBuilder: (_, i) => rows[i],
                ),
        ),
      ],
    );
  }
}

class _MonthHeader extends StatelessWidget {
  final TEMonthGroup group;
  final bool open;
  final bool selected;
  final VoidCallback? onToggle;
  final VoidCallback onSelect;

  const _MonthHeader({
    required this.group,
    required this.open,
    required this.selected,
    required this.onToggle,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.blueGrey.shade100 : Colors.blueGrey.shade50,
      child: InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(6, 6, 4, 6),
          child: Row(
            children: [
              Icon(open ? Icons.expand_more : Icons.chevron_right, size: 20),
              const SizedBox(width: 4),
              Text(group.label,
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Text(
                '${group.folders.length} folder'
                '${group.folders.length == 1 ? '' : 's'}',
                style: const TextStyle(fontSize: 11.5, color: Colors.black54),
              ),
              const Spacer(),
              TextButton(
                onPressed: onSelect,
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  textStyle: const TextStyle(fontSize: 12),
                ),
                child: const Text('Whole month'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderRow extends StatelessWidget {
  final TEFolderNode node;
  final int depth;
  final bool selected;
  final bool open;
  final VoidCallback onSelect;
  final VoidCallback? onToggle;

  const _FolderRow({
    required this.node,
    required this.depth,
    required this.selected,
    required this.open,
    required this.onSelect,
    this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? Colors.blue.shade50 : Colors.transparent,
      child: InkWell(
        onTap: onSelect,
        child: Padding(
          padding: EdgeInsets.fromLTRB(8.0 + depth * 18, 2, 4, 2),
          child: Row(
            children: [
              Icon(
                selected ? Icons.check_circle : Icons.folder,
                size: 18,
                color: selected ? Colors.blue : Colors.amber.shade700,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  node.name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              if (onToggle != null)
                IconButton(
                  tooltip: open ? 'Hide rounds' : 'Show rounds',
                  visualDensity: VisualDensity.compact,
                  icon: Icon(open ? Icons.expand_less : Icons.expand_more,
                      size: 18),
                  onPressed: onToggle,
                )
              else
                const SizedBox(height: 36),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════════════
// STORAGE BROWSER — the fallback, walking Cloud Storage folder by folder
// ════════════════════════════════════════════════════════════════════════════

class _StorageBrowser extends StatefulWidget {
  final String rootPath;
  final String? selected;
  final ValueChanged<String> onSelected;

  const _StorageBrowser({
    required this.rootPath,
    required this.selected,
    required this.onSelected,
  });

  @override
  State<_StorageBrowser> createState() => _StorageBrowserState();
}

class _StorageBrowserState extends State<_StorageBrowser> {
  late String _current = widget.rootPath;
  List<StorageFolderItem> _subfolders = [];
  int _gpxCount = 0;
  bool _loading = true;
  String? _error;

  /// Bumped on every navigation so a slow listing that finishes after the
  /// user has already moved on can't overwrite the folder they're in now.
  int _request = 0;

  @override
  void initState() {
    super.initState();
    _open(_current);
  }

  Future<void> _open(String path) async {
    final request = ++_request;
    // Move and select straight away: confirming never has to wait for the
    // listing, and never confirms the folder the user just left.
    setState(() {
      _current = path;
      _loading = true;
      _error = null;
    });
    widget.onSelected(path);
    try {
      final contents = await GpxStorageService().listFolderNames(path);
      if (!mounted || request != _request) return;
      setState(() {
        _subfolders = contents.folders;
        _gpxCount = contents.gpxCount;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || request != _request) return;
      setState(() {
        _error = 'Could not open that folder: $e';
        _loading = false;
      });
    }
  }

  List<(String, String)> get _crumbs {
    final rootSegs = widget.rootPath.split('/');
    final curSegs = _current.split('/');
    return [
      for (var i = rootSegs.length - 1; i < curSegs.length; i++)
        (curSegs[i], curSegs.sublist(0, i + 1).join('/')),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final (label, path) in _crumbs) ...[
              if (path != _crumbs.first.$2)
                const Icon(Icons.chevron_right,
                    size: 16, color: Colors.black38),
              InkWell(
                onTap: path == _current ? null : () => _open(path),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: path == _current
                          ? FontWeight.bold
                          : FontWeight.normal,
                      color:
                          path == _current ? Colors.black87 : Colors.blueGrey,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 4),
        Text(
          _loading
              ? 'Loading…'
              : '$_gpxCount GPX file${_gpxCount == 1 ? '' : 's'} directly in '
                  'this folder',
          style: const TextStyle(fontSize: 11.5, color: Colors.black54),
        ),
        const Divider(height: 14),
        Expanded(
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? Center(
                      child: Text(_error!,
                          style: const TextStyle(color: Colors.red)))
                  : _subfolders.isEmpty
                      ? const Center(
                          child: Text('No subfolders here',
                              style: TextStyle(color: Colors.black45)))
                      : ListView.builder(
                          itemCount: _subfolders.length,
                          itemBuilder: (context, i) {
                            final f = _subfolders[i];
                            return ListTile(
                              dense: true,
                              leading:
                                  const Icon(Icons.folder, color: Colors.amber),
                              title: Text(f.name),
                              trailing:
                                  const Icon(Icons.chevron_right, size: 18),
                              onTap: () => _open(f.fullPath),
                            );
                          },
                        ),
        ),
      ],
    );
  }
}
