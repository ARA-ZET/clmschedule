import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show EditableText, FocusManager;
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

final scheduleSelectionRiverpod =
    riverpod.ChangeNotifierProvider<ScheduleSelectionProvider>(
  (ref) => ScheduleSelectionProvider(),
);

/// Drag payload for several selected schedule jobs (by id), dropped on a
/// date header or cell to move them all at once.
class ScheduleJobsDrag {
  final List<String> jobIds;
  const ScheduleJobsDrag(this.jobIds);
}

/// Which schedule jobs are selected for a multi-job move.
///
/// Selecting is on while the "Select" toggle is set or while Ctrl / ⌘ /
/// Shift is held: a click on a job card then selects instead of opening the
/// card's own controls. A plain or Ctrl / ⌘ click toggles the clicked job;
/// a Shift-click selects every job between it and the last job clicked.
/// Escape clears the selection.
class ScheduleSelectionProvider extends ChangeNotifier {
  final Set<String> _ids = {};
  bool _selectMode = false;
  bool _modifierHeld = false;
  int _version = 0;

  ScheduleSelectionProvider() {
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  Set<String> get ids => Set.unmodifiable(_ids);
  int get count => _ids.length;
  bool contains(String id) => _ids.contains(id);
  bool get selectMode => _selectMode;

  /// Bumped whenever the set of selected jobs changes. A selected card
  /// watches it so its drag payload always carries the whole current
  /// selection, not the one from when the card was last built.
  int get version => _version;

  @override
  void notifyListeners() {
    _version++;
    super.notifyListeners();
  }

  /// Whether clicks on job cards select rather than act.
  bool get isSelecting => _selectMode || _modifierHeld;

  void setSelectMode(bool on) {
    if (_selectMode == on) return;
    _selectMode = on;
    if (!on) _clearAll();
    notifyListeners();
  }

  /// The grid cell of the last job clicked without Shift — one corner of
  /// the next Shift-click range.
  ({String distributorId, DateTime date})? _anchor;

  /// Jobs the last Shift-click range added, swapped out when Shift-clicking
  /// again from the same anchor (as in a spreadsheet).
  Set<String> _rangeIds = {};

  /// A plain or Ctrl / ⌘ click: toggles [id] and makes its cell the anchor
  /// for a following Shift-click.
  void toggle(String id, {String? distributorId, DateTime? date}) {
    if (!_ids.remove(id)) _ids.add(id);
    if (distributorId != null && date != null) {
      _anchor = (distributorId: distributorId, date: date);
    }
    _rangeIds = {};
    notifyListeners();
  }

  /// A Shift-click on the job at [distributorId] / [date]: selects every job
  /// in the rectangle between the anchor and this cell — the dates between
  /// them across the distributor rows between them, in [rowOrder] (the
  /// grid's row order). [jobsIn] lists a cell's job ids. Without an anchor
  /// it is a plain click.
  void selectRangeTo(
    String id, {
    required String distributorId,
    required DateTime date,
    required List<String> rowOrder,
    required Iterable<String> Function(String distributorId, DateTime date)
        jobsIn,
  }) {
    final anchor = _anchor;
    final fromRow =
        anchor == null ? -1 : rowOrder.indexOf(anchor.distributorId);
    final toRow = rowOrder.indexOf(distributorId);
    if (anchor == null || fromRow < 0 || toRow < 0) {
      toggle(id, distributorId: distributorId, date: date);
      return;
    }

    final range = <String>{};
    final rows = rowOrder.sublist(fromRow < toRow ? fromRow : toRow,
        (fromRow < toRow ? toRow : fromRow) + 1);
    var day = DateTime(anchor.date.year, anchor.date.month, anchor.date.day);
    var last = DateTime(date.year, date.month, date.day);
    if (last.isBefore(day)) (day, last) = (last, day);
    for (;
        !day.isAfter(last);
        day = DateTime(day.year, day.month, day.day + 1)) {
      for (final row in rows) {
        range.addAll(jobsIn(row, day));
      }
    }

    // Replace the previous Shift range from this anchor, keeping anything
    // picked one by one.
    _ids.removeAll(_rangeIds.difference(range));
    _rangeIds = range.difference(_ids);
    _ids.addAll(range);
    notifyListeners();
  }

  /// Selects all of [ids], or deselects them when all already are.
  void toggleAll(Iterable<String> ids) {
    final list = ids.toList();
    if (list.isEmpty) return;
    if (list.every(_ids.contains)) {
      _ids.removeAll(list);
    } else {
      _ids.addAll(list);
    }
    notifyListeners();
  }

  void clear() {
    if (_ids.isEmpty) return;
    _clearAll();
    notifyListeners();
  }

  void _clearAll() {
    _ids.clear();
    _anchor = null;
    _rangeIds = {};
  }

  /// Whether a text field has focus. Shift there is a capital letter, not a
  /// selection gesture — treating it as one flipped the grid into select mode
  /// while someone typed a client name, rebuilding the card behind the open
  /// dialog.
  static bool get _isTyping =>
      FocusManager.instance.primaryFocus?.context?.widget is EditableText;

  bool _onKey(KeyEvent event) {
    final kb = HardwareKeyboard.instance;
    final held = !_isTyping &&
        (kb.isControlPressed || kb.isMetaPressed || kb.isShiftPressed);
    if (held != _modifierHeld) {
      _modifierHeld = held;
      notifyListeners();
    }
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.escape &&
        (_ids.isNotEmpty || _selectMode)) {
      _clearAll();
      _selectMode = false;
      notifyListeners();
    }
    return false; // never swallow keys
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }
}
