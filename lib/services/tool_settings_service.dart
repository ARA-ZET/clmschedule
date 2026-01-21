import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/tool_settings.dart';

class ToolSettingsService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static const String _collectionPath = 'happy_sun_settings';
  static const String _documentId = 'tool_defaults';

  /// Get tool settings
  Future<ToolSettings> getToolSettings() async {
    try {
      final doc =
          await _firestore.collection(_collectionPath).doc(_documentId).get();

      if (doc.exists && doc.data() != null) {
        return ToolSettings.fromMap(doc.data()!);
      }
      return ToolSettings.empty();
    } catch (e) {
      print('Error getting tool settings: $e');
      return ToolSettings.empty();
    }
  }

  /// Save tool settings
  Future<void> saveToolSettings(ToolSettings settings) async {
    try {
      await _firestore
          .collection(_collectionPath)
          .doc(_documentId)
          .set(settings.toMap());
    } catch (e) {
      print('Error saving tool settings: $e');
      rethrow;
    }
  }

  /// Stream tool settings
  Stream<ToolSettings> streamToolSettings() {
    return _firestore
        .collection(_collectionPath)
        .doc(_documentId)
        .snapshots()
        .map((doc) {
      if (doc.exists && doc.data() != null) {
        return ToolSettings.fromMap(doc.data()!);
      }
      return ToolSettings.empty();
    });
  }
}
