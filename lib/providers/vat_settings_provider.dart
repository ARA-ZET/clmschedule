import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

final vatSettingsRiverpod =
    riverpod.ChangeNotifierProvider<VatSettingsProvider>(
        (ref) => VatSettingsProvider());

class VatSettingsProvider extends ChangeNotifier {
  static const _docPath = 'settings/vatSettings';

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  double _vatPercentage = 15.0;
  bool _isLoading = false;
  String? _error;

  double get vatPercentage => _vatPercentage;
  bool get isLoading => _isLoading;
  String? get error => _error;

  VatSettingsProvider() {
    _load();
  }

  Future<void> _load() async {
    try {
      _isLoading = true;
      notifyListeners();
      final doc = await _firestore.doc(_docPath).get();
      if (doc.exists) {
        final data = doc.data();
        _vatPercentage =
            (data?['vatPercentage'] as num?)?.toDouble() ?? 15.0;
      }
    } catch (e) {
      _error = 'Failed to load VAT settings: $e';
      if (kDebugMode) print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> updateVatPercentage(double percentage) async {
    try {
      _error = null;
      await _firestore.doc(_docPath).set(
        {'vatPercentage': percentage},
        SetOptions(merge: true),
      );
      _vatPercentage = percentage;
      notifyListeners();
    } catch (e) {
      _error = 'Failed to save VAT settings: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
    }
  }

  /// Compute incl-VAT from an excl-VAT amount.
  double inclFromExcl(double exclAmount) =>
      exclAmount * (1 + _vatPercentage / 100);

  /// Compute excl-VAT from an incl-VAT amount.
  double exclFromIncl(double inclAmount) =>
      inclAmount / (1 + _vatPercentage / 100);
}
