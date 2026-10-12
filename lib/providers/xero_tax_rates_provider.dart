import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/xero_org.dart';
import '../services/xero_accounting_service.dart';

/// Xero's tax rates, loaded once and held for the session.
///
/// Needed because an invoice line stores a tax *type* — `OUTPUT3` — and nothing
/// about what that means. Showing the code to someone checking an invoice is
/// close to useless; showing "15%" is the thing they are actually looking for.
/// Only Xero knows the mapping, and it is organisation-specific: a South
/// African org has six different rates at 15%.
///
/// Cached for the same reason [XeroItemsProvider] is — this is consulted once
/// per invoice line, and the daily budget is 1,000 calls.
class XeroTaxRatesProvider extends ChangeNotifier {
  XeroTaxRatesProvider(this._service);

  final XeroAccountingService _service;

  List<XeroTaxRate> _rates = const [];
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;

  List<XeroTaxRate> get rates => List.unmodifiable(_rates);
  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  String? get error => _error;

  /// The rate for [taxType], or null when unknown — not yet loaded, or a code
  /// this organisation does not have. Callers fall back to showing the raw
  /// code, which is honest rather than inventing a percentage.
  XeroTaxRate? byType(String taxType) {
    if (taxType.isEmpty) return null;
    for (final rate in _rates) {
      if (rate.taxType == taxType) return rate;
    }
    return null;
  }

  /// The percentage for [taxType], or null when unknown.
  double? percentFor(String taxType) => byType(taxType)?.effectiveRate;

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
      _rates = await _service.listTaxRates();
      _hasLoaded = true;
    } on XeroException catch (e) {
      // Not fatal: without rates the editor shows tax codes instead of
      // percentages, which is worse but not wrong.
      _error = e.message;
    } catch (e) {
      _error = '$e';
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }
}

final xeroTaxRatesRiverpod =
    riverpod.ChangeNotifierProvider<XeroTaxRatesProvider>((ref) {
  return XeroTaxRatesProvider(ref.read(xeroAccountingServiceRiverpod));
});
