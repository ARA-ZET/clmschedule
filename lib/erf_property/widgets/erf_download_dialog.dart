import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/csg_region.dart';
import '../models/csg_township.dart';
import '../providers/erf_property_provider.dart';
import '../services/csg_property_service.dart';
import 'erf_suburb_map_picker.dart';

/// What the user chose to download.
class ErfDownloadRequest {
  /// Set when a cadastral region was picked by name.
  final CsgRegion? region;

  /// Set when a suburb boundary was picked on the map. Preferred in the
  /// Western Cape, where a cadastral region covers the whole metro.
  final CsgTownship? township;

  /// Set when a custom map extent was chosen instead.
  final ErfBounds? bounds;
  final String name;

  /// Parcel count, when the picker already established it.
  final int? knownCount;

  const ErfDownloadRequest.forRegion(CsgRegion this.region)
      : township = null,
        bounds = null,
        knownCount = null,
        name = '';

  const ErfDownloadRequest.forTownship(CsgTownship this.township,
      {this.knownCount})
      : region = null,
        bounds = null,
        name = '';

  const ErfDownloadRequest.forBounds(ErfBounds this.bounds, this.name)
      : region = null,
        township = null,
        knownCount = null;
}

/// Picks an area to download ERF parcels for.
///
/// Two ways in:
///  - **Suburb**: search the CSG cadastral register by name. Any South
///    African suburb in the register can be downloaded whole, by its
///    MIN_CODE.
///  - **Around a place**: geocode any address or landmark and pull every
///    parcel within a radius, for areas whose cadastral name is not obvious.
class ErfDownloadDialog extends riverpod.ConsumerStatefulWidget {
  const ErfDownloadDialog({super.key});

  @override
  riverpod.ConsumerState<ErfDownloadDialog> createState() =>
      _ErfDownloadDialogState();
}

