import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/dropsheet_day.dart';

/// CRUD for `/dropsheet/daily/{YYYY-MM-DD}`.
///
/// Each day is one document holding an array of driver sections, each with
/// its own task list. Same daily-document pattern used by the schedule.
class DropsheetService {
  final FirebaseFirestore _firestore;

  DropsheetService({FirebaseFirestore? firestore})
      : _firestore = firestore ?? FirebaseFirestore.instance;

  CollectionReference<Map<String, dynamic>> get _dailyCol =>
      _firestore.collection('dropsheet').doc('daily').collection('days');

  Stream<DropsheetDay> streamDay(DateTime date) {
    final id = DropsheetDay.docIdFor(date);
    return _dailyCol.doc(id).snapshots().map((doc) {
      if (!doc.exists) return DropsheetDay(date: date);
      return DropsheetDay.fromMap(id, doc.data() ?? {});
    });
  }

  Future<DropsheetDay> getDay(DateTime date) async {
    final id = DropsheetDay.docIdFor(date);
    final doc = await _dailyCol.doc(id).get();
    if (!doc.exists) return DropsheetDay(date: date);
    return DropsheetDay.fromMap(id, doc.data() ?? {});
  }

  /// One-shot existence check for the day's document. Used to decide
  /// whether the provider should auto-seed from `/schedule/daily/{date}`.
  Future<bool> dayExists(DateTime date) async {
    final id = DropsheetDay.docIdFor(date);
    final doc = await _dailyCol.doc(id).get();
    return doc.exists;
  }

  Future<void> saveDay(DropsheetDay day) async {
    await _dailyCol.doc(day.docId).set(day.toMap(), SetOptions(merge: false));
  }
}
