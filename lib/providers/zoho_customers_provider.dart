import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_customer.dart';
import '../services/zoho_books_service.dart';

final zohoCustomersRiverpod =
    riverpod.ChangeNotifierProvider<ZohoCustomersProvider>(
  (ref) => ZohoCustomersProvider(service: ref.read(zohoBooksServiceRiverpod)),
);

/// Zoho Books customers.
///
/// Unlike most providers here, this does **not** load in its constructor —
/// every load is a billed Zoho API call against a rate-limited quota, so the
/// first fetch waits for [initialize] from the screen that needs it.
class ZohoCustomersProvider extends ChangeNotifier {
  final ZohoBooksService _service;

  List<ZohoCustomer> _customers = [];
  String _searchText = '';
  bool _isLoading = false;
  bool _isInitialized = false;
  String? _error;

  ZohoCustomersProvider({required ZohoBooksService service})
      : _service = service;

  List<ZohoCustomer> get customers => List.unmodifiable(_customers);
  String get searchText => _searchText;
  bool get isLoading => _isLoading;
  bool get isInitialized => _isInitialized;
  String? get error => _error;

  /// Customers filtered by [searchText]. Filtering is local so typing does not
  /// fire a request per keystroke.
  List<ZohoCustomer> get filteredCustomers {
    if (_searchText.isEmpty) return customers;
    final needle = _searchText.toLowerCase();
    return _customers
        .where((c) =>
            c.contactName.toLowerCase().contains(needle) ||
            c.companyName.toLowerCase().contains(needle) ||
            c.email.toLowerCase().contains(needle))
        .toList();
  }

  Future<void> initialize() async {
    if (_isInitialized) return;
    _isInitialized = true;
    await refresh();
  }

  Future<void> refresh() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      _customers = await _service.listCustomers(perPage: 200);
      _customers.sort((a, b) => a.displayName
          .toLowerCase()
          .compareTo(b.displayName.toLowerCase()));
    } on ZohoBooksException catch (e) {
      _error = e.isRateLimited
          ? 'Zoho rate limit reached — wait a moment and try again.'
          : 'Could not load customers: ${e.message}';
      if (kDebugMode) print(_error);
    } catch (e) {
      _error = 'Could not load customers: $e';
      if (kDebugMode) print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  void setSearchText(String value) {
    if (_searchText == value) return;
    _searchText = value;
    notifyListeners();
  }

  /// Create a customer in Zoho and merge it into local state.
  /// Rethrows so the calling form can surface the failure.
  Future<ZohoCustomer> createCustomer(ZohoCustomer customer) async {
    _error = null;
    try {
      final created = await _service.createCustomer(customer);
      _customers = [..._customers, created]
        ..sort((a, b) => a.displayName
            .toLowerCase()
            .compareTo(b.displayName.toLowerCase()));
      notifyListeners();
      return created;
    } catch (e) {
      _error = 'Could not create customer: $e';
      notifyListeners();
      rethrow;
    }
  }

  Future<ZohoCustomer> updateCustomer(ZohoCustomer customer) async {
    _error = null;
    try {
      final updated = await _service.updateCustomer(customer);
      final index =
          _customers.indexWhere((c) => c.contactId == updated.contactId);
      if (index != -1) {
        _customers = [..._customers]..[index] = updated;
      }
      notifyListeners();
      return updated;
    } catch (e) {
      _error = 'Could not update customer: $e';
      notifyListeners();
      rethrow;
    }
  }

  ZohoCustomer? getById(String contactId) {
    for (final c in _customers) {
      if (c.contactId == contactId) return c;
    }
    return null;
  }

  /// Best-effort match for a free-text client name from the Job List.
  /// Used to pre-select a customer when invoicing a scheduled job.
  ZohoCustomer? findByName(String name) {
    if (name.isEmpty) return null;
    final needle = name.trim().toLowerCase();
    for (final c in _customers) {
      if (c.contactName.toLowerCase() == needle ||
          c.companyName.toLowerCase() == needle) {
        return c;
      }
    }
    return null;
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
