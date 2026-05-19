import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:http/http.dart' as http;

final aiChatServiceRiverpod = riverpod.Provider<AiChatService>(
  (ref) => AiChatService(),
);

/// A single knowledge entry that teaches the AI about the system
class AiKnowledgeEntry {
  final String id;
  final String content;
  final String category; // 'correction', 'fact', 'preference', 'workflow'
  final String addedBy;
  final DateTime addedAt;

  AiKnowledgeEntry({
    required this.id,
    required this.content,
    required this.category,
    required this.addedBy,
    required this.addedAt,
  });

  factory AiKnowledgeEntry.fromMap(Map<String, dynamic> data) {
    return AiKnowledgeEntry(
      id: data['id'] as String? ?? '',
      content: data['content'] as String? ?? '',
      category: data['category'] as String? ?? 'fact',
      addedBy: data['addedBy'] as String? ?? '',
      addedAt: data['addedAt'] is Timestamp
          ? (data['addedAt'] as Timestamp).toDate()
          : DateTime.now(),
    );
  }

  Map<String, dynamic> toMap() => {
        'id': id,
        'content': content,
        'category': category,
        'addedBy': addedBy,
        'addedAt': Timestamp.fromDate(addedAt),
      };
}

/// Message model for AI chat conversations
class AiChatMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  final DateTime timestamp;
  final AiChatAction? action; // Optional action from the assistant

  AiChatMessage({
    required this.role,
    required this.content,
    DateTime? timestamp,
    this.action,
  }) : timestamp = timestamp ?? DateTime.now();

  Map<String, dynamic> toMap() => {
        'role': role,
        'content': content,
      };
}

/// Represents an action performed by the AI assistant (e.g., adding or updating a job)
class AiChatAction {
  final String
      type; // 'jobPendingConfirmation', 'jobAdded', 'jobCancelled', 'updatePendingConfirmation', 'jobUpdated', 'updateCancelled', 'multiJobPendingConfirmation', 'multiJobAdded', 'multiJobCancelled', 'schedulePendingConfirmation', 'scheduleJobsAdded', 'scheduleJobsCancelled'
  final String? jobId;
  final String? monthId;
  final Map<String, dynamic>?
      jobData; // Validated job data awaiting confirmation (add)
  final Map<String, dynamic>?
      updateData; // Validated update data awaiting confirmation (update)
  final List<Map<String, dynamic>>?
      jobsData; // Multiple validated jobs awaiting confirmation (bulk add)
  final List<Map<String, dynamic>>?
      scheduleJobsData; // Schedule grid jobs awaiting confirmation

  AiChatAction({
    required this.type,
    this.jobId,
    this.monthId,
    this.jobData,
    this.updateData,
    this.jobsData,
    this.scheduleJobsData,
  });

  factory AiChatAction.fromMap(Map<String, dynamic> data) {
    return AiChatAction(
      type: data['type'] as String? ?? '',
      jobId: data['jobId'] as String?,
      monthId: data['monthId'] as String?,
      jobData: data['jobData'] != null
          ? Map<String, dynamic>.from(data['jobData'] as Map)
          : null,
      updateData: data['updateData'] != null
          ? Map<String, dynamic>.from(data['updateData'] as Map)
          : null,
      jobsData: data['jobsData'] != null
          ? (data['jobsData'] as List)
              .map((j) => Map<String, dynamic>.from(j as Map))
              .toList()
          : null,
      scheduleJobsData: data['scheduleJobsData'] != null
          ? (data['scheduleJobsData'] as List)
              .map((j) => Map<String, dynamic>.from(j as Map))
              .toList()
          : null,
    );
  }
}

/// Response from the AI chat service
class AiChatResponse {
  final String text;
  final AiChatAction? action;

  AiChatResponse({required this.text, this.action});
}

/// A streaming event from the AI chat SSE endpoint
class AiStreamEvent {
  final String type; // 'text', 'status', 'done', 'error'
  final String? content;
  final AiChatAction? action;
  final String? monthId;

  AiStreamEvent({
    required this.type,
    this.content,
    this.action,
    this.monthId,
  });
}

