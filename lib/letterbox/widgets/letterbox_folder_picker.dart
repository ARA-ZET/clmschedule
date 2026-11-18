import 'package:clmschedule/utils/text_search.dart';
import 'package:flutter/material.dart';

import '../providers/letterbox_provider.dart';
import '../services/letterbox_folder_service.dart';

/// Pick the Cloud Storage folders to seed a suburb from.
///
/// Only folders that actually contain GPX are listed — the compile trigger
/// writes `_compiled_waypoints.json` beside the GPX, so anything else is a
/// guaranteed seed of zero. The count beside each folder is its GPX file
/// count, so an empty selection is obvious before you commit to it.
///
/// The listing fetches folder *names* only — a field-masked query that skips
/// the filename maps making up almost all of each index document. A folder's
/// GPX count is fetched on demand when it is ticked, since a user normally
/// picks one or two folders out of hundreds.
class LetterboxFolderPicker extends StatefulWidget {
  final LetterboxProvider provider;

  const LetterboxFolderPicker({super.key, required this.provider});

  @override
  State<LetterboxFolderPicker> createState() => _LetterboxFolderPickerState();
}

class _LetterboxFolderPickerState extends State<LetterboxFolderPicker> {
  final Set<String> _selected = {};
  String _query = '';

  @override
  void initState() {
    super.initState();
    widget.provider.addListener(_onChanged);
    widget.provider.loadFolders();
  }

  @override
  void dispose() {
    widget.provider.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  /// Ticking a folder is what triggers its detail fetch.
  void _toggle(String path, bool on) {
    setState(() {
      if (on) {
        _selected.add(path);
        widget.provider.fetchGpxCount(path);
      } else {
        _selected.remove(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final provider = widget.provider;
    final search = TextSearch(_query);
    final visible =
        provider.folders.where((f) => search.matches([f.label])).toList();

    // Month headers, so a long list stays navigable. Paths are already ordered
    // newest-year-first by the query.
    final rows = <_Row>[];
    String? lastMonth;
    for (final folder in visible) {
      if (folder.month != lastMonth) {
        rows.add(_Row.header(folder.month));
        lastMonth = folder.month;
      }
      rows.add(_Row.folder(folder));
    }

    return AlertDialog(
      title: const Text('Seed from which folders?'),
      content: SizedBox(
        width: 560,
        height: 460,
        child: provider.isLoadingFolders
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: 'Filter by client, month or round',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        '${_selected.length} selected · '
                        '${visible.length} of ${provider.folders.length}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const Spacer(),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Expanded(
                    child: rows.isEmpty
                        ? const Center(child: Text('No folders match.'))
                        : ListView.builder(
                            itemCount: rows.length,
                            itemBuilder: (context, i) {
                              final row = rows[i];
                              if (row.isHeader) {
                                return Padding(
                                  padding:
                                      const EdgeInsets.fromLTRB(12, 12, 12, 4),
                                  child: Text(
                                    row.header!,
                                    style:
                                        Theme.of(context).textTheme.labelLarge,
                                  ),
                                );
                              }
                              final folder = row.folder!;
                              final count = provider.gpxCountFor(folder.path);
                              return CheckboxListTile(
                                dense: true,
                                value: _selected.contains(folder.path),
                                title: Text(
                                  folder.label,
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                                // Only appears once selected — the count costs
                                // a document read, so it is not paid for rows
                                // the user never picks.
                                secondary: count == null
                                    ? null
                                    : Text(
                                        '$count GPX',
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall,
                                      ),
                                onChanged: (on) =>
                                    _toggle(folder.path, on ?? false),
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (visible.isNotEmpty)
          TextButton(
            onPressed: () {
              for (final f in visible) {
                _toggle(f.path, true);
              }
            },
            child: const Text('Select all shown'),
          ),
        FilledButton(
          onPressed: _selected.isEmpty
              ? null
              : () => Navigator.pop(context, _selected.toList()),
          child: const Text('Seed'),
        ),
      ],
    );
  }
}

/// A month header or a folder row.
class _Row {
  final String? header;
  final WaypointFolder? folder;

  const _Row.header(String this.header) : folder = null;
  const _Row.folder(WaypointFolder this.folder) : header = null;

  bool get isHeader => header != null;
}
