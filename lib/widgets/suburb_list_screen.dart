import 'package:clmschedule/utils/text_search.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../erf_property/providers/erf_property_provider.dart';
import '../erf_property/widgets/erf_paste_list_dialog.dart';
import '../services/address_service_v2.dart';
import '../services/erf_import_service.dart';
import '../services/erf_parcel_store.dart';
import 'add_suburb_addresses_screen.dart';
import 'geocode/geocode_ui.dart';
import 'master_map_viewer.dart';
import 'suburb_addresses_screen.dart';

/// Landing screen for the geocoding tool: every suburb with a delivery
/// list, how far each has got, and a way in.
class SuburbListScreen extends riverpod.ConsumerStatefulWidget {
  const SuburbListScreen({super.key});

  @override
  riverpod.ConsumerState<SuburbListScreen> createState() =>
      _SuburbListScreenState();
}

enum _SuburbSort {
  name('Name'),
  size('Most addresses'),
  outstanding('Most outstanding');

  const _SuburbSort(this.label);
  final String label;
}

class _SuburbListScreenState
    extends riverpod.ConsumerState<SuburbListScreen> {
  final AddressServiceV2 _addressService =
      AddressServiceV2(FirebaseFirestore.instance);
  final ErfParcelStore _parcelStore =
      ErfParcelStore(FirebaseFirestore.instance);
  bool _isImporting = false;
  final TextEditingController _searchController = TextEditingController();

  Map<String, Map<String, int>> _suburbStats = {};
  bool _isLoading = true;
  String? _errorMessage;
  String _search = '';
  _SuburbSort _sort = _SuburbSort.name;

  @override
  void initState() {
    super.initState();
    _loadStats();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  /// Load every suburb's counts from the single suburbs document.
  ///
  /// One read answers all of them. A failure is surfaced rather than
  /// swallowed — an empty grid and a failed read look identical to the
  /// user otherwise, and "no delivery lists yet" is a very misleading
  /// thing to show someone whose lists are sitting right there.
  Future<void> _loadStats() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final stats = await _addressService.getAllSuburbStats();
      if (mounted) setState(() => _suburbStats = stats);
    } catch (e) {
      debugPrint('Error loading suburb stats: $e');
      if (mounted) setState(() => _errorMessage = '$e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  List<String> get _visibleSuburbs {
    final search = TextSearch(_search);
    final names =
        _suburbStats.keys.where((s) => search.matches([s])).toList();

    names.sort((a, b) {
      final sa = _suburbStats[a]!;
      final sb = _suburbStats[b]!;
      return switch (_sort) {
        _SuburbSort.name => a.compareTo(b),
        _SuburbSort.size => sb['total']!.compareTo(sa['total']!),
        _SuburbSort.outstanding =>
          (sb['total']! - sb['geocoded']!).compareTo(sa['total']! - sa['geocoded']!),
      };
    });
    return names;
  }

  Future<void> _openSuburb(String suburb) async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SuburbAddressesScreen(suburb: suburb)),
    );
    if (mounted) _loadStats();
  }

  /// Start a run from a pasted list of ERFs, without needing a suburb to
  /// exist first.
  ///
  /// This lives here as well as inside a suburb because this is the screen
  /// someone lands on with nothing set up yet — putting the ERF search only
  /// behind an existing suburb hides it from exactly the person who needs
  /// it. The run's name becomes the list it is imported into.
  Future<void> _importErfList() async {
    if (_isImporting) return;

    final request = await showDialog<ErfPasteRequest>(
      context: context,
      builder: (_) => const ErfPasteListDialog(),
    );
    if (request == null || !mounted) return;

    final suburb = ErfImportService.suburbKeyFrom(
      request.label.isNotEmpty
          ? request.label
          : (request.region?.minRegion ?? ''),
    );

    setState(() => _isImporting = true);
    final erfProvider = ref.read(erfPropertyRiverpod);

    try {
      final existing = await _parcelStore.getParcels(suburb);
      final outcome = await ErfImportService(
        addressService: _addressService,
        parcelStore: _parcelStore,
      ).importList(
        erfProvider: erfProvider,
        text: request.text,
        suburb: suburb,
        region: request.region,
        label: request.label,
        existingParcels: existing,
      );

      if (!mounted) return;
      if (outcome.isEmpty) {
        showGeocodeSnack(context, 'Nothing usable in that list.',
            isError: true);
        return;
      }

      showGeocodeSnack(context, '${outcome.suburb}: ${outcome.summary}');
      await _loadStats();
      if (!mounted) return;
      // Drop straight into the run that was just created — the whole point
      // of pasting a list is to work on it.
      await _openSuburb(suburb);
    } catch (e) {
      if (mounted) {
        showGeocodeSnack(context, 'ERF lookup failed: $e', isError: true);
      }
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  Future<void> _addAddresses() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const AddSuburbAddressesScreen()),
    );
    if (mounted) _loadStats();
  }

  Future<void> _deleteSuburb(String suburb) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${suburb.toUpperCase()}?'),
        content: Text(
          'This removes all ${_suburbStats[suburb]?['total'] ?? 0} addresses '
          'and their coordinates. It cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: GeocodeColors.danger),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await _addressService.deleteSuburb(suburb);
    if (mounted) {
      showGeocodeSnack(context, 'Deleted $suburb.');
      _loadStats();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Geocoding & route planner'),
        actions: [
          if (_suburbStats.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.travel_explore_rounded),
              tooltip: 'All suburbs on one map',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MasterMapViewer()),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            tooltip: 'Reload',
            onPressed: _isLoading ? null : _loadStats,
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4),
            child: OutlinedButton.icon(
              onPressed: _isImporting ? null : _addAddresses,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Addresses'),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 8, right: 12),
            child: FilledButton.icon(
              onPressed: _isImporting ? null : _importErfList,
              icon: _isImporting
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.travel_explore_rounded, size: 18),
              label: Text(_isImporting ? 'Searching…' : 'Search ERFs'),
            ),
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_errorMessage != null) {
      return GeocodeEmptyState(
        icon: Icons.cloud_off_rounded,
        title: 'Could not load the delivery lists',
        message: _errorMessage,
        action: FilledButton.icon(
          onPressed: _loadStats,
          icon: const Icon(Icons.refresh),
          label: const Text('Try again'),
        ),
      );
    }

    if (_suburbStats.isEmpty) {
      return GeocodeEmptyState(
        icon: Icons.location_city_rounded,
        title: 'No delivery lists yet',
        message: 'Paste a list of ERF numbers or addresses to get started. '
            'ERFs are matched against the cadastral register and come back '
            'with their parcel boundaries; anything else is geocoded. Then '
            'the run is ordered, mapped and exported for the driver.',
        action: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: _isImporting ? null : _importErfList,
              icon: const Icon(Icons.travel_explore_rounded),
              label: const Text('Search ERFs'),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: _isImporting ? null : _addAddresses,
              icon: const Icon(Icons.add),
              label: const Text('Addresses only'),
            ),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildOverview(),
        _buildToolbar(),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = (constraints.maxWidth / 380).floor().clamp(1, 4);
              final suburbs = _visibleSuburbs;

              if (suburbs.isEmpty) {
                return GeocodeEmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No suburb matches "$_search"',
                  action: TextButton(
                    onPressed: () {
                      _searchController.clear();
                      setState(() => _search = '');
                    },
                    child: const Text('Clear search'),
                  ),
                );
              }

              return GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  mainAxisExtent: 150,
                ),
                itemCount: suburbs.length,
                itemBuilder: (context, index) =>
                    _buildSuburbCard(suburbs[index]),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildOverview() {
    var total = 0;
    var geocoded = 0;
    var review = 0;
    for (final stats in _suburbStats.values) {
      total += stats['total'] ?? 0;
      geocoded += stats['geocoded'] ?? 0;
      review += stats['review'] ?? 0;
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: Theme.of(context)
            .colorScheme
            .surfaceContainerHighest
            .withValues(alpha: 0.35),
        border:
            Border(bottom: BorderSide(color: Theme.of(context).dividerColor)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            StatPill(
              label: 'suburbs',
              value: '${_suburbStats.length}',
              color: GeocodeColors.depot,
              icon: Icons.location_city_rounded,
            ),
            const SizedBox(width: 8),
            StatPill(
              label: 'addresses',
              value: '$total',
              color: GeocodeColors.neutral,
              icon: Icons.format_list_numbered_rounded,
            ),
            const SizedBox(width: 8),
            StatPill(
              label: 'located',
              value: '$geocoded',
              color: GeocodeColors.success,
              icon: Icons.place_rounded,
            ),
            if (total - geocoded > 0) ...[
              const SizedBox(width: 8),
              StatPill(
                label: 'pending',
                value: '${total - geocoded}',
                color: GeocodeColors.warning,
                icon: Icons.hourglass_empty_rounded,
              ),
            ],
            if (review > 0) ...[
              const SizedBox(width: 8),
              StatPill(
                label: 'to check',
                value: '$review',
                color: GeocodeColors.danger,
                icon: Icons.help_outline_rounded,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (v) => setState(() => _search = v),
              decoration: InputDecoration(
                hintText: 'Search suburbs…',
                prefixIcon: const Icon(Icons.search_rounded, size: 20),
                isDense: true,
                border:
                    OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                suffixIcon: _search.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _search = '');
                        },
                      ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SegmentedButton<_SuburbSort>(
            showSelectedIcon: false,
            segments: [
              for (final sort in _SuburbSort.values)
                ButtonSegment(value: sort, label: Text(sort.label)),
            ],
            selected: {_sort},
            onSelectionChanged: (s) => setState(() => _sort = s.first),
          ),
        ],
      ),
    );
  }

  Widget _buildSuburbCard(String suburb) {
    final stats = _suburbStats[suburb]!;
    final total = stats['total'] ?? 0;
    final geocoded = stats['geocoded'] ?? 0;
    final review = stats['review'] ?? 0;
    final progress = total > 0 ? geocoded / total : 0.0;
    final complete = total > 0 && geocoded == total;

    final accent = total == 0
        ? GeocodeColors.neutral
        : complete
            ? GeocodeColors.success
            : GeocodeColors.brand;

    return Material(
      color: Theme.of(context).colorScheme.surface,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openSuburb(suburb),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Theme.of(context).dividerColor),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      complete
                          ? Icons.check_circle_rounded
                          : Icons.location_city_rounded,
                      color: accent,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      suburb.toUpperCase(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert, size: 18),
                    onSelected: (value) {
                      if (value == 'delete') _deleteSuburb(suburb);
                      if (value == 'open') _openSuburb(suburb);
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(
                        value: 'open',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.open_in_new_rounded, size: 20),
                          title: Text('Open'),
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: ListTile(
                          dense: true,
                          contentPadding: EdgeInsets.zero,
                          leading: Icon(Icons.delete_outline_rounded,
                              size: 20, color: GeocodeColors.danger),
                          title: Text('Delete suburb',
                              style: TextStyle(color: GeocodeColors.danger)),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const Spacer(),
              Row(
                children: [
                  Text(
                    '$geocoded',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      color: accent,
                      height: 1,
                    ),
                  ),
                  Text(
                    ' / $total located',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  ),
                  const Spacer(),
                  if (review > 0)
                    Tooltip(
                      message: '$review pin${review == 1 ? '' : 's'} to check',
                      child: Row(
                        children: [
                          const Icon(Icons.help_outline_rounded,
                              size: 14, color: GeocodeColors.danger),
                          const SizedBox(width: 3),
                          Text(
                            '$review',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: GeocodeColors.danger,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress,
                  minHeight: 6,
                  backgroundColor: accent.withValues(alpha: 0.15),
                  color: accent,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