/// Service for communicating with the Gemini-powered Cloud Function
class AiChatService {
  final FirebaseFunctions _functions;
  final FirebaseFirestore _firestore;

  // In-memory cache for system knowledge (loaded once per session)
  List<AiKnowledgeEntry>? _cachedKnowledge;

  AiChatService({
    FirebaseFunctions? functions,
    FirebaseFirestore? firestore,
  })  : _functions = functions ?? FirebaseFunctions.instance,
        _firestore = firestore ?? FirebaseFirestore.instance;

  /// Send a message and stream back AI responses via SSE.
  Stream<AiStreamEvent> sendMessageStream({
    required String message,
    required List<AiChatMessage> conversationHistory,
    required String userName,
    String? monthId,
  }) async* {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      yield AiStreamEvent(type: 'error', content: 'Not authenticated');
      return;
    }

    final idToken = await user.getIdToken();

    final trimmedHistory = conversationHistory.length > 10
        ? conversationHistory.sublist(conversationHistory.length - 10)
        : conversationHistory;

    final url = Uri.parse(
        'https://us-central1-clmschedule.cloudfunctions.net/chatWithAssistantStream');

    final request = http.Request('POST', url);
    request.headers['Content-Type'] = 'application/json';
    request.headers['Authorization'] = 'Bearer $idToken';
    request.body = jsonEncode({
      'message': message,
      'conversationHistory': trimmedHistory.map((m) => m.toMap()).toList(),
      'userName': userName,
      'monthId': monthId,
    });

