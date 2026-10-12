import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../../shareable_maps/providers/shareable_map_provider.dart';
import '../../shareable_maps/widgets/shareable_map_editor.dart';
import '../adapters/erf_property_adapter.dart';
import '../models/erf_area.dart';
import '../models/erf_list_entry.dart';
import '../models/erf_property.dart';
import '../providers/erf_property_provider.dart';
import '../services/csg_property_service.dart';
import '../services/erf_kml_service.dart';
import '../widgets/erf_area_card.dart';
import '../widgets/erf_download_dialog.dart';
import '../widgets/erf_paste_list_dialog.dart';
import '../widgets/erf_task_panel.dart';

/// Main screen for the ERF Property Viewer.
///
/// Three things happen here:
///  1. **Download** cadastral parcels for any suburb (or a radius around a
///     place) and keep them as a named area.
///  2. **Select** parcels by pasting a list of addresses and/or ERF numbers.
///  3. **Share** the result — highlighted on the map, or exported as KML.
///
/// Layout adapts at [_wideBreakpoint]: wide windows get a persistent areas
/// sidebar beside the working list, narrow ones stack the same content with
/// the areas in a horizontal strip.
class ErfPropertyScreen extends riverpod.ConsumerStatefulWidget {
  const ErfPropertyScreen({super.key});

  /// Above this width the sidebar and content sit side by side.
  static const double _wideBreakpoint = 900;

  @override
  riverpod.ConsumerState<ErfPropertyScreen> createState() =>
      _ErfPropertyScreenState();
}

