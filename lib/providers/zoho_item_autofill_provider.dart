import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_item_autofill.dart';
import '../services/reference_cache_service.dart';

const String _kCollectionName = 'zohoItemAutofills';

/// Per-item invoice line templates for Zoho Books.
///
/// Keyed by Zoho's `item_id`, which is also the Firestore document id — so
/// there is exactly one autofill per item and no way to create a duplicate.
///
/// Only items someone has actually configured are stored. An item with no
/// document behaves as it always did: the line takes Zoho's own name and
/// description.
class ZohoItemAutofillProvider extends ChangeNotifier {
  ZohoItemAutofillProvider(this._firestore);

  final FirebaseFirestore _firestore;

  Map<String, ZohoItemAutofill> _byItemId = {};
  bool _isLoading = false;
  bool _hasLoaded = false;
  String? _error;

  bool get isLoading => _isLoading;
  bool get hasLoaded => _hasLoaded;
  String? get error => _error;

  List<ZohoItemAutofill> get all => List.unmodifiable(_byItemId.values);

  /// The configured template for [itemId], or null when there is none.
  ZohoItemAutofill? forItem(String itemId) =>
      itemId.isEmpty ? null : _byItemId[itemId];

  Future<void> ensureLoaded() async {
    if (_hasLoaded || _isLoading) return;
    await load();
  }

  Future<void> load() async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final docs = await ReferenceCacheService.loadCollection<
          MapEntry<String, ZohoItemAutofill>>(
        query: _firestore.collection(_kCollectionName),
        collectionName: _kCollectionName,
        fromDoc: (doc) => MapEntry(
          doc.id,
          ZohoItemAutofill.fromMap(
              doc.id, Map<String, dynamic>.from(doc.data()! as Map)),
        ),
      );
      _byItemId = Map.fromEntries(docs);
      _hasLoaded = true;
    } catch (e) {
      _error = '$e';
      if (kDebugMode) debugPrint('ZohoItemAutofillProvider load failed: $e');
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Write, or delete when both templates are blank.
  ///
  /// Clearing both fields removes the document rather than storing an empty
  /// one, so "no autofill" has a single representation and the collection does
  /// not fill with placeholders for every item anyone ever opened.
  Future<void> save(ZohoItemAutofill autofill) async {
    final ref = _firestore.collection(_kCollectionName).doc(autofill.itemId);

    if (autofill.isEmpty) {
      await ref.delete();
      _byItemId.remove(autofill.itemId);
    } else {
      await ref.set(autofill.toMap());
      _byItemId[autofill.itemId] = autofill;
    }

    await ReferenceCacheService.bumpVersion(_kCollectionName);
    notifyListeners();
  }
}

final zohoItemAutofillRiverpod =
    riverpod.ChangeNotifierProvider<ZohoItemAutofillProvider>((ref) {
  return ZohoItemAutofillProvider(FirebaseFirestore.instance);
});
