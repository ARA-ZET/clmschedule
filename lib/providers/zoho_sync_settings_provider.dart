import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

import '../models/zoho_invoice.dart';

const String _kDocPath = 'settings/zohoSync';

final zohoSyncSettingsRiverpod =
    riverpod.ChangeNotifierProvider<ZohoSyncSettingsProvider>(
        (ref) => ZohoSyncSettingsProvider());

/// Settings that tie Zoho invoices to Job List records.
///
/// Two jobs:
///  * which of your job statuses means "cancelled", so its invoice can be
///    voided rather than left live for work never done;
///  * how Zoho's fixed statuses map onto your own `customInvoiceStatuses`,
///    so the Job List's Invoice Status column follows Zoho.
class ZohoSyncSettingsProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  String _cancelledJobStatusId = '';
  String _noInvoiceStatusId = '';
  String _invoiceEnteredStatusId = '';
  Map<String, String> _invoiceStatusMap = {};
  bool _isLoading = false;
  String? _error;

  /// Invoice status for a job with no invoice at all — a new or copied job
  /// saved with Zoho invoicing off and no number typed.
  String get noInvoiceStatusId => _noInvoiceStatusId;

  /// Invoice status applied when an invoice number is first entered by hand,
  /// i.e. billed but not yet paid.
  String get invoiceEnteredStatusId => _invoiceEnteredStatusId;

  /// Job status id that means the job is cancelled. Empty = not configured,
  /// in which case only deleting a job offers to void its invoice.
  String get cancelledJobStatusId => _cancelledJobStatusId;

  /// Zoho status wire value → your `customInvoiceStatuses` document id.
  Map<String, String> get invoiceStatusMap =>
      Map.unmodifiable(_invoiceStatusMap);

  bool get isLoading => _isLoading;
  String? get error => _error;

  ZohoSyncSettingsProvider() {
    load();
  }

  /// Whether [jobStatusId] is the nominated cancelled status.
  bool isCancelledStatus(String jobStatusId) =>
      _cancelledJobStatusId.isNotEmpty && jobStatusId == _cancelledJobStatusId;

  /// Your invoice-status id for a Zoho status, or null when unmapped — in
  /// which case the caller leaves the Job List column alone rather than
  /// guessing.
  String? mappedInvoiceStatusId(ZohoInvoiceStatus status) {
    final id = _invoiceStatusMap[status.apiValue];
    return (id == null || id.isEmpty) ? null : id;
  }

  Future<void> load() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      final doc = await _firestore.doc(_kDocPath).get();
      final data = doc.data() ?? const <String, dynamic>{};
      _cancelledJobStatusId = data['cancelledJobStatusId'] as String? ?? '';
      _noInvoiceStatusId = data['noInvoiceStatusId'] as String? ?? '';
      _invoiceEnteredStatusId = data['invoiceEnteredStatusId'] as String? ?? '';
      _invoiceStatusMap = Map<String, String>.from(
        (data['invoiceStatusMap'] as Map?)?.map(
              (k, v) => MapEntry(k.toString(), (v ?? '').toString()),
            ) ??
            const {},
      );
    } catch (e) {
      _error = 'Error loading Zoho sync settings: $e';
      if (kDebugMode) print(_error);
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> setCancelledJobStatusId(String id) async {
    try {
      await _firestore.doc(_kDocPath).set(
        {'cancelledJobStatusId': id},
        SetOptions(merge: true),
      );
      _cancelledJobStatusId = id;
      notifyListeners();
    } catch (e) {
      _error = 'Error saving cancelled status: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }

  Future<void> setNoInvoiceStatusId(String id) =>
      _setField('noInvoiceStatusId', id, (v) => _noInvoiceStatusId = v);

  Future<void> setInvoiceEnteredStatusId(String id) => _setField(
      'invoiceEnteredStatusId', id, (v) => _invoiceEnteredStatusId = v);

  Future<void> _setField(
    String key,
    String value,
    void Function(String) assign,
  ) async {
    try {
      await _firestore
          .doc(_kDocPath)
          .set({key: value}, SetOptions(merge: true));
      assign(value);
      notifyListeners();
    } catch (e) {
      _error = 'Error saving $key: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }

  /// Map one Zoho status onto an invoice status. Passing an empty
  /// [invoiceStatusId] clears the mapping, leaving that Zoho status to not
  /// touch the Job List column.
  Future<void> setInvoiceStatusMapping(
    ZohoInvoiceStatus status,
    String invoiceStatusId,
  ) async {
    final updated = Map<String, String>.from(_invoiceStatusMap);
    if (invoiceStatusId.isEmpty) {
      updated.remove(status.apiValue);
    } else {
      updated[status.apiValue] = invoiceStatusId;
    }

    try {
      await _firestore.doc(_kDocPath).set(
        {'invoiceStatusMap': updated},
        SetOptions(merge: true),
      );
      _invoiceStatusMap = updated;
      notifyListeners();
    } catch (e) {
      _error = 'Error saving status mapping: $e';
      if (kDebugMode) print(_error);
      notifyListeners();
      rethrow;
    }
  }
}