class _ErfPropertyScreenState
    extends riverpod.ConsumerState<ErfPropertyScreen> {
  final _addressController = TextEditingController();
  bool _isSearching = false;
  String? _searchError;

  @override
  void initState() {
    super.initState();
    ref.read(erfPropertyRiverpod).initialize();
  }

  @override
  void dispose() {
    _addressController.dispose();
    super.dispose();
  }

  void _snack(String message, {bool isError = false}) {
    if (!mounted) return;
    final scheme = Theme.of(context).colorScheme;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        width: 520,
        backgroundColor: isError ? scheme.errorContainer : null,
        showCloseIcon: true,
      ));
  }

  // ── Actions ─────────────────────────────────────────────────────────

  Future<void> _searchAddress() async {
    final address = _addressController.text.trim();
    if (address.isEmpty) return;

    setState(() {
      _isSearching = true;
      _searchError = null;
    });

    final provider = ref.read(erfPropertyRiverpod);
    ErfProperty? result;
    String? failure;
    try {
      result = await provider.findPropertyByAddress(address);
    } on CsgException catch (e) {
      failure = e.message;
    } catch (e) {
      failure = 'Lookup failed: $e';
    }

    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _searchError =
          failure ?? (result == null ? 'No ERF found for "$address"' : null);
    });

    if (result != null) {
      provider.setSelectionFromProperties([result], label: address);
    }
  }

  Future<void> _importSavedData() async {
    final provider = ref.read(erfPropertyRiverpod);
    final count = await provider.importSavedData();
    _snack(
      count > 0
          ? 'Packed $count parcels into area files and freed their documents'
          : (provider.error ?? 'No loose ERF documents found.'),
      isError: count == 0 && provider.error != null,
    );
  }

  Future<void> _openDownloadDialog() async {
    final request = await showDialog<ErfDownloadRequest>(
      context: context,
      builder: (_) => const ErfDownloadDialog(),
    );
    if (request == null || !mounted) return;

    final provider = ref.read(erfPropertyRiverpod);

    // Ask how big this is before committing. Cadastral minor regions are
    // suburbs in some provinces but entire metros in others — picking
    // "CAPE TOWN" means about 120,000 parcels and hours of downloading.
    // The map picker has already counted, so that path skips the round trip.
    final int expected;
    try {
      expected = request.knownCount ??
          (request.region != null
              ? await provider.countRegionParcels(request.region!)
              : request.township != null
                  ? await provider.countTownshipParcels(request.township!)
                  : await provider.countBoundsParcels(request.bounds!));
    } on CsgException catch (e) {
      _snack(e.message, isError: true);
      return;
    }

    if (!mounted) return;
    if (expected == 0) {
      _snack('That area has no ERF parcels in the cadastral register.');
      return;
    }
    if (!await _confirmDownloadSize(request, expected)) return;

    final count = request.township != null
        ? await provider.downloadTownship(request.township!,
            expectedTotal: expected)
        : request.region != null
            ? await provider.downloadRegion(request.region!,
                expectedTotal: expected)
            : await provider.downloadBounds(request.bounds!,
                name: request.name, expectedTotal: expected);

    // A download can succeed while storing it fails, so the error wins —
    // otherwise "Downloaded 9 954 parcels" would sit on top of a warning
    // that none of them were saved.
    if (provider.error != null) {
      _snack(provider.error!, isError: true);
    } else if (count > 0) {
      _snack('Downloaded $count ERF parcels');
    }
  }

  /// Confirm a download once its size is known, with an honest time estimate.
  Future<bool> _confirmDownloadSize(
      ErfDownloadRequest request, int expected) async {
    final name =
        request.township?.name ?? request.region?.minRegion ?? request.name;

    // The register answers in roughly 40 seconds per 1000-parcel page, and
    // does not get faster on repeat.
    final pages = (expected / 1000).ceil();
    final minutes = (pages * 40 / 60).ceil();
    final estimate = minutes <= 1 ? 'about a minute' : 'about $minutes minutes';

    // A suburb picked on the map is already scoped to its own boundary, so
    // the metro warning does not apply there.
    final huge = expected > 25000 && request.township == null;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: Icon(huge ? Icons.warning_amber_rounded : Icons.cloud_download,
            size: 32),
        title: Text('Download $name?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$name holds ${_thousands(expected)} ERF parcels.'),
            const SizedBox(height: 8),
            Text('Downloading takes $estimate and stores every parcel '
                'boundary as one compressed file.'),
            if (huge) ...[
              const SizedBox(height: 12),
              Text(
                'That is a very large area. In the Western Cape a cadastral '
                'region covers a whole metro rather than one suburb — if you '
                'only need a neighbourhood, cancel and use "Around a place" '
                'instead.',
                style: TextStyle(
                    color: Theme.of(dialogContext).colorScheme.error),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              'You can stop the download at any point and keep what has '
              'already arrived.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.pop(dialogContext, true),
            icon: const Icon(Icons.download),
            label: Text(huge ? 'Download anyway' : 'Download'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  static String _thousands(int value) => value.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+$)'),
        (m) => '${m[1]} ',
      );

  Future<void> _openPasteDialog() async {
    final request = await showDialog<ErfPasteRequest>(
      context: context,
      builder: (_) => const ErfPasteListDialog(),
    );
    if (request == null || !mounted) return;

    final provider = ref.read(erfPropertyRiverpod);
    provider.scope = request.scope;
    final matches = await provider.resolveList(
      request.text,
      region: request.region,
      label: request.label,
    );

    final matched =
        matches.where((m) => m.status == ErfMatchStatus.matched).length;
    _snack('Matched $matched of ${matches.length} entries',
        isError: matched == 0);
  }

  Future<void> _openMap({
    List<ErfProperty>? selected,
    List<ErfProperty>? context,
    String? title,
  }) async {
    final mapProvider = ref.read(shareableMapRiverpod);
    final erfProvider = ref.read(erfPropertyRiverpod);

    final adapter = ErfPropertyAdapter(
      selectedProperties: selected ?? erfProvider.selectedProperties,
      preloadedProperties: context ?? erfProvider.properties,
      title: title,
    );

    try {
      await mapProvider.loadFromAdapter(adapter);
      if (!mounted) return;
      Navigator.push(
        this.context,
        MaterialPageRoute(builder: (_) => const ShareableMapEditor()),
      );

      // Tell the user what the map is showing. When a selection is on
      // screen the surrounding parcels start hidden for responsiveness, and
      // silently omitting them would read as missing data.
      if (!mounted) return;
      if (adapter.truncatedContext > 0) {
        _snack(
          'Showing ${_thousands(adapter.maxContextPolygons)} of '
          '${_thousands(adapter.maxContextPolygons + adapter.truncatedContext)} '
          'parcels — the rest are omitted to keep the map responsive.',
        );
      } else if (adapter.selectedProperties.isNotEmpty &&
          adapter.preloadedProperties != null &&
          adapter.preloadedProperties!.length >
              adapter.selectedProperties.length) {
        _snack(
          'Showing your ${adapter.selectedProperties.length} searched '
          'ERFs. Turn on “All parcels in area” in the layers panel to see '
          'the rest.',
        );
      }
    } catch (e) {
      _snack('Error opening map: $e', isError: true);
    }
  }

  Future<void> _exportKml({
    required List<ErfProperty> selected,
    required String label,
    List<ErfProperty> context = const [],
    List<ErfListEntry> unmatched = const [],
  }) async {
    if (selected.isEmpty) {
      _snack('Nothing to export yet.');
      return;
    }

    final includeContext = context.isEmpty
        ? false
        : await showDialog<bool>(
              context: this.context,
              builder: (dialogContext) => AlertDialog(
                icon: const Icon(Icons.public, size: 32),
                title: const Text('Export KML'),
                content: Text(
                  '${selected.length} selected parcels will be exported.\n\n'
                  'Also include the ${context.length} surrounding parcels as '
                  'a second, hidden layer?',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(dialogContext, false),
                    child: const Text('Selected only'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(dialogContext, true),
                    child: const Text('Include surrounding'),
                  ),
                ],
              ),
            ) ??
            false;

    final kml = ErfKmlService.buildKml(
      documentName: label,
      selected: selected,
      context: includeContext ? context : const [],
      unmatched: unmatched,
    );

    final fileName = ErfKmlService.fileNameFor(label);
    final path = await ErfKmlService.download(kml, fileName);

    _snack(path == null ? 'Exported $fileName' : 'Exported $fileName → $path');
  }

  Future<void> _confirmDeleteArea(
      ErfPropertyProvider provider, ErfArea area) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        icon: const Icon(Icons.delete_outline, size: 32),
        title: Text('Remove ${area.name}?'),
        content: Text(
          'This deletes the stored file holding ${area.propertyCount} parcels'
          '${area.sizeLabel.isEmpty ? '' : ' (${area.sizeLabel})'}. '
          'You can download the area again at any time.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await provider.deleteArea(area);
    }
  }

  // ── Build ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final provider = ref.watch(erfPropertyRiverpod);

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide =
            constraints.maxWidth >= ErfPropertyScreen._wideBreakpoint;

        return Scaffold(
          appBar: AppBar(
            title: const Text('ERF Property Viewer'),
            actions: _buildActions(provider, isWide),
          ),
          floatingActionButton: isWide
              ? null
              : FloatingActionButton.extended(
                  onPressed: provider.isLoading ? null : _openPasteDialog,
                  icon: const Icon(Icons.playlist_add),
                  label: const Text('Paste list'),
                ),
          body: SafeArea(
            child: Column(
              children: [
                if (provider.hasUnimportedData && !provider.isLoading)
                  _buildImportBanner(),
                if (provider.error != null) _buildError(provider),
                if (provider.task != null)
                  Padding(
                    padding: EdgeInsets.fromLTRB(16, 12, 16, isWide ? 0 : 4),
                    child: ErfTaskPanel(
                      task: provider.task!,
                      compact: !isWide,
                      onCancel: provider.cancelTask,
                    ),
                  ),
                Expanded(
                  child: isWide
                      ? _buildWideLayout(provider)
                      : _buildNarrowLayout(provider),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  List<Widget> _buildActions(ErfPropertyProvider provider, bool isWide) {
    final hasSelection = provider.hasSelection;
    final busy = provider.isLoading;

    return [
      if (isWide) ...[
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton.tonalIcon(
            onPressed: busy ? null : _openDownloadDialog,
            icon: const Icon(Icons.cloud_download, size: 18),
            label: const Text('Download suburb'),
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: FilledButton.icon(
            onPressed: busy ? null : _openPasteDialog,
            icon: const Icon(Icons.playlist_add, size: 18),
            label: const Text('Paste list'),
          ),
        ),
      ] else
        IconButton(
          icon: const Icon(Icons.cloud_download),
          tooltip: 'Download a suburb',
          onPressed: busy ? null : _openDownloadDialog,
        ),
      IconButton(
        icon: const Icon(Icons.map_outlined),
        tooltip: hasSelection ? 'Map selected ERFs' : 'Map this area',
        onPressed: (busy || (!hasSelection && provider.properties.isEmpty))
            ? null
            : () => _openMap(title: provider.selectionLabel),
      ),
      IconButton(
        icon: const Icon(Icons.download_for_offline_outlined),
        tooltip: hasSelection
            ? 'Export selection as KML'
            : 'Select ERFs first to export',
        onPressed: (busy || !hasSelection)
            ? null
            : () => _exportKml(
                  selected: provider.selectedProperties,
                  label: provider.selectionLabel,
                  context: provider.properties,
                  unmatched: provider.unmatchedEntries,
                ),
      ),
      PopupMenuButton<String>(
        onSelected: (value) {
          if (value == 'import') _importSavedData();
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'import',
            child: ListTile(
              leading: Icon(Icons.inventory_2_outlined),
              title: Text('Convert loose ERF documents'),
              contentPadding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    ];
  }

  // ── Layouts ─────────────────────────────────────────────────────────

  Widget _buildWideLayout(ErfPropertyProvider provider) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(width: 300, child: _buildSidebar(provider)),
        const VerticalDivider(width: 1),
        Expanded(child: _buildContent(provider)),
      ],
    );
  }

  Widget _buildNarrowLayout(ErfPropertyProvider provider) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
          child: _buildSearchField(),
        ),
        if (provider.areas.isNotEmpty) _buildAreaStrip(provider),
        const SizedBox(height: 4),
        Expanded(child: _buildContent(provider)),
      ],
    );
  }

  /// Wide-layout sidebar: search plus the downloaded areas.
  Widget _buildSidebar(ErfPropertyProvider provider) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _buildSearchField(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            children: [
              Text('Downloaded areas',
                  style: Theme.of(context).textTheme.titleSmall),
              const Spacer(),
              Text(
                '${provider.areas.length}',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ),
        ),
        Expanded(
          child: provider.areas.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    'Nothing downloaded yet. Use “Download suburb” to pull a '
                    'suburb’s parcels from the Surveyor-General register.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color:
                              Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: provider.areas.length,
                  itemBuilder: (context, index) {
                    final area = provider.areas[index];
                    return ErfAreaCard(
                      area: area,
                      selected: provider.activeArea?.id == area.id,
                      enabled: !provider.isLoading,
                      onOpen: () => provider.openArea(area),
                      onDelete: () => _confirmDeleteArea(provider, area),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// Narrow-layout equivalent: areas as a horizontal strip of chips.
  Widget _buildAreaStrip(ErfPropertyProvider provider) {
    return SizedBox(
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        itemCount: provider.areas.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final area = provider.areas[index];
          final isActive = provider.activeArea?.id == area.id;
          return InputChip(
            avatar: Icon(
              area.source == ErfAreaSource.region
                  ? Icons.location_city_rounded
                  : Icons.crop_free_rounded,
              size: 18,
            ),
            label: Text(area.sizeLabel.isEmpty
                ? '${area.name} · ${area.propertyCount}'
                : '${area.name} · ${area.propertyCount} · ${area.sizeLabel}'),
            selected: isActive,
            onPressed:
                provider.isLoading ? null : () => provider.openArea(area),
            onDeleted: provider.isLoading
                ? null
                : () => _confirmDeleteArea(provider, area),
            deleteIcon: const Icon(Icons.close, size: 16),
          );
        },
      ),
    );
  }

  Widget _buildContent(ErfPropertyProvider provider) {
    if (provider.hasSelection || provider.matches.isNotEmpty) {
      return _buildSelectionList(provider);
    }
    return _buildAreaPropertyList(provider);
  }

  // ── Pieces ──────────────────────────────────────────────────────────

  Widget _buildSearchField() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _addressController,
          decoration: InputDecoration(
            hintText: 'Find one address…',
            helperText: 'Geocodes, then finds the parcel it falls inside',
            helperMaxLines: 2,
            prefixIcon: const Icon(Icons.search),
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide.none,
            ),
            isDense: true,
            suffixIcon: _isSearching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  )
                : IconButton(
                    icon: const Icon(Icons.arrow_forward),
                    onPressed: _searchAddress,
                  ),
          ),
          onSubmitted: (_) => _searchAddress(),
        ),
        if (_searchError != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              _searchError!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    );
  }

  /// Shown when Firestore holds parcels but no areas describe them — ERF
  /// data saved by an earlier version, which would otherwise stay invisible.
  Widget _buildImportBanner() {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 12, 10),
        child: Row(
          children: [
            Icon(Icons.inventory_2_outlined,
                color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'You have ERF parcels stored as individual Firestore '
                'documents. Converting packs each area into a single '
                'compressed file and frees those documents.',
                style: TextStyle(color: scheme.onSecondaryContainer),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _importSavedData,
              child: const Text('Convert'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(ErfPropertyProvider provider) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                provider.error!,
                style: TextStyle(color: scheme.onErrorContainer),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 18),
              onPressed: provider.clearError,
            ),
          ],
        ),
      ),
    );
  }

  /// The pasted list, with what each line resolved to.
  Widget _buildSelectionList(ErfPropertyProvider provider) {
    final matched = provider.selectedProperties.length;
    final total = provider.matches.length;
    final ambiguous = provider.matches
        .where((m) => m.status == ErfMatchStatus.ambiguous)
        .length;
    final failed = provider.matches
        .where((m) =>
            m.status == ErfMatchStatus.notFound ||
            m.status == ErfMatchStatus.error)
        .length;

    return Column(
      children: [
        _buildContentHeader(
          title: provider.selectionLabel,
          subtitle: '$matched of $total matched · ${provider.scope.label}',
          chips: [
            if (matched > 0) _StatChip(Icons.check_circle, '$matched', Colors.green),
            if (ambiguous > 0)
              _StatChip(Icons.help, '$ambiguous', Colors.orange),
            if (failed > 0)
              _StatChip(Icons.cancel, '$failed',
                  Theme.of(context).colorScheme.error),
          ],
          actions: [
            TextButton.icon(
              onPressed: provider.clearSelection,
              icon: const Icon(Icons.clear_all, size: 18),
              label: const Text('Clear'),
            ),
            const SizedBox(width: 8),
            FilledButton.icon(
              onPressed: matched == 0
                  ? null
                  : () => _openMap(title: provider.selectionLabel),
              icon: const Icon(Icons.map),
              label: const Text('View on map'),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: provider.matches.length,
            itemBuilder: (context, index) =>
                _buildMatchTile(provider, index, provider.matches[index]),
          ),
        ),
      ],
    );
  }

  Widget _buildContentHeader({
    required String title,
    required String subtitle,
    List<Widget> chips = const [],
    List<Widget> actions = const [],
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        runSpacing: 8,
        spacing: 12,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(title,
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant)),
                  for (final chip in chips) ...[
                    const SizedBox(width: 8),
                    chip,
                  ],
                ],
              ),
            ],
          ),
          Row(mainAxisSize: MainAxisSize.min, children: actions),
        ],
      ),
    );
  }

  Widget _buildMatchTile(
      ErfPropertyProvider provider, int index, ErfMatch match) {
    final scheme = Theme.of(context).colorScheme;

    late final IconData icon;
    late final Color color;
    switch (match.status) {
      case ErfMatchStatus.matched:
        icon = Icons.check_circle;
        color = Colors.green;
      case ErfMatchStatus.ambiguous:
        icon = Icons.help;
        color = Colors.orange;
      case ErfMatchStatus.notFound:
        icon = Icons.cancel;
        color = scheme.error;
      case ErfMatchStatus.error:
        icon = Icons.error;
        color = scheme.error;
      case ErfMatchStatus.pending:
        icon = Icons.hourglass_empty;
        color = scheme.outline;
    }

    final property = match.resolvedProperty;

    return ListTile(
      dense: true,
      leading: Icon(icon, color: color),
      title: Text(
        property?.displayLabel ?? match.entry.parsedLabel,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        property != null
            ? '${property.minRegion} · ${property.area.toStringAsFixed(1)} m²'
                '${property.lpiCode.isEmpty ? '' : ' · ${property.lpiCode}'}'
            : (match.message ?? match.entry.rawLine),
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (match.status == ErfMatchStatus.ambiguous)
            TextButton(
              onPressed: () => _pickCandidate(provider, index, match),
              child: Text('Pick (${match.candidates.length})'),
            ),
          // An ERF number that found nothing inside the working area may
          // still exist elsewhere; widen just this line rather than every
          // lookup.
          if (match.status == ErfMatchStatus.notFound &&
              match.entry.hasErfNumber &&
              provider.scope.isRestricted)
            TextButton(
              onPressed: provider.isLoading
                  ? null
                  : () => provider.widenSearch(index),
              child: const Text('Search wider'),
            ),
          if (property != null)
            IconButton(
              icon: const Icon(Icons.my_location, size: 18),
              tooltip: 'Show just this one',
              onPressed: () =>
                  _openMap(selected: [property], title: property.displayLabel),
            ),
          IconButton(
            icon: const Icon(Icons.close, size: 18),
            tooltip: 'Remove from list',
            onPressed: () => provider.removeMatch(index),
          ),
        ],
      ),
    );
  }

  Future<void> _pickCandidate(
      ErfPropertyProvider provider, int index, ErfMatch match) async {
    final chosen = await showDialog<ErfProperty>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: Text('Which ERF ${match.entry.erfNumber}?'),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              '${match.candidates.length} parcels carry this number in '
              '${provider.scope.label}.',
              style: Theme.of(dialogContext).textTheme.bodySmall,
            ),
          ),
          for (final candidate in match.candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, candidate),
              child: ListTile(
                dense: true,
                title: Text(
                  candidate.minRegion.isEmpty
                      ? 'ERF ${candidate.tagValue}'
                      : candidate.minRegion,
                ),
                subtitle: Text(
                  [
                    'ERF ${candidate.tagValue}',
                    if (candidate.majRegion.isNotEmpty) candidate.majRegion,
                    if (candidate.province.isNotEmpty) candidate.province,
                    '${candidate.area.toStringAsFixed(0)} m²',
                  ].join(' · '),
                ),
              ),
            ),
        ],
      ),
    );
    if (chosen != null) {
      provider.chooseCandidate(index, chosen);
    }
  }

  /// Parcels of the open area, when no list has been pasted.
  Widget _buildAreaPropertyList(ErfPropertyProvider provider) {
    if (provider.properties.isEmpty) {
      return _buildEmptyState(provider);
    }

    return Column(
      children: [
        _buildContentHeader(
          title: provider.activeArea?.name ?? 'Loaded parcels',
          subtitle: '${_thousands(provider.properties.length)} parcels'
              '${provider.activeArea?.sizeLabel.isNotEmpty == true ? ' · ${provider.activeArea!.sizeLabel}' : ''}',
          actions: [
            FilledButton.icon(
              onPressed: () => _openMap(
                selected: const [],
                title: provider.activeArea?.name,
              ),
              icon: const Icon(Icons.map),
              label: const Text('View on map'),
            ),
          ],
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 88),
            itemCount: provider.properties.length,
            itemBuilder: (context, index) {
              final property = provider.properties[index];
              return ListTile(
                dense: true,
                title: Text(property.displayLabel),
                subtitle: Text(
                  '${property.minRegion} · '
                  '${property.area.toStringAsFixed(1)} m²'
                  '${property.suburb != null ? ' · ${property.suburb}' : ''}',
                ),
                trailing: Text(
                  'ERF ${property.tagValue.isNotEmpty ? property.tagValue : property.erfNumber}',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
                onTap: () => _openMap(
                  selected: [property],
                  title: property.displayLabel,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildEmptyState(ErfPropertyProvider provider) {
    final theme = Theme.of(context);
    final busy = provider.isLoading;

    final String headline;
    final String body;
    if (provider.hasUnimportedData) {
      headline = 'Saved ERF data found';
      body = 'Convert it above to load and use it.';
    } else if (provider.areas.isEmpty) {
      headline = 'No suburbs downloaded yet';
      body = 'Download a suburb, then paste a list of addresses or ERF '
          'numbers to highlight them on a map and export a KML.';
    } else {
      headline = 'Pick an area to open it';
      body = 'Opening an area downloads one compressed file, not one record '
          'per parcel.';
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.location_city_rounded,
                  size: 56, color: theme.colorScheme.primary.withValues(alpha: 0.4)),
              const SizedBox(height: 16),
              Text(headline,
                  style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 12,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.icon(
                    onPressed: busy ? null : _openDownloadDialog,
                    icon: const Icon(Icons.cloud_download),
                    label: const Text('Download a suburb'),
                  ),
                  OutlinedButton.icon(
                    onPressed: busy ? null : _openPasteDialog,
                    icon: const Icon(Icons.playlist_add),
                    label: const Text('Paste a list'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small count badge used in the content header.
class _StatChip extends StatelessWidget {
  const _StatChip(this.icon, this.label, this.color);

  final IconData icon;
  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 3),
        Text(label,
            style: Theme.of(context)
                .textTheme
                .labelSmall
                ?.copyWith(color: color, fontWeight: FontWeight.w600)),
      ],
    );
  }
}
