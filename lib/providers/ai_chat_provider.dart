import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../services/ai_chat_service.dart';

final aiChatRiverpod = riverpod.ChangeNotifierProvider<AiChatProvider>(
  (ref) => AiChatProvider(ref.read(aiChatServiceRiverpod)),
);

/// Callback type for when the AI performs an action (e.g., adds a job)
typedef AiActionCallback = void Function(AiChatAction action);

/// Provider for managing AI assistant chat state
class AiChatProvider extends ChangeNotifier {
  final AiChatService _aiChatService;

  final List<AiChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isStreaming = false;
  String? _error;
  String _userName = 'User';
  String? _currentMonthId;
  DateTime? _lastDataRefresh;
  AiActionCallback? onAction;
  StreamSubscription<AiStreamEvent>? _streamSubscription;

  AiChatProvider(this._aiChatService);

  List<AiChatMessage> get messages => List.unmodifiable(_messages);
  bool get isLoading => _isLoading;
  bool get isStreaming => _isStreaming;
  String? get error => _error;
  String get userName => _userName;
  String? get currentMonthId => _currentMonthId;
  DateTime? get lastDataRefresh => _lastDataRefresh;

  /// Initialize with user name for personalized greeting
  void initialize(String userName) {
    _userName = userName;
    if (_messages.isEmpty) {
      // Add welcome message
      _messages.add(AiChatMessage(
        role: 'assistant',
        content:
            'Hello $_userName! \u{1F44B} I\'m Pelisa, your CLM assistant. I can help you with:\n\n'
            '• Finding jobs by client, area, or date\n'
            '• Checking job statuses and invoice details\n'
            '• Summarizing daily or monthly schedules\n'
            '• **Adding new jobs** to the Job List\n'
            '• **Updating existing jobs** on the Job List\n'
            '• Calculating totals for amounts or quantities\n\n'
            'What would you like to know?',
      ));
      notifyListeners();
    }
  }

  /// Update the current month context from schedule/job list providers
  void updateDataContext({required String monthId}) {
    _currentMonthId = monthId;
    _lastDataRefresh = DateTime.now();
    notifyListeners();
  }

