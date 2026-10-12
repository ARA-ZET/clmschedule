// track_editor/providers/te_report_provider.dart
//
// State for Report mode: which folder was picked, the promoter days the
// scan found in it, which of those are selected for the PDF, and the proof
// photos attached to each date. Deliberately its own self-contained provider —
// Report mode does not touch the tab system (tracks/waypoints/polygons) that
// every other mode shares, so there is nothing to key by TEMode here.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:image_picker/image_picker.dart';

import '../../models/distributor.dart';
import '../../services/storage_upload.dart';
import '../models/te_promoter_day.dart';
import '../services/te_report_scanner.dart';
import 'package:firebase_storage/firebase_storage.dart';

final teReportRiverpod = riverpod.ChangeNotifierProvider<TEReportProvider>(
    (ref) => TEReportProvider());

enum TEReportScanStatus { idle, scanning, error, done }

class TEReportProvider extends ChangeNotifier {
  String? _folderPath;
  TEReportScanStatus _status = TEReportScanStatus.idle;
  String? _errorMessage;
  List<TEPromoterDay> _days = [];
  List<TEUnresolvedReportFile> _unresolved = [];

  /// Keyed by [TEPromoterDay.key]. Empty + [fullReport] true means "every
  /// day found" without the UI having to keep every key in sync by hand as
  /// the scan result changes.
  final Set<String> _selectedKeys = {};
  bool _fullReport = true;

  bool _generating = false;

  /// Proof photos per calendar date (midnight). A date's photos are shared by
  /// everyone who worked it, so they hang off the date, not a promoter day.
  final Map<DateTime, List<TEProofPhoto>> _photosByDate = {};

  bool get hasFolder => _folderPath != null;
  String? get folderPath => _folderPath;
  TEReportScanStatus get status => _status;
  String? get errorMessage => _errorMessage;
  List<TEPromoterDay> get days => List.unmodifiable(_days);
  List<TEUnresolvedReportFile> get unresolved => List.unmodifiable(_unresolved);
  bool get fullReport => _fullReport;
  bool get isGenerating => _generating;

  Map<DateTime, List<TEProofPhoto>> get photosByDate =>
      Map.unmodifiable(_photosByDate);

  /// Every calendar date the scan found, oldest first.
  List<DateTime> get dates =>
      (_days.map((d) => _dateOnly(d.date)).toSet().toList()..sort());

  List<TEProofPhoto> photosFor(DateTime date) =>
      List.unmodifiable(_photosByDate[_dateOnly(date)] ?? const []);

