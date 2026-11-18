import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;

final dayOffRiverpod = riverpod.ChangeNotifierProvider<DayOffProvider>(
  (ref) => DayOffProvider(),
);

/// Tracks which distributors have a day off on which dates.
///
/// Firestore structure: `distributorDaysOff/{distributorId}` → `{ dates: ["yyyy-MM-dd", ...] }`
/// One document per distributor, dates stored as an array of ISO date strings.
///
/// Marking or removing a day off shows at once: the change is kept here as
/// pending and laid over what the stream last delivered until the stream
/// shows it. It used to wait for Firestore to put the write in its local
/// cache (on the web that queues behind the browser database, which is
/// busy storing the schedule's large day documents) or, for a removal, for
/// the server — so the cell lagged a noticeable moment behind the click.
class DayOffProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore;
  static const String _collection = 'distributorDaysOff';

  /// distributorId → set of "yyyy-MM-dd" date strings, pending changes
  /// included.
  Map<String, Set<String>> _daysOff = {};

  /// What the stream last delivered.
  Map<String, Set<String>> _server = {};

  /// "distributorId|yyyy-MM-dd" → whether it is being marked (true) or
  /// removed (false), until the stream agrees or the write fails.
  final Map<String, bool> _pending = {};

  StreamSubscription<QuerySnapshot>? _subscription;

  DayOffProvider({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  void initialize() {
    _subscription = _firestore.collection(_collection).snapshots().listen(
      (snap) {
        _server = {
          for (final doc in snap.docs)
            doc.id: ((doc.data()['dates'] as List?)?.cast<String>() ?? [])
                .toSet(),
        };
        // Pending changes the stream now shows are done.
        _pending.removeWhere((key, on) {
          final (id, day) = _split(key);
          return (_server[id]?.contains(day) ?? false) == on;
        });
        _rebuild();
        notifyListeners();
      },
      onError: (e) => debugPrint('DayOffProvider: stream error: $e'),
    );
  }

  /// "yyyy-MM-dd". Built by hand: every grid cell asks [isDayOff] on each
  /// change, and DateFormat is slow for that many calls.
  static String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static (String, String) _split(String key) {
    final i = key.lastIndexOf('|');
    return (key.substring(0, i), key.substring(i + 1));
  }

  void _rebuild() {
    _daysOff = {for (final e in _server.entries) e.key: {...e.value}};
    _pending.forEach((key, on) {
      final (id, day) = _split(key);
      final days = _daysOff.putIfAbsent(id, () => <String>{});
      on ? days.add(day) : days.remove(day);
    });
  }

  bool isDayOff(String distributorId, DateTime date) =>
      _daysOff[distributorId]?.contains(_day(date)) ?? false;

  Future<void> markDayOff(String distributorId, DateTime date) =>
      _set(distributorId, date, true);

  Future<void> removeDayOff(String distributorId, DateTime date) =>
      _set(distributorId, date, false);

  /// Shows the change now, then saves it. A refused save puts the cell
  /// back and rethrows.
  Future<void> _set(String distributorId, DateTime date, bool on) async {
    final day = _day(date);
    final key = '$distributorId|$day';
    _pending[key] = on;
    _rebuild();
    notifyListeners();
    try {
      // Merge-set either way: works whether or not the distributor's doc
      // exists yet (update() failed on a missing doc), and marking or
      // removing twice is harmless.
      await _firestore.collection(_collection).doc(distributorId).set(
        {
          'dates': on
              ? FieldValue.arrayUnion([day])
              : FieldValue.arrayRemove([day]),
        },
        SetOptions(merge: true),
      );
      // Saved. The stream normally shows it within a moment; if it never
      // does (someone changed it straight back), stop masking it.
      Timer(const Duration(seconds: 8), () {
        if (!_disposed && _pending[key] == on) {
          _pending.remove(key);
          _rebuild();
          notifyListeners();
        }
      });
    } catch (e) {
      // Only undo our own change — a newer click on the same cell stands.
      if (!_disposed && _pending[key] == on) {
        _pending.remove(key);
        _rebuild();
        notifyListeners();
      }
      rethrow;
    }
  }

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    _subscription?.cancel();
    super.dispose();
  }
}