class _ErfDownloadDialogState extends riverpod.ConsumerState<ErfDownloadDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  final _suburbController = TextEditingController();
  final _placeController = TextEditingController();

  bool _isSearching = false;
  List<CsgRegion> _regions = [];
  String? _searchMessage;
  bool _searchFailed = false;

  double _radiusKm = 1.0;
  bool _isLocating = false;
  String? _placeMessage;

  @override
  void dispose() {
    _tabs.dispose();
    _suburbController.dispose();
    _placeController.dispose();
    super.dispose();
  }

  /// Deliberately does not search as you type. Each query against the
  /// cadastral register takes the better part of a minute, so searching is
  /// an explicit act, not a side effect of a keystroke.
  void _onSuburbChanged(String value) {
    if (_regions.isNotEmpty || _searchMessage != null) {
      setState(() {
        _regions = [];
        _searchMessage = null;
        _searchFailed = false;
      });
    }
  }

  Future<void> _runSearch() async {
    final query = _suburbController.text.trim();
    if (query.length < 2) return;

    setState(() {
      _isSearching = true;
      _searchMessage = null;
      _searchFailed = false;
    });

    List<CsgRegion> regions = const [];
    String? failure;
    try {
      regions = await ref.read(erfPropertyRiverpod).searchRegions(query);
    } on CsgException catch (e) {
      failure = e.message;
    } catch (e) {
      failure = 'Suburb search failed: $e';
    }

    if (!mounted) return;
    setState(() {
      _isSearching = false;
      _regions = regions;
      _searchFailed = failure != null;
      _searchMessage = failure ??
          (regions.isEmpty
              ? 'No cadastral region matches "$query". Try the suburb name as '
                  'it appears on the title deed, or use "Around a place".'
              : null);
    });
  }

  Future<void> _usePlace() async {
    final place = _placeController.text.trim();
    if (place.isEmpty) return;

    setState(() {
      _isLocating = true;
      _placeMessage = null;
    });

    final point = await ref.read(erfPropertyRiverpod).geocode(place);

    if (!mounted) return;
    setState(() => _isLocating = false);

    if (point == null) {
      setState(() => _placeMessage = 'Could not find "$place".');
      return;
    }

    Navigator.pop(
      context,
      ErfDownloadRequest.forBounds(
        ErfBounds.aroundPoint(point, _radiusKm),
        '$place (${_radiusKm.toStringAsFixed(1)} km)',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Cap to the viewport so the dialog stays usable on a phone.
    final media = MediaQuery.of(context);
    final width = (media.size.width - 48).clamp(280.0, 460.0);
    final height = (media.size.height - 200).clamp(320.0, 470.0);

    return AlertDialog(
      title: const Text('Download ERF data'),
      insetPadding: const EdgeInsets.all(16),
      contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
      content: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.center,
              tabs: const [
                Tab(text: 'Map'),
                Tab(text: 'By name'),
                Tab(text: 'Around a place'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _buildMapTab(context),
                  _buildSuburbTab(context),
                  _buildPlaceTab(context),
                ],
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
      ],
    );
  }

  /// Visual picker — the recommended route, and the only one that scopes a
  /// Cape Town download to a single suburb.
  Widget _buildMapTab(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.map_outlined,
              size: 48, color: theme.colorScheme.primary),
          const SizedBox(height: 16),
          Text(
            'Pick a suburb on the map',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Suburb boundaries are drawn straight from the Surveyor-General '
            'register. Tap one to see how many parcels it holds, then '
            'download exactly those.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.secondaryContainer,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline,
                    size: 18, color: theme.colorScheme.onSecondaryContainer),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Best choice for Cape Town: the cadastral region there is '
                    'the whole metro (~120 000 parcels), so “By name” would '
                    'pull far more than one suburb.',
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () async {
              final selection = await Navigator.push<ErfTownshipSelection>(
                context,
                MaterialPageRoute(
                    builder: (_) => const ErfSuburbMapPicker()),
              );
              if (selection != null && context.mounted) {
                Navigator.pop(
                  context,
                  ErfDownloadRequest.forTownship(selection.township,
                      knownCount: selection.parcelCount),
                );
              }
            },
            icon: const Icon(Icons.map),
            label: const Text('Open the suburb map'),
          ),
        ],
      ),
    );
  }

  Widget _buildSuburbTab(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _suburbController,
            autofocus: true,
            textCapitalization: TextCapitalization.words,
            decoration: InputDecoration(
              labelText: 'Suburb name',
              hintText: 'e.g. Kensington, Mitchells Plain, Soweto',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
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
                      icon: const Icon(Icons.search),
                      onPressed: _runSearch,
                    ),
            ),
            onChanged: _onSuburbChanged,
            onSubmitted: (_) => _runSearch(),
          ),
          const SizedBox(height: 8),
          Text(
            _isSearching
                ? 'Searching the Surveyor-General register… this usually '
                    'takes 30-60 seconds.'
                : 'Downloads a whole cadastral region. Outside Gauteng a '
                    'region is often larger than one suburb — for Cape Town '
                    'use the Map tab. Press enter to search (30-60s).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_isSearching)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          const SizedBox(height: 8),
          if (_searchMessage != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Text(
                _searchMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: _searchFailed
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
              ),
            ),
          Expanded(
            child: ListView.builder(
              itemCount: _regions.length,
              itemBuilder: (context, index) {
                final region = _regions[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.location_city),
                  title: Text(region.minRegion),
                  subtitle: Text(
                    [
                      if (region.majRegion.isNotEmpty) region.majRegion,
                      if (region.province.isNotEmpty) region.province,
                      if (region.minCode.isNotEmpty) 'Code ${region.minCode}',
                    ].join(' · '),
                  ),
                  trailing: const Icon(Icons.download),
                  onTap: () => Navigator.pop(
                      context, ErfDownloadRequest.forRegion(region)),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceTab(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _placeController,
            decoration: InputDecoration(
              labelText: 'Address or landmark',
              hintText: 'e.g. 10 Voortrekker Road, Maitland',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onSubmitted: (_) => _usePlace(),
          ),
          const SizedBox(height: 20),
          Text('Radius: ${_radiusKm.toStringAsFixed(1)} km',
              style: Theme.of(context).textTheme.titleSmall),
          Slider(
            value: _radiusKm,
            min: 0.2,
            max: 5.0,
            divisions: 24,
            label: '${_radiusKm.toStringAsFixed(1)} km',
            onChanged: (v) => setState(() => _radiusKm = v),
          ),
          Text(
            'Pulls every parcel in a box around that point. A large radius '
            'over a dense suburb can run to tens of thousands of parcels, and '
            'the register answers slowly — start small.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (_placeMessage != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _placeMessage!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _isLocating ? null : _usePlace,
            icon: _isLocating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.download),
            label: const Text('Download this area'),
          ),
        ],
      ),
    );
  }
}
