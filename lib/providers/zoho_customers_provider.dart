import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_customer.dart';
import '../services/zoho_books_service.dart';

/// Keyed by Zoho organisation id, so Junk & Stuff's and Happy Sun's customer
/// books are loaded and held separately.
final zohoCustomersRiverpod =
    riverpod.ChangeNotifierProvider.family<ZohoCustomersProvider, String>(
  (ref, orgId) =>
      ZohoCustomersProvider(service: ref.read(zohoBooksServiceRiverpod(orgId))),
);

/// Sortable customer columns, in the same order as the table's columns so a
/// header index maps straight onto a value.
enum ZohoCustomerSort { name, company, email, phone, receivables }

/// Which customers to show. Zoho's own Contacts view hides inactive ones by
/// default; this defaults to all so nothing silently disappears.
enum ZohoCustomerFilter {
  all('All customers'),
  active('Active only'),
  inactive('Inactive only'),
  withBalance('With outstanding balance');

  const ZohoCustomerFilter(this.label);
  final String label;

  bool matches(ZohoCustomer c) {
    switch (this) {
      case all:
        return true;
      case active:
        return c.isActive;
      case inactive:
        return !c.isActive;
      case withBalance:
        return c.outstandingReceivable > 0;
    }
  }
}

/// Zoho Books customers.
///
/// Unlike most providers here, this does **not** load in its constructor —
/// every load is a billed Zoho API call against a rate-limited quota, so the
/// first fetch waits for [initialize] from the screen that needs it.
class ZohoCustomersProvider extends ChangeNotifier {
  final ZohoBooksService _service;

  List<ZohoCustomer> _customers = [];
  String _searchText = '';
  ZohoCustomerFilter _filter = ZohoCustomerFilter.all;
  ZohoCustomerSort _sortBy = ZohoCustomerSort.name;
  bool _sortAscending = true;
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

  ZohoCustomerFilter get filter => _filter;
  ZohoCustomerSort get sortBy => _sortBy;
  bool get sortAscending => _sortAscending;

  /// Customers after the filter, local text search and sort. Filtering is
  /// local so typing does not fire a request per keystroke — [refresh] loads
  /// every page precisely so this can see the whole book.
  List<ZohoCustomer> get filteredCustomers {
    var result = _customers.where(_filter.matches);

    if (_searchText.isNotEmpty) {
      final needle = _searchText.toLowerCase();
      result = result.where((c) =>
          c.contactName.toLowerCase().contains(needle) ||
          c.companyName.toLowerCase().contains(needle) ||
          c.firstName.toLowerCase().contains(needle) ||
          c.lastName.toLowerCase().contains(needle) ||
          c.email.toLowerCase().contains(needle) ||
          c.phone.contains(needle) ||
          c.mobile.contains(needle));
    }

    return result.toList()..sort(_compare);
  }

  int _compare(ZohoCustomer a, ZohoCustomer b) {
    int c;
    switch (_sortBy) {
      case ZohoCustomerSort.name:
        c = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
        break;
      case ZohoCustomerSort.company:
        c = a.companyName.toLowerCase().compareTo(b.companyName.toLowerCase());
        break;
      case ZohoCustomerSort.email:
        c = a.email.toLowerCase().compareTo(b.email.toLowerCase());
        break;
      case ZohoCustomerSort.phone:
        c = a.bestPhone.compareTo(b.bestPhone);
        break;
      case ZohoCustomerSort.receivables:
        c = a.outstandingReceivable.compareTo(b.outstandingReceivable);
        break;
    }
    return _sortAscending ? c : -c;
  }

  /// Sort by [field], toggling direction when it is already the sort field.
  void sortByField(ZohoCustomerSort field) {
    if (_sortBy == field) {
      _sortAscending = !_sortAscending;
    } else {
      _sortBy = field;
      // Money reads most usefully high-to-low first; names A-Z.
      _sortAscending = field != ZohoCustomerSort.receivables;
    }
    notifyListeners();
  }

  void setFilter(ZohoCustomerFilter value) {
    if (_filter == value) return;
    _filter = value;
    notifyListeners();
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
      // Every page, not just the first 200 — otherwise the local search below
      // can never find a customer past page one.
      // Ordering is applied by [filteredCustomers], which honours the chosen
      // sort column, so there is nothing to sort here.
      _customers = await _service.listAllCustomers();
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
      _customers = [..._customers, created];
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

  /// Fetch the full contact, including `contact_persons`. Required before an
  /// edit: the list response omits them, and updating without the primary
  /// `contact_person_id` makes Zoho append a duplicate contact person.
  Future<ZohoCustomer> loadFullCustomer(String contactId) async {
    final full = await _service.getCustomer(contactId);
    final index = _customers.indexWhere((c) => c.contactId == contactId);
    if (index != -1) {
      _customers = [..._customers]..[index] = full;
      notifyListeners();
    }
    return full;
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
