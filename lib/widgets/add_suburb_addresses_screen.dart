import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/address_import_parser.dart';
import '../services/address_service_v2.dart';
import 'geocode/geocode_ui.dart';

/// Paste-and-preview import for a suburb's delivery list.
///
/// The old version parsed on every keystroke and told you only a count.
/// This one shows the parsed table before anything is written, names what
/// it dropped and why, and lets you choose whether the paste replaces the
/// suburb or is added to it — because pasting a second batch over a
/// geocoded list used to wipe the coordinates silently.
class AddSuburbAddressesScreen extends StatefulWidget {
  /// Pre-fills the suburb, when coming from a suburb's workspace.
  final String? initialSuburb;

  const AddSuburbAddressesScreen({super.key, this.initialSuburb});

  @override
  State<AddSuburbAddressesScreen> createState() =>
      _AddSuburbAddressesScreenState();
}

enum _ImportMode { append, replace }

class _AddSuburbAddressesScreenState extends State<AddSuburbAddressesScreen> {
  final AddressServiceV2 _addressService =
      AddressServiceV2(FirebaseFirestore.instance);
  late final TextEditingController _suburbController =
      TextEditingController(text: widget.initialSuburb ?? '');
  final TextEditingController _addressesController = TextEditingController();

  AddressParseResult _result = AddressParseResult.empty;
  AddressParseMode _mode = AddressParseMode.auto;
  _ImportMode _importMode = _ImportMode.append;
  bool _dropDuplicates = true;
  bool _isSaving = false;
  int _existingCount = 0;

  @override
  void initState() {
    super.initState();
    _addressesController.addListener(_reparse);
    _suburbController.addListener(_reparse);
    if (widget.initialSuburb != null) _loadExistingCount();
  }

  @override
  void dispose() {
    _suburbController.dispose();
    _addressesController.dispose();
    super.dispose();
  }

  Future<void> _loadExistingCount() async {
    final suburb = _suburbController.text.trim().toLowerCase();
    if (suburb.isEmpty) return;
    final stats = await _addressService.getSuburbStats(suburb);
    if (mounted) setState(() => _existingCount = stats['total'] ?? 0);
  }

