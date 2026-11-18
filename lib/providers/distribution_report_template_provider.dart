import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/distribution_report_template.dart';
import '../services/reference_cache_service.dart';

const String _kCollectionName = 'distributionReportTemplates';

final distributionReportTemplateRiverpod =
    riverpod.ChangeNotifierProvider<DistributionReportTemplateProvider>(
        (ref) => DistributionReportTemplateProvider());

/// The report bodies sent to clients after a distribution.
///
/// Shared across all users, like the other user-configurable reference
/// collections — the wording that goes to customers should be consistent
/// whoever sends it.
class DistributionReportTemplateProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  List<DistributionReportTemplate> _templates = [];
  bool _isLoading = false;
  String? _error;

  List<DistributionReportTemplate> get templates =>
      List.unmodifiable(_templates);
  bool get isLoading => _isLoading;
  String? get error => _error;

  DistributionReportTemplateProvider() {
    load();
  }

  /// What the report dialog offers, in display order.
  ///
  /// Falls back to the built-in when Firestore holds nothing, so the feature
  /// works on a fresh deployment before anyone opens the template editor.
  /// Deliberately *not* seeded into Firestore on read — writing to the
  /// database as a side effect of opening a dialog would be surprising, and
  /// would resurrect the default every time someone deleted it.
  ///
  /// The Flyers & Posters and Flyer handout built-ins are always offered:
  /// unlike the standard body, nobody has a Firestore copy of them, and a
  /// saved doc with the same id replaces one.
  List<DistributionReportTemplate> get available {
    if (_templates.isEmpty) {
      return [...DistributionReportTemplate.builtIns];
    }
    final ids = _templates.map((t) => t.id).toSet();
    final sorted = [
      ..._templates,
      for (final t in DistributionReportTemplate.alwaysOffered)
        if (!ids.contains(t.id)) t,
    ];
    sorted.sort((a, b) {
      final byOrder = a.order.compareTo(b.order);
      return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
    });
    return sorted;
  }

  Future<void> load() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      _templates =
          await ReferenceCacheService.loadCollection<DistributionReportTemplate>(
        query: _firestore.collection(_kCollectionName).orderBy('order'),
        collectionName: _kCollectionName,
        fromDoc: (doc) {
          final data = Map<String, dynamic>.from(doc.data() as Map);
          data['id'] = doc.id;
          return DistributionReportTemplate.fromMap(data);
        },
      );
    } catch (e) {
      _error = 'Error loading report templates: $e';
      if (kDebugMode) print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> addTemplate(DistributionReportTemplate template) async {
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

  Future<void> updateTemplate(DistributionReportTemplate template) async {
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

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
