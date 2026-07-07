import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:intl/intl.dart';

final dayOffRiverpod = riverpod.ChangeNotifierProvider<DayOffProvider>(
  (ref) => DayOffProvider(),
);

/// Tracks which distributors have a day off on which dates.
///
/// Firestore structure: `distributorDaysOff/{distributorId}` → `{ dates: ["yyyy-MM-dd", ...] }`
/// One document per distributor, dates stored as an array of ISO date strings.
class DayOffProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore;
  static const String _collection = 'distributorDaysOff';
  static final DateFormat _fmt = DateFormat('yyyy-MM-dd');

  /// distributorId → set of "yyyy-MM-dd" date strings
  Map<String, Set<String>> _daysOff = {};
  StreamSubscription<QuerySnapshot>? _subscription;

  DayOffProvider({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  void initialize() {
    _subscription = _firestore.collection(_collection).snapshots().listen(
      (snap) {
        _daysOff = {
          for (final doc in snap.docs)
            doc.id: ((doc.data()['dates'] as List?)?.cast<String>() ?? [])
                .toSet(),
        };
        notifyListeners();
      },
      onError: (e) => debugPrint('DayOffProvider: stream error: $e'),
    );
  }

  bool isDayOff(String distributorId, DateTime date) =>
      _daysOff[distributorId]?.contains(_fmt.format(date)) ?? false;

  Future<void> markDayOff(String distributorId, DateTime date) async {
    await _firestore.collection(_collection).doc(distributorId).set(
      {'dates': FieldValue.arrayUnion([_fmt.format(date)])},
      SetOptions(merge: true),
    );
  }

  Future<void> removeDayOff(String distributorId, DateTime date) async {
    await _firestore.collection(_collection).doc(distributorId).update(
      {'dates': FieldValue.arrayRemove([_fmt.format(date)])},
    );
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
