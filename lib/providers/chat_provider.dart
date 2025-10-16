import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:typed_data';
import '../models/chat_message.dart';
import '../services/chat_service.dart';
import 'auth_provider.dart';

class ChatProvider extends ChangeNotifier {
  final ChatService _chatService;
  final AuthProvider _authProvider;

  List<ChatMessage> _messages = [];
  bool _isLoading = false;
  bool _isSending = false;
  String? _error;
  int _unreadCount = 0;
  List<String> _onlineUsers = [];
  StreamSubscription<List<ChatMessage>>? _messagesSubscription;
  StreamSubscription<int>? _unreadCountSubscription;
  StreamSubscription<List<String>>? _onlineUsersSubscription;
  Timer? _heartbeatTimer;
  Timer? _cleanupTimer;

  ChatProvider(this._chatService, this._authProvider) {
    _initializeChat();
  }

  // Getters
  List<ChatMessage> get messages => _messages;
  bool get isLoading => _isLoading;
  bool get isSending => _isSending;
  String? get error => _error;
  int get unreadCount => _unreadCount;
  List<String> get onlineUsers => _onlineUsers;
  bool get hasUnreadMessages => _unreadCount > 0;

  // Initialize chat functionality
  void _initializeChat() {
    if (_authProvider.isAuthenticated) {
      _startListeningToMessages();
      _startListeningToUnreadCount();
      _startListeningToOnlineUsers();
      _updateUserOnlineStatus(true);
      _startHeartbeat();
      _startCleanupTimer();
    }
  }

