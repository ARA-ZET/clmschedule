import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/map_instruction.dart';
import '../services/reference_cache_service.dart';

const String _kCollectionName = 'mapInstructions';

final mapInstructionRiverpod =
    riverpod.ChangeNotifierProvider<MapInstructionProvider>(
        (ref) => MapInstructionProvider());

class MapInstructionProvider extends ChangeNotifier {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  List<MapInstruction> _instructions = [];
  bool _isLoading = false;
  String? _error;

  List<MapInstruction> get instructions => List.unmodifiable(_instructions);
  bool get isLoading => _isLoading;
  String? get error => _error;

  MapInstructionProvider() {
    loadInstructions();
  }

  Future<void> loadInstructions() async {
    try {
      _isLoading = true;
      _error = null;
      notifyListeners();

      _instructions =
          await ReferenceCacheService.loadCollection<MapInstruction>(
        query: _firestore.collection(_kCollectionName).orderBy('order'),
        collectionName: _kCollectionName,
        fromDoc: (doc) => MapInstruction.fromMap(
            doc.id, Map<String, dynamic>.from(doc.data() as Map)),
      );

      if (_instructions.isEmpty) {
        await _initializeDefaults();
      }
    } catch (e) {
      _error = 'Error loading map instructions: $e';
      if (kDebugMode) print(_error);
      _instructions = MapInstruction.getDefaults();
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  Future<void> _initializeDefaults() async {
    final defaults = MapInstruction.getDefaults();
    final batch = _firestore.batch();
    for (final instr in defaults) {
      batch.set(
          _firestore.collection(_kCollectionName).doc(instr.id), instr.toMap());
    }
    await batch.commit();
    await ReferenceCacheService.bumpVersion(_kCollectionName);
    _instructions = defaults;
  }

  Future<void> addInstruction(String text) async {
    final nextOrder = _instructions.isEmpty ? 0 : _instructions.last.order + 1;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final instr = MapInstruction(id: id, text: text.trim(), order: nextOrder);
    try {
      await _firestore.collection(_kCollectionName).doc(id).set(instr.toMap());
      await ReferenceCacheService.bumpVersion(_kCollectionName);
      _instructions.add(instr);
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('Error adding map instruction: $e');
      throw Exception('Failed to add map instruction');
    }
  }

  Future<void> updateInstruction(String id, String text) async {
    final index = _instructions.indexWhere((i) => i.id == id);
    if (index == -1) return;
    final updated = _instructions[index].copyWith(text: text.trim());
    try {
      await _firestore
          .collection(_kCollectionName)
          .doc(id)
          .update({'text': updated.text});
      await ReferenceCacheService.bumpVersion(_kCollectionName);
      _instructions[index] = updated;
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('Error updating map instruction: $e');
      throw Exception('Failed to update map instruction');
    }
  }

  Future<void> deleteInstruction(String id) async {
    try {
      await _firestore.collection(_kCollectionName).doc(id).delete();
      await ReferenceCacheService.bumpVersion(_kCollectionName);
      _instructions.removeWhere((i) => i.id == id);
      notifyListeners();
    } catch (e) {
      if (kDebugMode) print('Error deleting map instruction: $e');
      throw Exception('Failed to delete map instruction');
    }
  }
}
