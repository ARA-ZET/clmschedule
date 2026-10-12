import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/xero_org.dart';
import '../services/xero_accounting_service.dart';

/// Xero's Products & Services catalogue, loaded once and held for the session.
///
/// The caching is the point. This list is consulted from a job-type settings
/// dropdown, from every line of the invoice editor, and again whenever the job
/// type changes on the Add Job form — a fetch per consultation would burn the
/// 1,000-call daily budget on a screen nobody thinks of as expensive.
///
/// The catalogue changes rarely (it is a price list), so a session-long cache
/// is the right trade. [refresh] is there for when someone has just added an
/// item in Xero and wants to see it without reloading the app.
class XeroItemsProvider extends ChangeNotifier {
  XeroItemsProvider(this._service);

  final XeroAccountingService _service;

  List<XeroItem> _items = const [];
  bool _isLoading = false;
  String? _error;
  bool _hasLoaded = false;

  List<XeroItem> get items => List.unmodifiable(_items);
  bool get isLoading => _isLoading;
  String? get error => _error;
  bool get hasLoaded => _hasLoaded;

  /// The item with [code], or null. Used to resolve a job type's stored
  /// `accountingItemCode` back to something with a price on it.
  XeroItem? byCode(String code) {
    if (code.isEmpty) return null;
    for (final item in _items) {
      if (item.code == code) return item;
    }
    return null;
  }

  /// Load once. Repeat calls are free — which is what lets callers invoke this
  /// from `initState` without coordinating with each other.
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
    } on XeroException catch (e) {
      // A missing catalogue is not a failure state for the caller: invoicing
      // still works with free-text lines. The error is surfaced so a picker can
      // explain itself, but nothing blocks on it.
      _error = e.message;
    } catch (e) {
      _error = '$e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

final xeroItemsRiverpod =
    riverpod.ChangeNotifierProvider<XeroItemsProvider>((ref) {
  return XeroItemsProvider(ref.read(xeroAccountingServiceRiverpod));
});
