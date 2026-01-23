import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import '../models/inventory_tool.dart';

class InventoryService {
  final FirebaseFirestore _firestore;
  FirebaseStorage get _storage => FirebaseStorage.instance;

  InventoryService(this._firestore);

  // Get all inventory tools
  Stream<List<InventoryTool>> getTools() {
    return _firestore
        .collection('inventoryTools')
        .orderBy('name')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => InventoryTool.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  // Get tools by category
  Stream<List<InventoryTool>> getToolsByCategory(String category) {
    return _firestore
        .collection('inventoryTools')
        .where('category', isEqualTo: category)
        .orderBy('name')
        .snapshots()
        .map((snapshot) {
      return snapshot.docs
          .map((doc) => InventoryTool.fromMap(doc.id, doc.data()))
          .toList();
    });
  }

  // Get tool by QR code
  Future<InventoryTool?> getToolByQrCode(String qrCode) async {
    final snapshot = await _firestore
        .collection('inventoryTools')
        .where('qrCode', isEqualTo: qrCode)
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return null;
    return InventoryTool.fromMap(
        snapshot.docs.first.id, snapshot.docs.first.data());
  }

  // Generate next tool ID number
  Future<int> _getNextToolNumber() async {
    final snapshot = await _firestore
        .collection('inventoryTools')
        .orderBy('toolId', descending: true)
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return 1;

    final lastToolId = snapshot.docs.first.data()['toolId'] as String;
    final match = RegExp(r'TOOL#(\d+)').firstMatch(lastToolId);
    if (match != null) {
      return int.parse(match.group(1)!) + 1;
    }
    return 1;
  }

  // Add new tools (creates multiple if quantity > 1)
  Future<List<String>> addTools(String name, String description,
      String? imageUrl, String category, int quantity,
      {ToolType toolType = ToolType.extras}) async {
    final List<String> toolIds = [];
    int startNumber = await _getNextToolNumber();

    for (int i = 0; i < quantity; i++) {
      final toolNumber = startNumber + i;
      final toolId = 'TOOL#${toolNumber.toString().padLeft(3, '0')}';
      final qrCode = toolId; // QR code is the same as tool ID

      final tool = InventoryTool(
        id: '', // Will be set by Firestore
        name: quantity > 1 ? '$name #${i + 1}' : name,
        description: description,
        imageUrl: imageUrl,
        category: category,
        toolId: toolId,
        qrCode: qrCode,
        createdAt: DateTime.now(),
        toolType: toolType,
      );

      final docRef =
          await _firestore.collection('inventoryTools').add(tool.toMap());
      toolIds.add(docRef.id);
    }

    return toolIds;
  }

  // Add new tools with image file (uploads once, reuses URL for all tools)
  Future<List<String>> addToolsWithImageFile(String name, String description,
      dynamic imageFile, String category, int quantity,
      {ToolType toolType = ToolType.extras}) async {
    final List<String> toolIds = [];
    int startNumber = await _getNextToolNumber();

    // Upload image once with the tool name (sanitized)
    String? imageUrl;

    try {
      imageUrl = await uploadToolImage(name, imageFile);
    } catch (e) {
      print('Error uploading image: $e');
      // Continue without image if upload fails
    }

    // Create all tools with the same image URL
    for (int i = 0; i < quantity; i++) {
      final toolNumber = startNumber + i;
      final toolId = 'TOOL#${toolNumber.toString().padLeft(3, '0')}';
      final qrCode = toolId;

      final tool = InventoryTool(
        id: '',
        name: quantity > 1 ? '$name #${i + 1}' : name,
        description: description,
        imageUrl: imageUrl,
        category: category,
        toolId: toolId,
        qrCode: qrCode,
        toolType: toolType,
        createdAt: DateTime.now(),
      );

      final docRef =
          await _firestore.collection('inventoryTools').add(tool.toMap());
      toolIds.add(docRef.id);
    }

    return toolIds;
  }

  // Update tool
  Future<void> updateTool(InventoryTool tool) async {
    await _firestore
        .collection('inventoryTools')
        .doc(tool.id)
        .update(tool.toMap());
  }

  // Update image URL for all tools with the same base name
  Future<void> updateImageForAllToolsWithSameName(
      String toolName, String imageUrl) async {
    // Get base name without #number suffix
    final baseName = toolName.replaceAll(RegExp(r'\s*#\d+$'), '');

    // Find all tools with names matching the base name (with or without #number)
    final snapshot = await _firestore.collection('inventoryTools').get();

    final batch = _firestore.batch();
    int updateCount = 0;

    for (var doc in snapshot.docs) {
      final data = doc.data();
      final name = data['name'] as String?;
      if (name != null) {
        // Remove #number suffix to compare base names
        final docBaseName = name.replaceAll(RegExp(r'\s*#\d+$'), '');
        if (docBaseName.toLowerCase() == baseName.toLowerCase()) {
          batch.update(doc.reference, {'imageUrl': imageUrl});
          updateCount++;
        }
      }
    }

    if (updateCount > 0) {
      await batch.commit();
    }
  }

  // Delete tool
  Future<void> deleteTool(String toolId) async {
    await _firestore.collection('inventoryTools').doc(toolId).delete();
  }

  // Assign tool to project
  Future<void> assignToolToProject(String toolId, String projectId) async {
    await _firestore.collection('inventoryTools').doc(toolId).update({
      'isInUse': true,
      'currentProject': projectId,
      'lastUsed': Timestamp.now(),
    });
  }

  // Return tool from project
  Future<void> returnToolFromProject(String toolId) async {
    await _firestore.collection('inventoryTools').doc(toolId).update({
      'isInUse': false,
      'currentProject': null,
    });
  }

  // Helper method to sanitize tool name for filename
  String _sanitizeFileName(String name) {
    // Remove #number suffix if present
    String cleanName = name.replaceAll(RegExp(r'\s*#\d+$'), '');
    // Convert to lowercase and replace spaces/special chars with underscore
    cleanName = cleanName
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_|_$'), '');
    return cleanName;
  }

  // Upload image to Firebase Storage (converted to PNG, named by tool name)
  Future<String?> uploadToolImage(String toolName, dynamic imageFile) async {
    try {
      String fileName = '${_sanitizeFileName(toolName)}.png';
      final storageRef = _storage.ref().child('inventory_tools/$fileName');

      if (kIsWeb) {
        final bytes = await imageFile.readAsBytes();
        final uploadTask = storageRef.putData(
          bytes,
          SettableMetadata(contentType: 'image/png'),
        );
        final snapshot = await uploadTask;
        final downloadUrl = await snapshot.ref.getDownloadURL();
        return downloadUrl;
      } else {
        final file = File(imageFile.path);
        final uploadTask = storageRef.putFile(
          file,
          SettableMetadata(contentType: 'image/png'),
        );
        final snapshot = await uploadTask;
        final downloadUrl = await snapshot.ref.getDownloadURL();
        return downloadUrl;
      }
    } catch (e) {
      return null;
    }
  }

  // Delete image from Firebase Storage
  Future<void> deleteToolImage(String imageUrl) async {
    try {
      // Validate URL format before attempting deletion
      if (imageUrl.isEmpty ||
          (!imageUrl.startsWith('gs://') && !imageUrl.startsWith('https://'))) {
        return;
      }

      final ref = _storage.refFromURL(imageUrl);
      await ref.delete();
    } catch (e) {
      // Deletion errors are non-fatal, continue silently
    }
  }

  // Check out tools (mark as in use for a project)
  Future<void> checkOutTools(List<String> toolIds, String projectId) async {
    final batch = _firestore.batch();

    for (final toolId in toolIds) {
      final docRef = _firestore.collection('inventoryTools').doc(toolId);
      batch.update(docRef, {
        'isInUse': true,
        'currentProject': projectId,
        'lastUsed': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }

  // Check in tools (mark as available)
  Future<void> checkInTools(List<String> toolIds) async {
    final batch = _firestore.batch();

    for (final toolId in toolIds) {
      final docRef = _firestore.collection('inventoryTools').doc(toolId);
      batch.update(docRef, {
        'isInUse': false,
        'currentProject': null,
        'lastUsed': FieldValue.serverTimestamp(),
      });
    }

    await batch.commit();
  }
}
