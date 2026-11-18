// track_editor/widgets/te_distributor_picker_dialog.dart
//
// Pick the distributor a track belongs to by hand — for when the name in the
// file name matched nobody on the schedule (usually a misspelling), or matched
// the wrong person. The closest names to the one in the file are listed first.
import 'package:clmschedule/utils/text_search.dart';
import 'package:flutter/material.dart';

import '../../models/distributor.dart';
import '../services/te_gpx_matching.dart';

/// Shows the picker and returns the chosen distributor's id, or null.
///
/// [fileName] is the text the name was read from (the tab's match key or
/// title); [currentId] marks the distributor the track is matched to now.
Future<String?> showTEDistributorPicker(
  BuildContext context, {
  required List<Distributor> distributors,
  required String fileName,
  String? currentId,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _TEDistributorPickerDialog(
      distributors: distributors,
      fileName: fileName,
      currentId: currentId,
    ),
  );
}

/// How similar a name must be to count as a suggestion.
const _suggestionThreshold = 0.5;
const _maxSuggestions = 3;

class _TEDistributorPickerDialog extends StatefulWidget {
  final List<Distributor> distributors;
  final String fileName;
  final String? currentId;

  const _TEDistributorPickerDialog({
    required this.distributors,
    required this.fileName,
    this.currentId,
  });

  @override
  State<_TEDistributorPickerDialog> createState() =>
      _TEDistributorPickerDialogState();
}

class _TEDistributorPickerDialogState
    extends State<_TEDistributorPickerDialog> {
  final _search = TextEditingController();
  late final List<({Distributor distributor, double score})> _ranked =
      rankDistributorsByName(widget.fileName, widget.distributors);

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final query = _search.text.trim().toLowerCase();
    final suggestions = query.isNotEmpty
        ? const <Distributor>[]
        : _ranked
            .where((r) => r.score >= _suggestionThreshold)
            .take(_maxSuggestions)
            .map((r) => r.distributor)
            .toList();
    // Typing: best name matches first (words any order, close spellings).
    final rest = query.isEmpty
        ? [
            for (final r in _ranked)
              if (!suggestions.contains(r.distributor)) r.distributor,
          ]
        : TextSearch(query)
            .rank(_ranked.map((r) => r.distributor), (d) => [d.name]);
    // Suggestions lead; below them everyone else alphabetically.
    if (query.isEmpty) {
      rest.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    }

    return AlertDialog(
      title: const Text('Match distributor'),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
      content: SizedBox(
        width: 360,
        height: 440,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('From file: ${widget.fileName}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
            const SizedBox(height: 8),
            TextField(
              controller: _search,
              autofocus: true,
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 18),
                hintText: 'Search distributors',
                border: OutlineInputBorder(),
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) {
                final only = [...suggestions, ...rest];
                if (only.length == 1) Navigator.of(context).pop(only.first.id);
              },
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: [
                  if (suggestions.isNotEmpty) ...[
                    _heading('Closest to the file name'),
                    for (final d in suggestions) _tile(d, suggested: true),
                    const Divider(height: 12),
                    _heading('All distributors'),
                  ],
                  for (final d in rest) _tile(d),
                  if (suggestions.isEmpty && rest.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text('No distributor matches "$query".',
                          style: TextStyle(color: Colors.grey.shade600)),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _heading(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
        child: Text(text,
            style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600)),
      );

  Widget _tile(Distributor d, {bool suggested = false}) {
    final isCurrent = d.id == widget.currentId;
    return ListTile(
      dense: true,
      leading: Icon(
        isCurrent
            ? Icons.check_circle
            : suggested
                ? Icons.auto_awesome
                : Icons.person_outline,
        size: 18,
        color: isCurrent
            ? Colors.green
            : suggested
                ? Colors.amber.shade800
                : Colors.grey,
      ),
      title: Text(d.name),
      subtitle: isCurrent ? const Text('Matched now') : null,
      onTap: () => Navigator.of(context).pop(d.id),
    );
  }
}
