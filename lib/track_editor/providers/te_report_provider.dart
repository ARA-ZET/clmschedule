// track_editor/providers/te_report_provider.dart
//
// State for Report mode: which folder was picked, the promoter days the
// scan found in it, which of those are selected for the PDF, and the proof
// photos attached to each date — the ones found in the folder beside the
// tracks plus any added by hand. Deliberately its own self-contained
// provider — Report mode does not touch the tab system (tracks/waypoints/
// polygons) that every other mode shares, so there is nothing to key by
// TEMode here. The Job List report page keeps an instance of its own.
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:image_picker/image_picker.dart';

import '../../models/distributor.dart';
import '../../services/storage_upload.dart';
import '../models/te_promoter_day.dart';
import '../services/te_folder_photos.dart';
import '../services/te_report_scanner.dart';
import 'package:firebase_storage/firebase_storage.dart';

final teReportRiverpod = riverpod.ChangeNotifierProvider<TEReportProvider>(
    (ref) => TEReportProvider());

enum TEReportScanStatus { idle, scanning, error, done }

class TEReportProvider extends ChangeNotifier {
  List<String> _folderPaths = const [];
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

  /// What the Generate button says while it works ("Finding intersections
  /// 12 of 40…"); null shows the plain "Building PDF…".
  String? _generateStatus;

  /// What the scan is on ("Loading photos 3 of 20…"); null before it knows.
  String? _scanStatus;

  /// Bumped by every scan, so an older one finishing late is ignored.
  int _scanToken = 0;

  /// Goes up with every change to what the PDF would show, so a page holding
  /// a built PDF can tell it is out of date.
  int _revision = 0;

  /// Proof photos per calendar date (midnight). A date's photos are shared by
  /// everyone who worked it, so they hang off the date, not a promoter day.
  final Map<DateTime, List<TEProofPhoto>> _photosByDate = {};

  /// Folder photos with no date, or dated on a day nobody in the report
  /// worked — left out of the PDF until put on a date.
  final List<TEProofPhoto> _undatedPhotos = [];

  /// Folder photos that would not download.
  List<String> _failedPhotos = const [];

  /// The photos going into the report, by Storage path. A folder can hold
  /// far more photos than the report wants, so a folder photo is only in it
  /// once chosen; one added by hand is chosen as it is added.
  final Set<String> _chosenPhotoPaths = {};

  /// Chosen photos added by hand that have no Storage path yet (still
  /// uploading, or the upload failed).
  final Set<TEProofPhoto> _chosenUnsaved = {};

  /// Folder photos put on a date by hand, by Storage path.
  final Map<String, DateTime> _photoDates = {};

  /// Unticked days a scan did not find (their folder was unticked) — kept
  /// so they stay unticked when they come back.
  Set<String> _absentUnselected = {};

  /// "Where worked" text typed in by hand, keyed by [TEPromoterDay.key] —
  /// kept here so regenerating the report doesn't lose the edits.
  final Map<String, String> _whereOverrides = {};

  /// Client map links typed or pasted in by hand, keyed by
  /// [TEPromoterDay.key]; '' means "no link" even when one was found.
  final Map<String, String> _mapLinkOverrides = {};

  bool get hasFolder => _folderPaths.isNotEmpty;
  String? get folderPath => hasFolder ? _folderPaths.join(', ') : null;
  List<String> get folderPaths => List.unmodifiable(_folderPaths);
  TEReportScanStatus get status => _status;
  String? get scanStatus => _scanStatus;
  int get revision => _revision;
  String? get errorMessage => _errorMessage;
  List<TEPromoterDay> get days => List.unmodifiable(_days);
  List<TEUnresolvedReportFile> get unresolved => List.unmodifiable(_unresolved);
  bool get fullReport => _fullReport;
  bool get isGenerating => _generating;
  String? get generateStatus => _generateStatus;

