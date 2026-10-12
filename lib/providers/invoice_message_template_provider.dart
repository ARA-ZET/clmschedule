import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/invoice_message_subject.dart';
import '../models/invoice_message_template.dart';
import '../services/reference_cache_service.dart';

const String _kCollectionName = 'invoiceMessageTemplates';
const String _kSettingsDocPath = 'settings/invoiceMessaging';

final invoiceMessageTemplateRiverpod =
    riverpod.ChangeNotifierProvider<InvoiceMessageTemplateProvider>(
        (ref) => InvoiceMessageTemplateProvider());

/// Message templates used when sharing an invoice, plus the banking details
/// block the `{banking_details}` token expands to.
///
/// Shared across all users, like the other user-configurable reference
/// collections (customInvoiceStatuses, customJobTypes) — the wording that goes
/// to customers should be consistent whoever sends it.
class InvoiceMessageTemplateProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  List<InvoiceMessageTemplate> _templates = [];
  String _bankingDetails = '';
  bool _isLoading = false;
  String? _error;

  List<InvoiceMessageTemplate> get templates => List.unmodifiable(_templates);
  String get bankingDetails => _bankingDetails;
  bool get isLoading => _isLoading;
  String? get error => _error;

  InvoiceMessageTemplateProvider() {
    load();
  }

  /// Templates offered for [invoice] — those tagged for its state plus any
  /// tagged "Any invoice", in display order.
  List<InvoiceMessageTemplate> templatesFor(InvoiceMessageSubject invoice) {
    final matching = _templates.where((t) => t.appliesTo(invoice)).toList();
    matching.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
    });
    return matching;
  }

  Future<void> load() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      _templates =
          await ReferenceCacheService.loadCollection<InvoiceMessageTemplate>(
        query: _firestore.collection(_kCollectionName).orderBy('order'),
        collectionName: _kCollectionName,
        fromDoc: (doc) {
          final data = Map<String, dynamic>.from(doc.data() as Map);
          data['id'] = doc.id;
          return InvoiceMessageTemplate.fromMap(data);
        },
      );

      final settings = await _firestore.doc(_kSettingsDocPath).get();
      _bankingDetails = settings.data()?['bankingDetails'] as String? ?? '';
    } catch (e) {
      _error = 'Error loading message templates: $e';
      if (kDebugMode) print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> addTemplate(InvoiceMessageTemplate template) async {
    try {
      _error = null;
      final docRef =
          await _firestore.collection(_kCollectionName).add(template.toMap());
      await ReferenceCacheService.bumpVersion(_kCollectionName);

      _templates = [..._templates, template.copyWith(id: docRef.id)];
      notifyListeners();
    } catch (e) {
      _error = 'Error adding template: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> updateTemplate(InvoiceMessageTemplate template) async {
    try {
      _error = null;
      await _firestore
          .collection(_kCollectionName)
          .doc(template.id)
          .update(template.toMap());
      await ReferenceCacheService.bumpVersion(_kCollectionName);

      final index = _templates.indexWhere((t) => t.id == template.id);
      if (index != -1) {
        _templates = [..._templates]..[index] = template;
      }
      notifyListeners();
    } catch (e) {
      _error = 'Error updating template: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> deleteTemplate(String id) async {
    try {
      _error = null;
      await _firestore.collection(_kCollectionName).doc(id).delete();
      await ReferenceCacheService.bumpVersion(_kCollectionName);

      _templates = _templates.where((t) => t.id != id).toList();
      notifyListeners();
    } catch (e) {
      _error = 'Error deleting template: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }

  /// The block `{banking_details}` expands to. Stored as free text rather than
  /// structured fields — bank, branch code and reference formats vary, and a
  /// wrong account number is worse than an ugly one.
  Future<void> setBankingDetails(String value) async {
    try {
      _error = null;
      await _firestore.doc(_kSettingsDocPath).set(
        {'bankingDetails': value},
        SetOptions(merge: true),
      );
      _bankingDetails = value;
      notifyListeners();
    } catch (e) {
      _error = 'Error saving banking details: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
