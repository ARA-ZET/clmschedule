import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/csg_region.dart';
import '../models/erf_list_entry.dart';
import '../models/erf_search_scope.dart';
import '../providers/erf_property_provider.dart';
import '../services/csg_property_service.dart';
import '../services/erf_list_parser.dart';

/// What the user asked to look up.
class ErfPasteRequest {
  final String text;

  /// Geographic limit on ERF-number lookups and their suggestions.
  final ErfSearchScope scope;

  /// Suburb to restrict ERF-number lookups to. Optional, but strongly
  /// recommended — ERF numbers are only unique within a cadastral region.
  final CsgRegion? region;

  /// Name for the resulting map and KML file.
  final String label;

  const ErfPasteRequest({
    required this.text,
    required this.label,
    required this.scope,
    this.region,
  });
}

/// Collects a pasted list of addresses and/or ERF numbers.
///
/// Shows a live preview of how each line was understood before anything is
/// looked up, because the formats people paste vary wildly and a silent
/// mis-parse is worse than a visible one.
class ErfPasteListDialog extends riverpod.ConsumerStatefulWidget {
  const ErfPasteListDialog({super.key});

  @override
  riverpod.ConsumerState<ErfPasteListDialog> createState() =>
      _ErfPasteListDialogState();
}

class _ErfPasteListDialogState
    extends riverpod.ConsumerState<ErfPasteListDialog> {
  final _textController = TextEditingController();
  final _labelController = TextEditingController();
  final _suburbController = TextEditingController();

  Timer? _parseDebounce;

  List<ErfListEntry> _preview = [];
  List<CsgRegion> _regions = [];
  CsgRegion? _region;
  bool _isSearchingRegions = false;
  String? _regionError;
  ErfSearchScope _scope = ErfSearchScope.capeTown;

  @override
  void dispose() {
    _parseDebounce?.cancel();
    _textController.dispose();
    _labelController.dispose();
    _suburbController.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _parseDebounce?.cancel();
    _parseDebounce = Timer(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _preview = ErfListParser.parse(value));
    });
  }

  void _onSuburbChanged(String value) {
    setState(() {
      _region = null;
      _regions = [];
      _regionError = null;
    });
  }

  /// Explicit, never on keystroke — a register query takes 30-60 seconds.
  Future<void> _searchRegions() async {
    final value = _suburbController.text;
    if (value.trim().length < 2) return;
    await () async {
      setState(() => _isSearchingRegions = true);
      List<CsgRegion> regions = const [];
      String? failure;
      try {
        regions = await ref.read(erfPropertyRiverpod).searchRegions(value.trim());
      } on CsgException catch (e) {
        failure = e.message;
      } catch (e) {
        failure = 'Suburb search failed: $e';
      }
      if (!mounted) return;
      setState(() {
        _isSearchingRegions = false;
        _regions = regions;
        _regionError = failure;
      });
    }();
  }

  void _submit() {
    final text = _textController.text;
    if (text.trim().isEmpty) return;

    final label = _labelController.text.trim().isNotEmpty
        ? _labelController.text.trim()
        : (_region?.minRegion ?? 'ERF Selection');

    Navigator.pop(
      context,
      ErfPasteRequest(
        text: text,
        label: label,
        region: _region,
        scope: _scope,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Fixed dialog dimensions overflow on a phone, so both axes are capped to
    // the viewport and the two panes stack when there is no room to sit side
    // by side.
    final media = MediaQuery.of(context);
    final maxWidth = media.size.width - 48;
    final maxHeight = media.size.height - 180;
    final isWide = maxWidth >= 660;

    return AlertDialog(
      title: const Text('Paste addresses / ERF numbers'),
      insetPadding: const EdgeInsets.all(16),
      content: SizedBox(
        width: isWide ? 720 : maxWidth,
        height: maxHeight.clamp(340.0, 560.0),
        child: isWide
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 3, child: _buildEditor(context)),
                  const SizedBox(width: 16),
                  Expanded(flex: 2, child: _buildSidePane(context)),
                ],
              )
            : Column(
                children: [
                  Expanded(flex: 3, child: _buildEditor(context)),
                  const SizedBox(height: 12),
                  Expanded(flex: 2, child: _buildSidePane(context)),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: _preview.any((e) => e.isUsable) ? _submit : null,
          icon: const Icon(Icons.search),
          label: const Text('Find these ERFs'),
        ),
      ],
    );
  }

  Widget _buildEditor(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: TextField(
            controller: _textController,
            autofocus: true,
            maxLines: null,
            expands: true,
            textAlignVertical: TextAlignVertical.top,
            decoration: InputDecoration(
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              alignLabelWithHint: true,
              labelText: 'One per line',
              hintText: '12 Main Road, Kensington\n'
                  'ERF 1234\n'
                  '8 Fifth Avenue, Kensington, 5678\n'
                  '9012',
            ),
            onChanged: _onTextChanged,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Addresses are geocoded and matched to the parcel they fall inside. '
          'ERF numbers are looked up directly — set the suburb so they '
          'resolve to the right one.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _buildSidePane(BuildContext context) {
    final theme = Theme.of(context);
    final withErf = _preview.where((e) => e.hasErfNumber).length;
    final withAddress =
        _preview.where((e) => e.hasAddress && !e.hasErfNumber).length;
    final unusable = _preview.where((e) => !e.isUsable).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          controller: _suburbController,
          decoration: InputDecoration(
            labelText: 'Suburb (recommended)',
            helperText: 'Enter to search (30-60s)',
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            suffixIcon: _isSearchingRegions
                ? const Padding(
                    padding: EdgeInsets.all(10),
                    child: SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : (_region != null
                    ? const Icon(Icons.check_circle, color: Colors.green)
                    : IconButton(
                        icon: const Icon(Icons.search, size: 20),
                        onPressed: _searchRegions,
                      )),
          ),
          onChanged: _onSuburbChanged,
          onSubmitted: (_) => _searchRegions(),
        ),
        if (_isSearchingRegions)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: LinearProgressIndicator(),
          ),
        if (_regionError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _regionError!,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.error),
            ),
          ),
        if (_region == null && _regions.isNotEmpty)
          Container(
            constraints: const BoxConstraints(maxHeight: 130),
            margin: const EdgeInsets.only(top: 6),
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: _regions.length,
              itemBuilder: (context, index) {
                final region = _regions[index];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  title: Text(region.minRegion),
                  subtitle: region.majRegion.isEmpty
                      ? null
                      : Text(region.majRegion),
                  onTap: () {
                    setState(() {
                      _region = region;
                      _suburbController.text = region.minRegion;
                      _regions = [];
                    });
                  },
                );
              },
            ),
          ),
        const SizedBox(height: 12),
        DropdownButtonFormField<ErfSearchScope>(
          initialValue: _scope,
          isDense: true,
          decoration: InputDecoration(
            labelText: 'Search area',
            helperText: _scope.description,
            helperMaxLines: 2,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          items: [
            for (final scope in ErfSearchScope.values)
              DropdownMenuItem(value: scope, child: Text(scope.label)),
          ],
          onChanged: (value) {
            if (value != null) setState(() => _scope = value);
          },
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _labelController,
          decoration: InputDecoration(
            labelText: 'Name this list',
            hintText: 'Used for the map and file name',
            isDense: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Text('Preview', style: theme.textTheme.titleSmall),
            const Spacer(),
            if (_preview.isNotEmpty)
              Text('${_preview.length} lines',
                  style: theme.textTheme.labelSmall),
          ],
        ),
        if (_preview.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              '$withErf by ERF · $withAddress by address'
              '${unusable > 0 ? ' · $unusable unreadable' : ''}',
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              border: Border.all(color: theme.colorScheme.outlineVariant),
              borderRadius: BorderRadius.circular(12),
            ),
            child: _preview.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(
                        'Paste your list to see how each line will be read.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant),
                      ),
                    ),
                  )
                : ListView.builder(
                    itemCount: _preview.length,
                    itemBuilder: (context, index) {
                      final entry = _preview[index];
                      return ListTile(
                        dense: true,
                        visualDensity: VisualDensity.compact,
                        leading: Icon(
                          !entry.isUsable
                              ? Icons.help_outline
                              : entry.hasErfNumber
                                  ? Icons.tag
                                  : Icons.place_outlined,
                          size: 18,
                          color: entry.isUsable ? null : theme.colorScheme.error,
                        ),
                        title: Text(
                          entry.parsedLabel,
                          style: const TextStyle(fontSize: 12),
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: entry.isUsable
                            ? null
                            : const Text('Will be skipped',
                                style: TextStyle(fontSize: 11)),
                      );
                    },
                  ),
          ),
        ),
      ],
    );
  }
}
