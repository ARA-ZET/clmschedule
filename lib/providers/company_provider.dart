import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/company.dart';
import '../models/custom_job_type.dart';
import '../services/reference_cache_service.dart';

const String _kCollectionName = 'companies';

final companyRiverpod = riverpod.ChangeNotifierProvider<CompanyProvider>(
    (ref) => CompanyProvider());

/// The businesses whose work this app manages, and the accounting provider
/// each one invoices through.
///
/// Follows the same shape as the other user-configurable reference collections
/// (customJobTypes, customInvoiceStatuses): Firestore-backed, cached through
/// [ReferenceCacheService], shared by all users.
class CompanyProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  /// Static accessor, matching [JobTypeProvider.instance], so model-level
  /// helpers can resolve a company without plumbing a ref everywhere.
  static CompanyProvider? _instance;
  static CompanyProvider? get instance => _instance;

  List<Company> _companies = [];
  bool _isLoading = false;
  String? _error;

  List<Company> get companies => List.unmodifiable(_companies);
  List<Company> get activeCompanies =>
      _companies.where((c) => c.active).toList();
  bool get isLoading => _isLoading;
  String? get error => _error;

  CompanyProvider() {
    _instance = this;
    load();
  }

  Company? getById(String id) {
    for (final c in _companies) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The company owning [jobType], following its [CustomJobType.resolvedCompanyId]
  /// so job types not yet assigned by hand still resolve.
  Company? forJobType(CustomJobType jobType) =>
      getById(jobType.resolvedCompanyId);

  /// The accounting provider for a job type — the whole point of the company
  /// link. Returns [AccountingProvider.none] when the job type is marked as not
  /// invoiced, so callers need only check one thing.
  AccountingProvider providerForJobType(CustomJobType jobType) {
    if (!jobType.createsInvoices) return AccountingProvider.none;
    return forJobType(jobType)?.accountingProvider ?? AccountingProvider.none;
  }

  Future<void> load() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      _companies = await ReferenceCacheService.loadCollection<Company>(
        query: _firestore.collection(_kCollectionName).orderBy('order'),
        collectionName: _kCollectionName,
        fromDoc: (doc) {
          final data = Map<String, dynamic>.from(doc.data() as Map);
          data['id'] = doc.id;
          return Company.fromMap(data);
        },
      );

      // First run: seed the three businesses that exist today rather than
      // presenting an empty screen. Uses fixed ids so the seed is idempotent
      // and the job-type derivation can rely on them.
      if (_companies.isEmpty) await _seed();
    } catch (e) {
      _error = 'Error loading companies: $e';
      if (kDebugMode) print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _seed() async {
    final batch = _firestore.batch();
    for (final company in Company.seed) {
      batch.set(
        _firestore.collection(_kCollectionName).doc(company.id),
        company.toMap(),
        // Merge so a re-run cannot clobber edits made since.
        SetOptions(merge: true),
      );
    }
    await batch.commit();
    await ReferenceCacheService.bumpVersion(_kCollectionName);
    _companies = List.of(Company.seed);
    if (kDebugMode) print('Seeded ${_companies.length} companies');
  }

  Future<void> saveCompany(Company company) async {
    try {
      _error = null;
      if (company.id.isEmpty) {
        final ref =
            await _firestore.collection(_kCollectionName).add(company.toMap());
        _companies = [..._companies, company.copyWith(id: ref.id)];
      } else {
        await _firestore
            .collection(_kCollectionName)
            .doc(company.id)
            .set(company.toMap(), SetOptions(merge: true));
        final index = _companies.indexWhere((c) => c.id == company.id);
        if (index == -1) {
          _companies = [..._companies, company];
        } else {
          _companies = [..._companies]..[index] = company;
        }
      }
      _companies.sort((a, b) => a.order.compareTo(b.order));
      await ReferenceCacheService.bumpVersion(_kCollectionName);
      notifyListeners();
    } catch (e) {
      _error = 'Error saving company: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }

  /// Companies are deactivated rather than deleted — job types and historical
  /// jobs reference them by id, and a dangling reference would leave those
  /// records with no resolvable owner.
  Future<void> setActive(String id, bool active) async {
    final company = getById(id);
    if (company == null) return;
    await saveCompany(company.copyWith(active: active));
  }

  void clearError() {
    _error = null;
    notifyListeners();
  }
}