  // Start heartbeat to keep user status updated
  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(minutes: 2), (timer) {
      if (_authProvider.isAuthenticated) {
        _sendHeartbeat();
      } else {
        timer.cancel();
      }
    });
  }

  // Send heartbeat to update lastSeen timestamp
  Future<void> _sendHeartbeat() async {
    final currentUser = _authProvider.user;
    if (currentUser == null) return;

    try {
      await _chatService.updateUserHeartbeat(currentUser.uid);
    } catch (e) {
      print('ChatProvider: Error sending heartbeat: $e');
    }
  }

  // Start cleanup timer for stale online statuses
  void _startCleanupTimer() {
    _cleanupTimer?.cancel();
    _cleanupTimer = Timer.periodic(const Duration(minutes: 5), (timer) {
      _chatService.cleanupStaleOnlineStatuses();
    });
  }

  // Start listening to messages
  void _startListeningToMessages() {
    _isLoading = true;
    notifyListeners();

    _messagesSubscription = _chatService.getMessages(limit: 100).listen(
      (messages) {
        _messages = messages;
        _isLoading = false;
        _error = null;
        notifyListeners();
      },
      onError: (error) {
        _error = 'Failed to load messages: $error';
        _isLoading = false;
        notifyListeners();
        print('ChatProvider: Error loading messages: $error');
      },
    );
  }

  // Start listening to unread count
  void _startListeningToUnreadCount() {
    final currentUser = _authProvider.user;
    if (currentUser == null) return;

    _unreadCountSubscription =
        _chatService.getUnreadMessageCountStream(currentUser.uid).listen(
      (count) {
        _unreadCount = count;
        notifyListeners();
      },
      onError: (error) {
        print('ChatProvider: Error getting unread count: $error');
      },
    );
  }

  // Start listening to online users
  void _startListeningToOnlineUsers() {
    _onlineUsersSubscription = _chatService.getOnlineUsersStream().listen(
      (users) {
        _onlineUsers = users;
        notifyListeners();
      },
      onError: (error) {
        print('ChatProvider: Error getting online users: $error');
      },
    );
  }

  // Send a text message
  Future<void> sendMessage(String content, {String? replyToMessageId}) async {
    final currentUser = _authProvider.user;
    final appUser = _authProvider.appUser;

    if (currentUser == null) {
      _error = 'User must be authenticated to send messages';
      notifyListeners();
      return;
    }

    if (content.trim().isEmpty) {
      _error = 'Message cannot be empty';
      notifyListeners();
      return;
    }

    _isSending = true;
    _error = null;
    notifyListeners();

    try {
      await _chatService.sendMessage(
        senderId: currentUser.uid,
        senderName: appUser?.displayName ??
            currentUser.displayName ??
            currentUser.email ??
            'Unknown User',
        senderPhotoUrl: appUser?.photoUrl ?? currentUser.photoURL,
        content: content.trim(),
        type: MessageType.text,
        replyToMessageId: replyToMessageId,
      );

      print('ChatProvider: Message sent successfully');
    } catch (e) {
      _error = 'Failed to send message: $e';
      print('ChatProvider: Error sending message: $e');
    } finally {
      _isSending = false;
      notifyListeners();
    }
  }

  Future<void> sendImageMessage(Uint8List imageData, String fileName,
      {String? replyToMessageId}) async {
    final currentUser = _authProvider.user;
    final appUser = _authProvider.appUser;

    if (currentUser == null) {
      _error = 'User must be authenticated to send messages';
      notifyListeners();
      return;
    }

    _isSending = true;
    _error = null;
    notifyListeners();

    try {
      await _chatService.sendImageMessage(
        senderId: currentUser.uid,
        senderName: appUser?.displayName ??
            currentUser.displayName ??
            currentUser.email ??
            'Unknown User',
        senderPhotoUrl: appUser?.photoUrl ?? currentUser.photoURL,
        imageData: imageData,
        fileName: fileName,
        replyToMessageId: replyToMessageId,
      );

      print('ChatProvider: Image message sent successfully');
    } catch (e) {
      _error = 'Failed to send image: $e';
      print('ChatProvider: Error sending image: $e');
    } finally {
      _isSending = false;
      notifyListeners();
    }
  }

  // Send a system message (admin only)
  Future<void> sendSystemMessage(String content) async {
    final currentUser = _authProvider.user;
    final appUser = _authProvider.appUser;

    if (currentUser == null || !_authProvider.isAdmin) {
      _error = 'Only administrators can send system messages';
      notifyListeners();
      return;
    }

    _isSending = true;
    _error = null;
    notifyListeners();

    try {
      await _chatService.sendSystemMessage(
        content: content.trim(),
        metadata: {
          'adminId': currentUser.uid,
          'adminName': appUser?.displayName ?? 'Administrator',
        },
      );

      print('ChatProvider: System message sent successfully');
    } catch (e) {
      _error = 'Failed to send system message: $e';
      print('ChatProvider: Error sending system message: $e');
    } finally {
      _isSending = false;
      notifyListeners();
    }
  }

  // Mark message as read
  Future<void> markMessageAsRead(String messageId) async {
    final currentUser = _authProvider.user;
    if (currentUser == null) return;

    try {
      await _chatService.markMessageAsRead(messageId, currentUser.uid);
    } catch (e) {
      print('ChatProvider: Error marking message as read: $e');
    }
  }

  // Mark all messages as read
  Future<void> markAllMessagesAsRead() async {
    final currentUser = _authProvider.user;
    if (currentUser == null) return;

    try {
      final unreadMessages = _messages
          .where((message) =>
              message.senderId != currentUser.uid &&
              !message.readBy.contains(currentUser.uid))
          .map((message) => message.id)
          .toList();

      if (unreadMessages.isNotEmpty) {
        await _chatService.markMultipleMessagesAsRead(
            unreadMessages, currentUser.uid);
      }
    } catch (e) {
      print('ChatProvider: Error marking all messages as read: $e');
    }
  }

  // Delete a message
  Future<void> deleteMessage(String messageId) async {
    final currentUser = _authProvider.user;
    if (currentUser == null) {
      _error = 'User must be authenticated to delete messages';
      notifyListeners();
      return;
    }

    try {
      await _chatService.deleteMessage(messageId, currentUser.uid);
      print('ChatProvider: Message deleted successfully');
    } catch (e) {
      _error = 'Failed to delete message: $e';
      notifyListeners();
      print('ChatProvider: Error deleting message: $e');
    }
  }

  // Edit a message
  Future<void> editMessage(String messageId, String newContent) async {
    final currentUser = _authProvider.user;
    if (currentUser == null) {
      _error = 'User must be authenticated to edit messages';
      notifyListeners();
      return;
    }

    if (newContent.trim().isEmpty) {
      _error = 'Message cannot be empty';
      notifyListeners();
      return;
    }

    try {
      await _chatService.editMessage(
          messageId, currentUser.uid, newContent.trim());
      print('ChatProvider: Message edited successfully');
    } catch (e) {
      _error = 'Failed to edit message: $e';
      notifyListeners();
      print('ChatProvider: Error editing message: $e');
    }
  }

  // Search messages
  Future<List<ChatMessage>> searchMessages(String query) async {
    if (query.trim().isEmpty) return [];

    try {
      return await _chatService.searchMessages(query.trim());
    } catch (e) {
      print('ChatProvider: Error searching messages: $e');
      return [];
    }
  }

  // Get message by ID
  Future<ChatMessage?> getMessageById(String messageId) async {
    try {
      return await _chatService.getMessageById(messageId);
    } catch (e) {
      print('ChatProvider: Error getting message by ID: $e');
      return null;
    }
  }

  // Update user online status
  Future<void> _updateUserOnlineStatus(bool isOnline) async {
    final currentUser = _authProvider.user;
    if (currentUser == null) return;

    try {
      await _chatService.updateUserStatus(currentUser.uid, isOnline);
    } catch (e) {
      print('ChatProvider: Error updating user status: $e');
    }
  }

  // Check if user is online
  bool isUserOnline(String userId) {
    return _onlineUsers.contains(userId);
  }

  // Get chat statistics (admin only)
  Future<Map<String, dynamic>?> getChatStatistics() async {
    if (!_authProvider.isAdmin) {
      _error = 'Only administrators can view chat statistics';
      notifyListeners();
      return null;
    }

    try {
      return await _chatService.getChatStatistics();
    } catch (e) {
      _error = 'Failed to get chat statistics: $e';
      notifyListeners();
      print('ChatProvider: Error getting chat statistics: $e');
      return null;
    }
  }

  // Clean up old messages (admin only)
  Future<void> cleanupOldMessages({int daysOld = 30}) async {
    if (!_authProvider.isAdmin) {
      _error = 'Only administrators can cleanup messages';
      notifyListeners();
      return;
    }

    try {
      await _chatService.cleanupOldMessages(daysOld: daysOld);
      print('ChatProvider: Old messages cleaned up successfully');
    } catch (e) {
      _error = 'Failed to cleanup old messages: $e';
      notifyListeners();
      print('ChatProvider: Error cleaning up old messages: $e');
    }
  }

  // Clear error
  void clearError() {
    _error = null;
    notifyListeners();
  }

  // Refresh messages
  Future<void> refreshMessages() async {
    _startListeningToMessages();
  }

  // Search users for mentions
  Future<List<Map<String, String>>> searchUsers(String query) async {
    return await _chatService.searchUsers(query);
  }

  // Handle authentication state changes
  void handleAuthStateChange() {
    if (_authProvider.isAuthenticated) {
      _initializeChat();
    } else {
      _cleanup();
    }
  }

  // Clean up resources
  void _cleanup() {
    _updateUserOnlineStatus(false);
    _messagesSubscription?.cancel();
    _unreadCountSubscription?.cancel();
    _onlineUsersSubscription?.cancel();
    _heartbeatTimer?.cancel();
    _cleanupTimer?.cancel();
    _messages.clear();
    _unreadCount = 0;
    _onlineUsers.clear();
    _error = null;
    _isLoading = false;
    _isSending = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _cleanup();
    super.dispose();
  }
}