  void _reparse() {
    final suburb = _suburbController.text.trim();
    final parser = AddressImportParser(defaultSuburb: suburb);
    setState(() {
      _result = parser.parse(
        _addressesController.text,
        mode: _mode,
        dropDuplicates: _dropDuplicates,
      );
    });
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text == null) return;
    _addressesController.text = data!.text!;
  }

  Future<void> _save() async {
    final suburb = _suburbController.text.trim().toLowerCase();
    if (suburb.isEmpty) {
      showGeocodeSnack(context, 'Give the suburb a name first.', isError: true);
      return;
    }
    if (_result.isEmpty) {
      showGeocodeSnack(context, 'Nothing to import yet.', isError: true);
      return;
    }

    if (_importMode == _ImportMode.replace && _existingCount > 0) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Replace the whole list?'),
          content: Text(
            '$suburb already holds $_existingCount address'
            '${_existingCount == 1 ? '' : 'es'}. Replacing discards them '
            'along with any coordinates already found for them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style:
                  FilledButton.styleFrom(backgroundColor: GeocodeColors.danger),
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Replace'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }

    setState(() => _isSaving = true);
    try {
      final raw = _result.addresses.map((a) => a.toRawMap()).toList();
      final int added;
      if (_importMode == _ImportMode.replace) {
        await _addressService.setSuburbAddresses(suburb, raw);
        added = raw.length;
      } else {
        added = await _addressService.appendSuburbAddresses(
          suburb,
          raw,
          skipDuplicates: _dropDuplicates,
        );
      }

      if (!mounted) return;
      final skippedExisting = raw.length - added;
      showGeocodeSnack(
        context,
        'Added $added address${added == 1 ? '' : 'es'} to $suburb'
        '${skippedExisting > 0 ? ' · $skippedExisting already there' : ''}.',
      );
      Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        showGeocodeSnack(context, 'Import failed: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Import addresses'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _isSaving || _result.isEmpty ? null : _save,
              icon: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_rounded, size: 18),
              label: Text(_isSaving
                  ? 'Saving…'
                  : 'Import ${_result.addresses.length}'),
            ),
          ),
        ],
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final wide = constraints.maxWidth >= 900;
          final input = _buildInputPane();
          final preview = _buildPreviewPane();

          if (wide) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(width: 460, child: input),
                const VerticalDivider(width: 1),
                Expanded(child: preview),
              ],
            );
          }
          return Column(
            children: [
              Expanded(flex: 3, child: input),
              const Divider(height: 1),
              Expanded(flex: 4, child: preview),
            ],
          );
        },
      ),
    );
  }

  Widget _buildInputPane() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _suburbController,
            textCapitalization: TextCapitalization.words,
            onSubmitted: (_) => _loadExistingCount(),
            onTapOutside: (_) => _loadExistingCount(),
            decoration: InputDecoration(
              labelText: 'Suburb',
              hintText: 'e.g. Pinelands',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.location_city_rounded),
              helperText: _existingCount > 0
                  ? 'Already holds $_existingCount address'
                      '${_existingCount == 1 ? '' : 'es'}'
                  : null,
            ),
          ),
          const SizedBox(height: 16),

          TextField(
            controller: _addressesController,
            maxLines: 12,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            decoration: InputDecoration(
              labelText: 'Paste the addresses',
              alignLabelWithHint: true,
              border: const OutlineInputBorder(),
              hintText: '30 Riverside Road, Pinelands, Cape Town, 7405\n'
                  '19 Morningside Street, Pinelands\n'
                  '…or paste a whole column out of a spreadsheet',
              hintStyle: TextStyle(color: Theme.of(context).hintColor),
            ),
          ),
          const SizedBox(height: 10),

          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _paste,
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: const Text('Paste'),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _addressesController.text.isEmpty
                    ? null
                    : () => _addressesController.clear(),
                icon: const Icon(Icons.clear_rounded, size: 16),
                label: const Text('Clear'),
              ),
            ],
          ),

          const Divider(height: 32),

          Text(
            'HOW TO READ IT',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).hintColor,
                ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<AddressParseMode>(
            initialValue: _mode,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              prefixIcon: Icon(Icons.table_rows_rounded, size: 20),
            ),
            items: [
              for (final mode in AddressParseMode.values)
                DropdownMenuItem(value: mode, child: Text(mode.label)),
            ],
            onChanged: (mode) {
              if (mode == null) return;
              setState(() => _mode = mode);
              _reparse();
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _dropDuplicates,
            onChanged: (v) {
              setState(() => _dropDuplicates = v);
              _reparse();
            },
            title: const Text('Skip duplicates'),
            subtitle: const Text('Same street, suburb and city.'),
          ),

          const Divider(height: 32),

          Text(
            'WHERE IT GOES',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  letterSpacing: 1.1,
                  fontWeight: FontWeight.w700,
                  color: Theme.of(context).hintColor,
                ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<_ImportMode>(
            segments: const [
              ButtonSegment(
                value: _ImportMode.append,
                icon: Icon(Icons.playlist_add_rounded, size: 18),
                label: Text('Add to list'),
              ),
              ButtonSegment(
                value: _ImportMode.replace,
                icon: Icon(Icons.swap_horiz_rounded, size: 18),
                label: Text('Replace list'),
              ),
            ],
            selected: {_importMode},
            onSelectionChanged: (s) =>
                setState(() => _importMode = s.first),
          ),
          const SizedBox(height: 8),
          Text(
            _importMode == _ImportMode.append
                ? 'Keeps what is already there, including coordinates already found.'
                : 'Discards the current list for this suburb, coordinates and all.',
            style: TextStyle(
              fontSize: 11.5,
              color: _importMode == _ImportMode.replace
                  ? GeocodeColors.danger
                  : Theme.of(context).hintColor,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreviewPane() {
    if (_result.isEmpty && _addressesController.text.trim().isEmpty) {
      return const GeocodeEmptyState(
        icon: Icons.preview_rounded,
        title: 'Preview appears here',
        message: 'Paste a list on the left and every row is shown exactly as '
            'it will be saved — before anything is written.',
      );
    }

    if (_result.isEmpty) {
      return GeocodeEmptyState(
        icon: Icons.report_gmailerrorred_rounded,
        title: 'Nothing usable in that paste',
        message: 'Try switching "How to read it" to '
            '"${AddressParseMode.singleLine.label}".',
      );
    }

    return Column(
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          decoration: BoxDecoration(
            border: Border(
                bottom: BorderSide(color: Theme.of(context).dividerColor)),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatPill(
                label: 'to import',
                value: '${_result.addresses.length}',
                color: GeocodeColors.success,
                icon: Icons.check_circle_outline_rounded,
              ),
              if (_result.duplicates.isNotEmpty)
                StatPill(
                  label: 'duplicates',
                  value: '${_result.duplicates.length}',
                  color: GeocodeColors.warning,
                  icon: Icons.copy_all_rounded,
                ),
              if (_result.skipped.isNotEmpty)
                StatPill(
                  label: 'unreadable',
                  value: '${_result.skipped.length}',
                  color: GeocodeColors.danger,
                  icon: Icons.error_outline_rounded,
                ),
              StatPill(
                label: 'read as',
                value: _result.modeUsed == AddressParseMode.columns
                    ? 'columns'
                    : 'lines',
                color: GeocodeColors.neutral,
                icon: Icons.rule_rounded,
              ),
              if (_result.headerDetected)
                StatPill(
                  label: 'row used',
                  value: 'header',
                  color: GeocodeColors.brand,
                  icon: Icons.view_headline_rounded,
                ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: _result.addresses.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final parsed = _result.addresses[index];
              return ListTile(
                dense: true,
                leading: CircleAvatar(
                  radius: 14,
                  backgroundColor:
                      GeocodeColors.brand.withValues(alpha: 0.12),
                  child: Text(
                    '${index + 1}',
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: GeocodeColors.brand,
                    ),
                  ),
                ),
                title: Text(
                  parsed.streetAddress.isEmpty
                      ? '(no street)'
                      : parsed.streetAddress,
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
                subtitle: Text(
                  [
                    parsed.suburb,
                    parsed.city,
                    parsed.postalCode,
                    parsed.province,
                  ].where((p) => p.isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 11.5),
                ),
                trailing: parsed.notes.isEmpty
                    ? null
                    : Tooltip(
                        message: parsed.notes,
                        child: const Icon(Icons.sticky_note_2_outlined,
                            size: 16),
                      ),
              );
            },
          ),
        ),
        if (_result.duplicates.isNotEmpty || _result.skipped.isNotEmpty)
          _buildDroppedSummary(),
      ],
    );
  }

  Widget _buildDroppedSummary() {
    final dropped = [
      ..._result.duplicates.map((l) => ('Duplicate', l)),
      ..._result.skipped.map((l) => ('Unreadable', l)),
    ];

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        leading: const Icon(Icons.filter_alt_off_outlined,
            color: GeocodeColors.warning),
        title: Text(
          '${dropped.length} line${dropped.length == 1 ? '' : 's'} not imported',
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 200),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: dropped.length,
              itemBuilder: (context, index) {
                final (reason, line) = dropped[index];
                return ListTile(
                  dense: true,
                  visualDensity: VisualDensity.compact,
                  leading: Text(
                    reason,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: reason == 'Duplicate'
                          ? GeocodeColors.warning
                          : GeocodeColors.danger,
                    ),
                  ),
                  title: Text(
                    line,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        fontSize: 11.5, fontFamily: 'monospace'),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
