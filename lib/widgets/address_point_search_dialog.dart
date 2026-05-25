import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../models/custom_polygon.dart';
import '../shareable_maps/services/places_autocomplete_service.dart';

/// Result returned by [AddressPointSearchDialog] when the user confirms.
class AddressPointResult {
  final String address;
  final LatLng position;
  final PointCategory category;

  const AddressPointResult({
    required this.address,
    required this.position,
    required this.category,
  });

  /// Creates a [CustomPolygon] point from this result.
  CustomPolygon toCustomPolygon() {
    return CustomPolygon(
      name: address,
      description: '',
      points: [position],
      color: category.color,
      type: MapElementType.point,
      pointCategory: category,
    );
  }
}

/// A dialog that lets the user search for an address using the Google Places
/// API and confirm it as a map point to be saved with the job.
///
/// Returns an [AddressPointResult] if the user confirms, or `null` if they skip.
class AddressPointSearchDialog extends StatefulWidget {
  /// Pre-filled search text (e.g. the job's collection address).
  final String initialAddress;

  /// Label shown in the dialog title (e.g. "Collection Address").
  final String label;

  /// Category for the resulting point (determines icon colour).
  final PointCategory category;

  const AddressPointSearchDialog({
    super.key,
    required this.initialAddress,
    this.label = 'Job Address',
    this.category = PointCategory.pickup,
  });

  @override
  State<AddressPointSearchDialog> createState() =>
      _AddressPointSearchDialogState();
}

class _AddressPointSearchDialogState extends State<AddressPointSearchDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  final PlacesAutocompleteService _service = PlacesAutocompleteService();

  Timer? _debounce;
  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;
  LatLng? _selectedLatLng;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialAddress);
    _focusNode = FocusNode();

    // Auto-search the initial address if provided
    if (widget.initialAddress.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _onTextChanged(widget.initialAddress);
      });
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onTextChanged(String value) {
    _debounce?.cancel();
    setState(() {
      _selectedLatLng = null;
    });
    if (value.trim().isEmpty) {
      setState(() => _suggestions = []);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 500), () async {
      if (!mounted) return;
      setState(() => _loading = true);
      final results = await _service.getSuggestions(value);
      if (!mounted) return;
      setState(() {
        _suggestions = results;
        _loading = false;
      });
    });
  }

  Future<void> _onSuggestionTap(PlaceSuggestion suggestion) async {
    setState(() {
      _loading = true;
      _suggestions = [];
      _controller.text = suggestion.description;
    });
    final latLng = await _service.getPlaceDetails(suggestion.placeId);
    if (!mounted) return;
    setState(() {
      _selectedLatLng = latLng;
      _loading = false;
    });
  }

  void _confirm() {
    if (_selectedLatLng == null) return;
    Navigator.of(context).pop(AddressPointResult(
      address: _controller.text.trim(),
      position: _selectedLatLng!,
      category: widget.category,
    ));
  }

  void _skip() => Navigator.of(context).pop(null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Title
              Row(
                children: [
                  Icon(widget.category.icon,
                      color: widget.category.color, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Add Address Point – ${widget.label}',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Search for the address to pin it on the schedule map.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              ),
              const SizedBox(height: 16),

              // Search field
              TextField(
                controller: _controller,
                focusNode: _focusNode,
                decoration: InputDecoration(
                  labelText: 'Search address',
                  hintText: 'Type to search…',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: _loading
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : _controller.text.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _controller.clear();
                                setState(() {
                                  _suggestions = [];
                                  _selectedLatLng = null;
                                });
                              },
                            )
                          : null,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: _onTextChanged,
                autofocus: true,
              ),

              // Suggestions list
              if (_suggestions.isNotEmpty)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 200),
                  child: Card(
                    margin: const EdgeInsets.only(top: 4),
                    elevation: 4,
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: _suggestions.length,
                      separatorBuilder: (_, __) => const Divider(height: 0),
                      itemBuilder: (context, i) {
                        final s = _suggestions[i];
                        return ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.location_on_outlined, size: 18),
                          title: Text(s.mainText,
                              style:
                                  const TextStyle(fontWeight: FontWeight.w500)),
                          subtitle: Text(s.secondaryText,
                              style: const TextStyle(fontSize: 11)),
                          onTap: () => _onSuggestionTap(s),
                        );
                      },
                    ),
                  ),
                ),

              // Selected confirmation chip
              if (_selectedLatLng != null) ...[
                const SizedBox(height: 12),
                Chip(
                  avatar: Icon(Icons.check_circle,
                      color: widget.category.color, size: 16),
                  label: Text(
                    'Point resolved  (${_selectedLatLng!.latitude.toStringAsFixed(4)}, '
                    '${_selectedLatLng!.longitude.toStringAsFixed(4)})',
                    style: const TextStyle(fontSize: 11),
                  ),
                  backgroundColor: widget.category.color.withValues(alpha: 0.1),
                ),
              ],

              const SizedBox(height: 20),

              // Action buttons
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _skip,
                    child: const Text('Skip'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _selectedLatLng != null ? _confirm : null,
                    icon: const Icon(Icons.add_location_alt, size: 16),
                    label: const Text('Add Point'),
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