  /// Every photo found or added, by date — chosen or not.
  Map<DateTime, List<TEProofPhoto>> get photosByDate =>
      Map.unmodifiable(_photosByDate);

  /// The photos that go into the PDF, by date.
  Map<DateTime, List<TEProofPhoto>> get chosenPhotosByDate => {
        for (final MapEntry(key: date, value: list) in _photosByDate.entries)
          if (list.any(isChosen)) date: list.where(isChosen).toList(),
      };

  Map<String, String> get whereOverrides => Map.unmodifiable(_whereOverrides);

  Map<String, String> get mapLinkOverrides =>
      Map.unmodifiable(_mapLinkOverrides);

  List<TEProofPhoto> get undatedPhotos => List.unmodifiable(_undatedPhotos);
  List<String> get failedPhotos => List.unmodifiable(_failedPhotos);
  Set<String> get chosenPhotoPaths => Set.unmodifiable(_chosenPhotoPaths);
  Map<String, DateTime> get photoDates => Map.unmodifiable(_photoDates);

  bool isChosen(TEProofPhoto photo) => photo.storagePath != null
      ? _chosenPhotoPaths.contains(photo.storagePath)
      : _chosenUnsaved.contains(photo);

  /// Every photo going into the report.
  int get photoCount => _photosByDate.values
      .fold(0, (n, list) => n + list.where(isChosen).length);

  /// Every photo on a date, chosen or not.
  int get availablePhotoCount =>
      _photosByDate.values.fold(0, (n, list) => n + list.length);

  /// The size of the chosen photos as they will go into the PDF.
  int get chosenPhotoBytes => _photosByDate.values.fold(
      0,
      (n, list) =>
          n + list.where(isChosen).fold(0, (m, p) => m + p.bytes.length));

  /// Promoter days left out of the report, including ones a scan did not
  /// find this time.
  Set<String> get unselectedKeys => {
        ..._absentUnselected,
        if (!_fullReport)
          for (final d in _days)
            if (!_selectedKeys.contains(d.key)) d.key,
      };

  String? whereOverrideFor(TEPromoterDay day) => _whereOverrides[day.key];

  String? mapLinkOverrideFor(TEPromoterDay day) => _mapLinkOverrides[day.key];

  /// Every calendar date the scan found, oldest first.
  List<DateTime> get dates =>
      (_days.map((d) => _dateOnly(d.date)).toSet().toList()..sort());

  List<TEProofPhoto> photosFor(DateTime date) =>
      List.unmodifiable(_photosByDate[_dateOnly(date)] ?? const []);