  static DateTime _dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);

  /// The promoter days that would actually go into the PDF right now.
  List<TEPromoterDay> get selectedDays => _fullReport
      ? _days
      : _days.where((d) => _selectedKeys.contains(d.key)).toList();

  bool isSelected(TEPromoterDay day) =>
      _fullReport || _selectedKeys.contains(day.key);

  // ── Folder + scan ──────────────────────────────────────────────────────

  Future<void> scanFolder(
    String folderPath, {
    required List<Distributor> distributors,
    void Function(int done, int total)? onProgress,
  }) async {
    _folderPath = folderPath;
    _status = TEReportScanStatus.scanning;
    _errorMessage = null;
    _days = [];
    _unresolved = [];
    _selectedKeys.clear();
    _fullReport = true;
    _photosByDate.clear();
    notifyListeners();

    try {
      final result = await scanFolderForPromoterDays(
        folderPath,
        distributors: distributors,
        onProgress: onProgress,
      );
      _days = result.promoterDays;
      _unresolved = result.unresolved;
      _status = TEReportScanStatus.done;
    } catch (e) {
      _errorMessage = 'Could not scan that folder: $e';
      _status = TEReportScanStatus.error;
    }
    notifyListeners();
  }

  /// Sets [days] directly, bypassing the real Storage scan. The selection
  /// logic below (toggle/full-report/select-all-for-date) is
  /// ordinary state manipulation worth testing on its own, without needing
  /// Firebase in the test harness to get promoter days to test it against.
  @visibleForTesting
  void seedDaysForTest(List<TEPromoterDay> days) {
    _folderPath = 'test';
    _days = days;
    _unresolved = [];
    _status = TEReportScanStatus.done;
    _selectedKeys.clear();
    _fullReport = true;
    _photosByDate.clear();
    notifyListeners();
  }

  void clear() {
    _folderPath = null;
    _status = TEReportScanStatus.idle;
    _errorMessage = null;
    _days = [];
    _unresolved = [];
    _selectedKeys.clear();
    _fullReport = true;
    _photosByDate.clear();
    notifyListeners();
  }

  // ── Selection ──────────────────────────────────────────────────────────

  void setFullReport(bool value) {
    if (_fullReport == value) return;
    _fullReport = value;
    if (!value && _selectedKeys.isEmpty) {
      // Switching into "pick specific days" from "full report" with nothing
      // chosen yet would silently produce an empty PDF — start from
      // everything selected instead, so the toggle alone never loses data.
      _selectedKeys.addAll(_days.map((d) => d.key));
    }
    notifyListeners();
  }

  void toggleDay(TEPromoterDay day, bool selected) {
    if (_fullReport) {
      // The user is refining a subset starting from "everything" — seed the
      // full set once, then apply this one change, so unchecking one day
      // doesn't have to be typed as "everything except this one" by hand.
      _selectedKeys.addAll(_days.map((d) => d.key));
      _fullReport = false;
    }
    if (selected) {
      _selectedKeys.add(day.key);
    } else {
      _selectedKeys.remove(day.key);
    }
    notifyListeners();
  }

  /// Ticks or unticks every promoter day at once. Stays in "select days"
  /// mode either way, so deselecting everything leaves a blank slate to pick
  /// from rather than falling back to the full report.
  void selectAll(bool selected) {
    _fullReport = false;
    if (selected) {
      _selectedKeys.addAll(_days.map((d) => d.key));
    } else {
      _selectedKeys.clear();
    }
    notifyListeners();
  }

  /// Ticks or unticks every promoter's shift on [date] at once.
  void selectAllForDate(DateTime date, bool selected) {
    if (_fullReport) {
      _selectedKeys.addAll(_days.map((d) => d.key));
      _fullReport = false;
    }
    final key = _dateOnly(date);
    for (final d in _days.where((d) => _dateOnly(d.date) == key)) {
      if (selected) {
        _selectedKeys.add(d.key);
      } else {
        _selectedKeys.remove(d.key);
      }
    }
    notifyListeners();
  }

  // ── Proof photos ───────────────────────────────────────────────────────

  /// Opens the image picker and attaches whatever was chosen to [date],
  /// uploading each to Cloud Storage alongside that date's GPX files so the
  /// photos persist for a future re-generated report.
  Future<void> attachPhotos(DateTime date) async {
    final key = _dateOnly(date);
    final picked = await ImagePicker().pickMultiImage(
      maxWidth: 1600,
      maxHeight: 1600,
      imageQuality: 85,
    );
    if (picked.isEmpty) return;

    // Show the photos immediately (upload happens in the background) so the
    // panel doesn't sit blank while several images go up one at a time.
    final newPhotos = <TEProofPhoto>[];
    for (final x in picked) {
      newPhotos
          .add(TEProofPhoto(bytes: await x.readAsBytes(), fileName: x.name));
    }
    _photosByDate[key] = [...?_photosByDate[key], ...newPhotos];
    notifyListeners();

    final folder = _proofFolderFor(key);
    for (var i = 0; i < newPhotos.length; i++) {
      final photo = newPhotos[i];
      try {
        final ext = photo.fileName.contains('.')
            ? photo.fileName.split('.').last.toLowerCase()
            : 'jpg';
        final name = 'proof_${DateTime.now().millisecondsSinceEpoch}_$i.$ext';
        final ref = FirebaseStorage.instance.ref('$folder/$name');
        await StorageUpload.safePutData(
          ref,
          photo.bytes,
          metadata: SettableMetadata(
            contentType: ext == 'png' ? 'image/png' : 'image/jpeg',
          ),
        );
        final url = await ref.getDownloadURL();
        final photos = [...?_photosByDate[key]];
        final pIdx = photos.indexWhere((p) => identical(p.bytes, photo.bytes));
        // Removed while it was uploading — nothing left to update.
        if (pIdx == -1) continue;
        photos[pIdx] = photos[pIdx].copyWith(url: url);
        _photosByDate[key] = photos;
        notifyListeners();
      } catch (e) {
        debugPrint('attachPhotos: upload failed for ${photo.fileName}: $e');
        // The photo stays attached (with bytes, no url) — it still makes it
        // into the PDF even if the permanent copy failed to upload.
      }
    }
  }

  void removePhoto(DateTime date, TEProofPhoto photo) {
    final key = _dateOnly(date);
    final photos = _photosByDate[key];
    if (photos == null) return;
    final remaining = photos.where((p) => !identical(p, photo)).toList();
    if (remaining.isEmpty) {
      _photosByDate.remove(key);
    } else {
      _photosByDate[key] = remaining;
    }
    notifyListeners();
  }

  /// Folder a date's proof photos are uploaded to — alongside the GPX files
  /// of the first shift found on that date rather than a separate top-level
  /// tree, so deleting a distribution folder later takes its photos with it.
  String _proofFolderFor(DateTime date) {
    for (final day in _days) {
      if (_dateOnly(day.date) != date || day.sourcePaths.isEmpty) continue;
      final path = day.sourcePaths.first;
      final slash = path.lastIndexOf('/');
      final base = slash == -1 ? path : path.substring(0, slash);
      return '$base/proof';
    }
    // No source path on record for that date — fall back to a path keyed by
    // the date so its photos still land together.
    return 'Distribution/_proof/${date.year}-${date.month}-${date.day}';
  }

  // ── PDF generation state ───────────────────────────────────────────────
  // The actual PDF bytes are built by te_report_pdf.dart; this flag only
  // tracks whether that's in flight so the panel can show a spinner and
  // disable the button against a double-tap.

  void setGenerating(bool value) {
    if (_generating == value) return;
    _generating = value;
    notifyListeners();
  }
}