    final client = http.Client();
    try {
      final response = await client.send(request).timeout(
            const Duration(seconds: 120),
          );

      if (response.statusCode != 200) {
        final body = await response.stream.bytesToString();
        yield AiStreamEvent(
            type: 'error',
            content: 'Server error: ${response.statusCode} - $body');
        return;
      }

      // Parse SSE events from the response stream
      String buffer = '';
      await for (final chunk in response.stream.transform(utf8.decoder)) {
        buffer += chunk;
        // SSE events are separated by double newlines
        while (buffer.contains('\n\n')) {
          final eventEnd = buffer.indexOf('\n\n');
          final eventStr = buffer.substring(0, eventEnd);
          buffer = buffer.substring(eventEnd + 2);

          for (final line in eventStr.split('\n')) {
            if (line.startsWith('data: ')) {
              final jsonStr = line.substring(6);
              try {
                final data = jsonDecode(jsonStr) as Map<String, dynamic>;
                final type = data['type'] as String? ?? '';

                AiChatAction? action;
                if (data['action'] != null) {
                  action = AiChatAction.fromMap(
                      Map<String, dynamic>.from(data['action'] as Map));
                }

                yield AiStreamEvent(
                  type: type,
                  content: data['content'] as String?,
                  action: action,
                  monthId: data['monthId'] as String?,
                );
              } catch (e) {
                debugPrint('Failed to parse SSE event: $e');
              }
            }
          }
        }
      }
    } catch (e) {
      yield AiStreamEvent(type: 'error', content: e.toString());
    } finally {
      client.close();
    }
  }

  /// Send a message to the AI assistant and get a response with optional action.
  Future<AiChatResponse> sendMessage({
    required String message,
    required List<AiChatMessage> conversationHistory,
    required String userName,
    String? monthId,
  }) async {
    // Knowledge is now loaded server-side with caching — no need to send from client

    final callable = _functions.httpsCallable(
      'chatWithAssistant',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );

    // Trim history client-side to last 10 messages (server also trims as safety net)
    final trimmedHistory = conversationHistory.length > 10
        ? conversationHistory.sublist(conversationHistory.length - 10)
        : conversationHistory;

    final result = await callable.call({
      'message': message,
      'conversationHistory': trimmedHistory.map((m) => m.toMap()).toList(),
      'userName': userName,
      'monthId': monthId,
    });

    final data = Map<String, dynamic>.from(result.data as Map);
    if (data['success'] == true) {
      AiChatAction? action;
      if (data['action'] != null) {
        action = AiChatAction.fromMap(
            Map<String, dynamic>.from(data['action'] as Map));
      }
      return AiChatResponse(
        text: data['response'] as String,
        action: action,
      );
    }
    throw Exception('Failed to get AI response');
  }

  /// Confirm and write a pending job to Firestore
  Future<Map<String, dynamic>> confirmAddJob({
    required Map<String, dynamic> jobData,
    required String userName,
  }) async {
    final callable = _functions.httpsCallable(
      'confirmAddJob',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );

    final result = await callable.call({
      'jobData': jobData,
      'userName': userName,
    });

    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Confirm and write multiple pending jobs to Firestore
  Future<Map<String, dynamic>> confirmAddMultipleJobs({
    required List<Map<String, dynamic>> jobsData,
    required String userName,
  }) async {
    final callable = _functions.httpsCallable(
      'confirmAddMultipleJobs',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );

    final result = await callable.call({
      'jobsData': jobsData,
      'userName': userName,
    });

    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Confirm and write pending schedule grid jobs to Firestore
  Future<Map<String, dynamic>> confirmAddScheduleJobs({
    required List<Map<String, dynamic>> scheduleJobsData,
    required String userName,
  }) async {
    final callable = _functions.httpsCallable(
      'confirmAddScheduleJobs',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 60)),
    );

    final result = await callable.call({
      'scheduleJobsData': scheduleJobsData,
      'userName': userName,
    });

    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Confirm and apply a pending job update to Firestore
  Future<Map<String, dynamic>> confirmUpdateJob({
    required Map<String, dynamic> updateData,
    required String userName,
  }) async {
    final callable = _functions.httpsCallable(
      'confirmUpdateJob',
      options: HttpsCallableOptions(timeout: const Duration(seconds: 30)),
    );

    final result = await callable.call({
      'updateData': updateData,
      'userName': userName,
    });

    return Map<String, dynamic>.from(result.data as Map);
  }

  /// Manually trigger a monthly summary rebuild for a specific month
  Future<void> rebuildMonthlySummary(String monthId) async {
    final callable = _functions.httpsCallable('rebuildMonthlySummary');
    await callable.call({'monthId': monthId});
  }

  /// Check if monthly summary exists for a given month
  Future<bool> hasMonthlySummary(String monthId) async {
    final doc =
        await _firestore.collection('monthSummaries').doc(monthId).get();
    return doc.exists;
  }

  // ─── System Knowledge Management ───

  /// Load all knowledge entries (cached in-memory after first load)
  Future<List<AiKnowledgeEntry>> getKnowledge() async {
    if (_cachedKnowledge != null) return _cachedKnowledge!;

    try {
      final doc =
          await _firestore.collection('aiConfig').doc('knowledge').get();
      if (doc.exists) {
        final entries = doc.data()?['entries'] as List<dynamic>? ?? [];
        _cachedKnowledge = entries
            .map((e) =>
                AiKnowledgeEntry.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList();
      } else {
        _cachedKnowledge = [];
      }
    } catch (e) {
      debugPrint('Failed to load AI knowledge: $e');
      _cachedKnowledge = [];
    }
    return _cachedKnowledge!;
  }

  /// Add a new knowledge entry
  Future<void> addKnowledge(AiKnowledgeEntry entry) async {
    final docRef = _firestore.collection('aiConfig').doc('knowledge');
    await docRef.set({
      'entries': FieldValue.arrayUnion([entry.toMap()]),
      'lastUpdated': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));

    // Update local cache
    _cachedKnowledge ??= [];
    _cachedKnowledge!.add(entry);
  }

  /// Remove a knowledge entry by id
  Future<void> removeKnowledge(String entryId) async {
    final knowledge = await getKnowledge();
    final entry = knowledge.where((e) => e.id == entryId).firstOrNull;
    if (entry == null) return;

    final docRef = _firestore.collection('aiConfig').doc('knowledge');
    await docRef.update({
      'entries': FieldValue.arrayRemove([entry.toMap()]),
      'lastUpdated': FieldValue.serverTimestamp(),
    });

    _cachedKnowledge?.removeWhere((e) => e.id == entryId);
  }

  /// Force refresh knowledge from Firestore
  void invalidateKnowledgeCache() {
    _cachedKnowledge = null;
  }
}