  List<TEProofPhoto> chosenPhotosFor(DateTime date) =>
      photosFor(date).where(isChosen).toList();

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
  }) =>
      scanFolders([folderPath],
          distributors: distributors, onProgress: onProgress);

  /// Scans [folderPaths] for promoter days and photos. With [keepChoices]
  /// (the Job List page, rescanning after a folder was ticked or unticked,
  /// or restoring a draft) unticked days, chosen and re-dated photos and
  /// typed text carry over; otherwise it starts fresh.
  Future<void> scanFolders(
    List<String> folderPaths, {
    required List<Distributor> distributors,
    void Function(int done, int total)? onProgress,
    bool keepChoices = false,
  }) async {
    final token = ++_scanToken;
    final unselected = keepChoices ? unselectedKeys : <String>{};
    // Photos added by hand that haven't finished uploading aren't in the
    // folder yet, so the scan can't bring them back.
    final uploading = keepChoices
        ? [
            for (final MapEntry(key: date, value: list)
                in _photosByDate.entries)
              for (final p in list)
                if (p.storagePath == null) (date, p),
          ]
        : const <(DateTime, TEProofPhoto)>[];
    _folderPaths = [...folderPaths];
    _status = TEReportScanStatus.scanning;
    _scanStatus = null;
    _errorMessage = null;
    _days = [];
    _unresolved = [];
    _selectedKeys.clear();
    _fullReport = true;
    _absentUnselected = {};
    _photosByDate.clear();
    _undatedPhotos.clear();
    _failedPhotos = const [];
    if (!keepChoices) {
      _whereOverrides.clear();
      _mapLinkOverrides.clear();
      _chosenPhotoPaths.clear();
      _chosenUnsaved.clear();
      _photoDates.clear();
    }
    notifyListeners();

    try {
      final result = await scanFoldersForPromoterDays(
        folderPaths,
        distributors: distributors,
        onProgress: (done, total) {
          onProgress?.call(done, total);
          _setScanStatus('Reading tracks ${done < total ? done + 1 : done} '
              'of $total…');
        },
      );
      if (token != _scanToken) return;
      _days = result.promoterDays;
      _unresolved = result.unresolved;
      _applyUnselected(unselected);

      final photos = await loadFolderPhotos(
        result.photoPaths,
        dates: dates.toSet(),
        onProgress: (done, total) => _setScanStatus(
            'Loading photos ${done < total ? done + 1 : done} of $total…'),
      );
      if (token != _scanToken) return;
      _placeFolderPhotos(photos);
      for (final (date, p) in uploading) {
        (_photosByDate[date] ??= []).add(p);
      }
      _status = TEReportScanStatus.done;
    } catch (e) {
      if (token != _scanToken) return;
      _errorMessage = 'Could not scan that folder: $e';
      _status = TEReportScanStatus.error;
    }
    _scanStatus = null;
    _touch();
  }

  /// Sets the choices a saved draft made, before its first
  /// `scanFolders(keepChoices: true)` applies them.
  void restoreChoices({
    Set<String> unselected = const {},
    Map<String, String> where = const {},
    Map<String, String> links = const {},
    Set<String> chosenPhotos = const {},
    Map<String, DateTime> photoDates = const {},
  }) {
    _absentUnselected = {...unselected};
    _whereOverrides
      ..clear()
      ..addAll(where);
    _mapLinkOverrides
      ..clear()
      ..addAll(links);
    _chosenPhotoPaths
      ..clear()
      ..addAll(chosenPhotos);
    _photoDates
      ..clear()
      ..addAll(photoDates.map((k, v) => MapEntry(k, _dateOnly(v))));
  }

  void _applyUnselected(Set<String> unselected) {
    final present = {for (final d in _days) d.key};
    _absentUnselected = unselected.difference(present);
    final here = unselected.intersection(present);
    _selectedKeys.clear();
    if (here.isEmpty) {
      _fullReport = true;
    } else {
      _fullReport = false;
      _selectedKeys.addAll(present.difference(here));
    }
  }

  /// Files [photos] under their dates, a date picked by hand winning.
  void _placeFolderPhotos(TEFolderPhotos photos) {
    final days = dates.toSet();
    for (final p in [
      for (final list in photos.byDate.values) ...list,
      ...photos.undated,
    ]) {
      final picked = p.storagePath == null ? null : _photoDates[p.storagePath];
      if (picked != null && days.contains(picked)) {
        (_photosByDate[picked] ??= []).add(p);
      }
    }
    for (final MapEntry(key: date, value: list) in photos.byDate.entries) {
      for (final p in list) {
        if (_photoDates.containsKey(p.storagePath)) continue;
        (_photosByDate[date] ??= []).add(p);
      }
    }
    for (final p in photos.undated) {
      final picked = _photoDates[p.storagePath];
      if (picked != null && days.contains(picked)) continue;
      _undatedPhotos.add(p);
    }
    _failedPhotos = photos.failed;
  }

  void _setScanStatus(String status) {
    if (_scanStatus == status) return;
    _scanStatus = status;
    notifyListeners();
  }

  /// Notifies a change to what the PDF would show.
  void _touch() {
    _revision++;
    notifyListeners();
  }

  /// Sets [days] directly, bypassing the real Storage scan. The selection
  /// logic below (toggle/full-report/select-all-for-date) is
  /// ordinary state manipulation worth testing on its own, without needing
  /// Firebase in the test harness to get promoter days to test it against.
  @visibleForTesting
  void seedDaysForTest(List<TEPromoterDay> days) {
    _folderPaths = const ['test'];
    _days = days;
    _unresolved = [];
    _status = TEReportScanStatus.done;
    _selectedKeys.clear();
    _fullReport = true;
    _photosByDate.clear();
    _undatedPhotos.clear();
    _whereOverrides.clear();
    _mapLinkOverrides.clear();
    _touch();
  }

  /// What `scanFolders(keepChoices: true)` does once the folders are read,
  /// with [days] and [photos] standing in for Storage.
  @visibleForTesting
  void seedScanForTest(List<TEPromoterDay> days,
      [TEFolderPhotos photos = TEFolderPhotos.empty]) {
    final unselected = unselectedKeys;
    _folderPaths = const ['test'];
    _days = days;
    _unresolved = [];
    _applyUnselected(unselected);
    _photosByDate.clear();
    _undatedPhotos.clear();
    _placeFolderPhotos(photos);
    _status = TEReportScanStatus.done;
    _touch();
  }

  void clear() {
    _scanToken++;
    _folderPaths = const [];
    _status = TEReportScanStatus.idle;
    _errorMessage = null;
    _days = [];
    _unresolved = [];
    _selectedKeys.clear();
    _fullReport = true;
    _photosByDate.clear();
    _undatedPhotos.clear();
    _failedPhotos = const [];
    _chosenPhotoPaths.clear();
    _chosenUnsaved.clear();
    _photoDates.clear();
    _absentUnselected = {};
    _whereOverrides.clear();
    _mapLinkOverrides.clear();
    _touch();
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
    _touch();
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
    _touch();
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
    _touch();
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
    _touch();
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
    _chosenUnsaved.addAll(newPhotos);
    _touch();

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
        // It may have been moved to another date while it went up.
        final date = _photosByDate.keys.firstWhere(
            (d) => _photosByDate[d]!.any((p) => identical(p.bytes, photo.bytes)),
            orElse: () => key);
        final photos = [...?_photosByDate[date]];
        final pIdx = photos.indexWhere((p) => identical(p.bytes, photo.bytes));
        // Removed while it was uploading — nothing left to update.
        if (pIdx == -1) continue;
        final chosen = _chosenUnsaved.remove(photos[pIdx]);
        photos[pIdx] = photos[pIdx].copyWith(url: url, storagePath: ref.fullPath);
        _photosByDate[date] = photos;
        if (chosen) _chosenPhotoPaths.add(ref.fullPath);
        // Its name carries no date, so the next scan finds it by this.
        _photoDates[ref.fullPath] = date;
        notifyListeners();
      } catch (e) {
        debugPrint('attachPhotos: upload failed for ${photo.fileName}: $e');
        // The photo stays attached (with bytes, no url) — it still makes it
        // into the PDF even if the permanent copy failed to upload.
      }
    }
  }

  /// Puts [photo] in the report or takes it out. A photo with no date has
  /// to be put on one first ([assignPhoto]).
  void setPhotoChosen(TEProofPhoto photo, bool chosen) {
    if (chosen && _undatedPhotos.contains(photo)) return;
    if (!_setChosen(photo, chosen)) return;
    _touch();
  }

  /// Chooses or unchooses every photo on [date].
  void setChosenForDate(DateTime date, bool chosen) {
    var changed = false;
    for (final p in photosFor(date)) {
      changed |= _setChosen(p, chosen);
    }
    if (changed) _touch();
  }

  bool _setChosen(TEProofPhoto photo, bool chosen) {
    if (isChosen(photo) == chosen) return false;
    final path = photo.storagePath;
    if (path != null) {
      chosen ? _chosenPhotoPaths.add(path) : _chosenPhotoPaths.remove(path);
    } else {
      chosen ? _chosenUnsaved.add(photo) : _chosenUnsaved.remove(photo);
    }
    return true;
  }

  /// Moves [photo] onto [date] — an undated folder photo, or one filed
  /// under the wrong day — and chooses it, which is why it was moved.
  void assignPhoto(TEProofPhoto photo, DateTime date) {
    if (!_moveTo(photo, date)) return;
    _setChosen(photo, true);
    _touch();
  }

  /// What the photo chooser decided, in one change: [assigned] photos moved
  /// onto their dates, then exactly the [chosen] ones in the report.
  void applyPhotoChoices({
    Map<TEProofPhoto, DateTime> assigned = const {},
    required Set<TEProofPhoto> chosen,
  }) {
    var changed = false;
    for (final MapEntry(key: photo, value: date) in assigned.entries) {
      changed |= _moveTo(photo, date);
    }
    for (final list in _photosByDate.values) {
      for (final p in list) {
        changed |= _setChosen(p, chosen.contains(p));
      }
    }
    if (changed) _touch();
  }

  bool _moveTo(TEProofPhoto photo, DateTime date) {
    final key = _dateOnly(date);
    if (!_takeOut(photo)) return false;
    final list = _photosByDate[key] ??= [];
    list
      ..add(photo)
      ..sort((a, b) => (a.takenAt ?? DateTime(9999))
          .compareTo(b.takenAt ?? DateTime(9999)));
    if (photo.storagePath != null) _photoDates[photo.storagePath!] = key;
    return true;
  }

  /// Removes [photo] from wherever it is filed; false if it wasn't.
  bool _takeOut(TEProofPhoto photo) {
    if (_undatedPhotos.remove(photo)) return true;
    for (final MapEntry(key: date, value: list) in _photosByDate.entries) {
      if (!list.any((p) => identical(p, photo))) continue;
      final remaining = list.where((p) => !identical(p, photo)).toList();
      if (remaining.isEmpty) {
        _photosByDate.remove(date);
      } else {
        _photosByDate[date] = remaining;
      }
      return true;
    }
    return false;
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

  // ── Where worked ───────────────────────────────────────────────────────

  /// Sets the hand-typed "Where worked" text for [day]; null goes back to
  /// the looked-up names.
  void setWhereOverride(TEPromoterDay day, String? text) {
    if (text == null) {
      if (_whereOverrides.remove(day.key) == null) return;
    } else {
      if (_whereOverrides[day.key] == text) return;
      _whereOverrides[day.key] = text;
    }
    _touch();
  }

  /// Sets the hand-entered client map link for every one of [days]; null
  /// goes back to the link that was found.
  void setMapLinkOverride(Iterable<TEPromoterDay> days, String? url) {
    var changed = false;
    for (final d in days) {
      if (url == null) {
        changed |= _mapLinkOverrides.remove(d.key) != null;
      } else if (_mapLinkOverrides[d.key] != url) {
        _mapLinkOverrides[d.key] = url;
        changed = true;
      }
    }
    if (changed) _touch();
  }

  // ── Lifetime ───────────────────────────────────────────────────────────
  // A scan, photo upload or build can outlive the page that owns this.

  bool _disposed = false;

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _scanToken++;
    super.dispose();
  }

  // ── PDF generation state ───────────────────────────────────────────────
  // The actual PDF bytes are built by te_report_pdf.dart; this flag only
  // tracks whether that's in flight so the panel can show a spinner and
  // disable the button against a double-tap.

  void setGenerating(bool value) {
    if (_generating == value) return;
    _generating = value;
    _generateStatus = null;
    notifyListeners();
  }

  void setGenerateStatus(String? status) {
    if (_generateStatus == status) return;
    _generateStatus = status;
    notifyListeners();
  }
}
