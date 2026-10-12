import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_item.dart';
import '../services/zoho_books_service.dart';

/// Zoho Books' item catalogue, loaded once and held for the session.
///
/// The Zoho counterpart to `XeroItemsProvider`, and cached for the same reason:
/// it is consulted from a job-type settings dropdown, from every invoice line,
/// and again on each job type change. Fetching per consultation would put a
/// rate-limited call behind a dropdown that opens constantly.
class ZohoItemsProvider extends ChangeNotifier {
  ZohoItemsProvider(this._service);

  final ZohoBooksService _service;

  List<ZohoItem> _items = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;

  List<ZohoItem> get items => List.unmodifiable(_items);
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  String? get error => _error;

  /// The item with [itemId], or null.
  ///
  /// Keyed on Zoho's opaque `item_id`, not a code — Zoho has no equivalent of
  /// Xero's human-chosen `Code`, so this is what a job type stores.
  ZohoItem? byId(String itemId) {
    if (itemId.isEmpty) return null;
    for (final item in _items) {
      if (item.itemId == itemId) return item;
    }
    return null;
  }

  /// Load once. Repeat calls are free, so callers need not coordinate.
  Future<void> ensureLoaded() async {
    if (_hasLoaded || _isLoading) return;
    await _load();
  }

  Future<void> refresh() => _load();

  Future<void> _load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _items = await _service.listItems();
      _hasLoaded = true;
    } catch (e) {
      // Not fatal: invoicing still works with free-text lines, so a picker
      // explains itself rather than blocking the form.
      _error = '$e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

/// Keyed by Zoho organisation id — each organisation has its own catalogue.
final zohoItemsRiverpod =
    riverpod.ChangeNotifierProvider.family<ZohoItemsProvider, String>(
        (ref, orgId) {
  return ZohoItemsProvider(ref.read(zohoBooksServiceRiverpod(orgId)));
});