  /// Send a message and stream AI response
  Future<void> sendMessage(String message) async {
    if (message.trim().isEmpty) return;

    // Add user message
    _messages.add(AiChatMessage(role: 'user', content: message.trim()));
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      final historyForContext = _messages
          .where((m) => m.role != 'assistant' || _messages.indexOf(m) != 0)
          .toList();
      final recentHistory = historyForContext.length > 20
          ? historyForContext.sublist(historyForContext.length - 20)
          : historyForContext;

      // Add placeholder message and start streaming
      final placeholderIndex = _messages.length;
      _messages.add(AiChatMessage(role: 'assistant', content: ''));
      _isStreaming = true;
      notifyListeners();

      String accumulatedText = '';
      AiChatAction? action;

      await for (final event in _aiChatService.sendMessageStream(
        message: message.trim(),
        conversationHistory: recentHistory,
        userName: _userName,
        monthId: _currentMonthId,
      )) {
        switch (event.type) {
          case 'text':
            accumulatedText += event.content ?? '';
            _messages[placeholderIndex] = AiChatMessage(
              role: 'assistant',
              content: accumulatedText,
            );
            notifyListeners();
            break;
          case 'status':
            // Show status in the placeholder while processing
            if (accumulatedText.isEmpty) {
              _messages[placeholderIndex] = AiChatMessage(
                role: 'assistant',
                content: '_${event.content ?? "Thinking..."}_',
              );
              notifyListeners();
            }
            break;
          case 'done':
            action = event.action;
            break;
          case 'error':
            throw Exception(event.content ?? 'Unknown error');
        }
      }

      // Finalize message with action
      _messages[placeholderIndex] = AiChatMessage(
        role: 'assistant',
        content: accumulatedText,
        action: action,
      );

      if (action != null) {
        onAction?.call(action);
      }
    } catch (e) {
      _error = e.toString();
      debugPrint('AI Chat error: $e');
      _messages.add(AiChatMessage(
        role: 'assistant',
        content: 'Error: $e\n\nPlease try again in a moment.',
      ));
    } finally {
      _isLoading = false;
      _isStreaming = false;
      notifyListeners();
    }
  }

  /// Confirm a pending job addition — writes to Firestore
  Future<void> confirmPendingJob(int messageIndex) async {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];
    final jobData = message.action?.jobData;
    if (jobData == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _aiChatService.confirmAddJob(
        jobData: jobData,
        userName: _userName,
      );

      // Replace the pending action with a confirmed one
      _messages[messageIndex] = AiChatMessage(
        role: message.role,
        content: message.content,
        timestamp: message.timestamp,
        action: AiChatAction(
          type: 'jobAdded',
          jobId: result['jobId'] as String?,
          monthId: result['monthId'] as String?,
        ),
      );

      onAction?.call(_messages[messageIndex].action!);
    } catch (e) {
      _messages.add(AiChatMessage(
        role: 'assistant',
        content: 'Failed to add job: $e',
      ));
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cancel a pending job addition
  void cancelPendingJob(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];

    _messages[messageIndex] = AiChatMessage(
      role: message.role,
      content: message.content,
      timestamp: message.timestamp,
      action: AiChatAction(type: 'jobCancelled'),
    );

    _messages.add(AiChatMessage(
      role: 'assistant',
      content: 'No problem! The job was not added.',
    ));
    notifyListeners();
  }

  /// Confirm multiple pending jobs — writes all to Firestore
  Future<void> confirmPendingMultipleJobs(int messageIndex) async {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];
    final jobsData = message.action?.jobsData;
    if (jobsData == null || jobsData.isEmpty) return;

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _aiChatService.confirmAddMultipleJobs(
        jobsData: jobsData,
        userName: _userName,
      );

      final jobCount = (result['jobCount'] as num?)?.toInt() ?? jobsData.length;

      _messages[messageIndex] = AiChatMessage(
        role: message.role,
        content: message.content,
        timestamp: message.timestamp,
        action: AiChatAction(type: 'multiJobAdded'),
      );

      _messages.add(AiChatMessage(
        role: 'assistant',
        content: '$jobCount job(s) added to the Job List successfully!',
      ));

      onAction?.call(AiChatAction(type: 'multiJobAdded'));
    } catch (e) {
      _messages.add(AiChatMessage(
        role: 'assistant',
        content: 'Failed to add jobs: $e',
      ));
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cancel multiple pending jobs
  void cancelPendingMultipleJobs(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];

    _messages[messageIndex] = AiChatMessage(
      role: message.role,
      content: message.content,
      timestamp: message.timestamp,
      action: AiChatAction(type: 'multiJobCancelled'),
    );

    _messages.add(AiChatMessage(
      role: 'assistant',
      content: 'No problem! The jobs were not added.',
    ));
    notifyListeners();
  }

  /// Confirm pending schedule grid jobs — writes to Firestore
  Future<void> confirmPendingScheduleJobs(int messageIndex) async {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];
    final scheduleJobsData = message.action?.scheduleJobsData;
    if (scheduleJobsData == null || scheduleJobsData.isEmpty) return;

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _aiChatService.confirmAddScheduleJobs(
        scheduleJobsData: scheduleJobsData,
        userName: _userName,
      );

      final jobCount = (result['jobCount'] as num?)?.toInt() ?? scheduleJobsData.length;

      _messages[messageIndex] = AiChatMessage(
        role: message.role,
        content: message.content,
        timestamp: message.timestamp,
        action: AiChatAction(type: 'scheduleJobsAdded'),
      );

      _messages.add(AiChatMessage(
        role: 'assistant',
        content: '$jobCount job(s) added to the Schedule Grid successfully!',
      ));

      onAction?.call(AiChatAction(type: 'scheduleJobsAdded'));
    } catch (e) {
      _messages.add(AiChatMessage(
        role: 'assistant',
        content: 'Failed to add schedule jobs: $e',
      ));
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cancel pending schedule grid jobs
  void cancelPendingScheduleJobs(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];

    _messages[messageIndex] = AiChatMessage(
      role: message.role,
      content: message.content,
      timestamp: message.timestamp,
      action: AiChatAction(type: 'scheduleJobsCancelled'),
    );

    _messages.add(AiChatMessage(
      role: 'assistant',
      content: 'No problem! The schedule jobs were not added.',
    ));
    notifyListeners();
  }

  /// Confirm a pending job update — applies changes to Firestore
  Future<void> confirmPendingUpdate(int messageIndex) async {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];
    final updateData = message.action?.updateData;
    if (updateData == null) return;

    _isLoading = true;
    notifyListeners();

    try {
      final result = await _aiChatService.confirmUpdateJob(
        updateData: updateData,
        userName: _userName,
      );

      // Replace the pending action with a confirmed one
      _messages[messageIndex] = AiChatMessage(
        role: message.role,
        content: message.content,
        timestamp: message.timestamp,
        action: AiChatAction(
          type: 'jobUpdated',
          jobId: result['jobId'] as String?,
          monthId: result['monthId'] as String?,
        ),
      );

      onAction?.call(_messages[messageIndex].action!);
    } catch (e) {
      _messages.add(AiChatMessage(
        role: 'assistant',
        content: 'Failed to update job: $e',
      ));
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Cancel a pending job update
  void cancelPendingUpdate(int messageIndex) {
    if (messageIndex < 0 || messageIndex >= _messages.length) return;
    final message = _messages[messageIndex];

    _messages[messageIndex] = AiChatMessage(
      role: message.role,
      content: message.content,
      timestamp: message.timestamp,
      action: AiChatAction(type: 'updateCancelled'),
    );

    _messages.add(AiChatMessage(
      role: 'assistant',
      content: 'No problem! The job was not updated.',
    ));
    notifyListeners();
  }

  /// Clear conversation and start fresh
  void clearConversation() {
    _messages.clear();
    _error = null;
    initialize(_userName);
  }

  // ─── System Knowledge Management ───

  /// Get all knowledge entries (cached in service)
  Future<List<AiKnowledgeEntry>> getKnowledge() {
    return _aiChatService.getKnowledge();
  }

  /// Add a new knowledge entry to teach the AI
  Future<void> addKnowledge({
    required String content,
    required String category,
  }) async {
    final entry = AiKnowledgeEntry(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      content: content,
      category: category,
      addedBy: _userName,
      addedAt: DateTime.now(),
    );
    await _aiChatService.addKnowledge(entry);
    notifyListeners();
  }

  /// Remove a knowledge entry
  Future<void> removeKnowledge(String entryId) async {
    await _aiChatService.removeKnowledge(entryId);
    notifyListeners();
  }

  /// Force refresh knowledge from Firestore
  void refreshKnowledge() {
    _aiChatService.invalidateKnowledgeCache();
  }

  @override
  void dispose() {
    _streamSubscription?.cancel();
    _messages.clear();
    super.dispose();
  }
}
