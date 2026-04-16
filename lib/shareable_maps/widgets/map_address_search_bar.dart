import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../providers/shareable_map_provider.dart';
import '../services/places_autocomplete_service.dart';
import '../models/map_point.dart';

/// Floating address search bar for the map editor.
/// Uses Google Places Autocomplete API with 5-second debounce,
/// biased to Cape Town, South Africa.
/// Selecting a suggestion adds a marker to the map.
class MapAddressSearchBar extends riverpod.ConsumerStatefulWidget {
  /// When true, the search field is always shown (no toggle FAB).
  final bool alwaysExpanded;

  /// Called when the user closes the search panel.
  final VoidCallback? onClose;

  const MapAddressSearchBar({
    super.key,
    this.alwaysExpanded = false,
    this.onClose,
  });

  @override
  riverpod.ConsumerState<MapAddressSearchBar> createState() =>
      _MapAddressSearchBarState();
}

class _MapAddressSearchBarState
    extends riverpod.ConsumerState<MapAddressSearchBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _service = PlacesAutocompleteService();

  Timer? _debounceTimer;
  List<PlaceSuggestion> _suggestions = [];
  bool _isLoading = false;
  bool _isExpanded = false;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _closeSearch() {
    _controller.clear();
    _debounceTimer?.cancel();
    setState(() {
      _suggestions = [];
      _isExpanded = false;
      _isLoading = false;
    });
    _focusNode.unfocus();
    widget.onClose?.call();
  }

  void _onTextChanged(String value) {
    _debounceTimer?.cancel();

    if (value.trim().isEmpty) {
      setState(() {
        _suggestions = [];
        _isLoading = false;
      });
      return;
    }

    setState(() => _isLoading = true);

    _debounceTimer = Timer(const Duration(seconds: 5), () async {
      if (!mounted) return;
      final results = await _service.getSuggestions(value.trim());
      if (mounted) {
        setState(() {
          _suggestions = results;
          _isLoading = false;
        });
      }
    });
  }

  Future<void> _onSuggestionTap(PlaceSuggestion suggestion) async {
    final provider = ref.read(shareableMapRiverpod);

    setState(() => _isLoading = true);

    final latLng = await _service.getPlaceDetails(suggestion.placeId);

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (latLng == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not get location for this address'),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    // Add as a marker/point to the selected layer
    final layer = provider.selectedLayer;
    if (layer == null) return;

    final point = MapPoint.create(
      name: suggestion.mainText,
      description: suggestion.secondaryText,
      position: latLng,
      color: layer.defaultColor,
    );

    provider.addPointToSelectedLayer(point);

    // Animate camera to the new point
    provider.animateToPosition(latLng, zoom: 16.0);

    // Clear search
    _controller.clear();
    setState(() {
      _suggestions = [];
    });
    _focusNode.unfocus();
    widget.onClose?.call();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(Icons.place, color: Colors.white),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Added: ${suggestion.mainText}'),
              ),
            ],
          ),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVisible = widget.alwaysExpanded || _isExpanded;

    if (!isVisible) {
      return FloatingActionButton.small(
        heroTag: 'address_search',
        backgroundColor: Colors.white,
        onPressed: () => setState(() => _isExpanded = true),
        tooltip: 'Search address',
        child: const Icon(Icons.search, color: Color(0xFF5F6368)),
      );
    }

    return Material(
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        width: 320,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Search field
            TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search address in Cape Town...',
                hintStyle:
                    const TextStyle(color: Color(0xFF9AA0A6), fontSize: 13),
                prefixIcon: const Icon(Icons.search,
                    size: 20, color: Color(0xFF9AA0A6)),
                suffixIcon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_isLoading)
                      const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    IconButton(
                      icon: const Icon(Icons.close,
                          size: 18, color: Color(0xFF5F6368)),
                      onPressed: _closeSearch,
                    ),
                  ],
                ),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: _onTextChanged,
            ),
            // Suggestions list
            if (_suggestions.isNotEmpty) ...[
              const Divider(height: 1),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView.builder(
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: _suggestions.length,
                  itemBuilder: (context, index) {
                    final s = _suggestions[index];
                    return ListTile(
                      dense: true,
                      leading: const Icon(Icons.place,
                          size: 20, color: Color(0xFF5F6368)),
                      title: Text(
                        s.mainText,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        s.secondaryText,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF9AA0A6),
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => _onSuggestionTap(s),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
