import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'dart:async';
import 'dart:typed_data';
import '../models/chat_message.dart';

class ChatService {
  final FirebaseFirestore _firestore;
  final FirebaseStorage _storage = FirebaseStorage.instance;
  static const String _chatMonthsCollection = 'chat_months';
  static const String _userStatusCollection = 'user_status';

  ChatService(this._firestore);

  // Get month document ID for a given date
  String _getMonthDocumentId(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }

  // Get current month document reference
  DocumentReference _getCurrentMonthDocument() {
    final now = DateTime.now();
    final monthId = _getMonthDocumentId(now);
    return _firestore.collection(_chatMonthsCollection).doc(monthId);
  }

  // Stream of all chat messages ordered by timestamp (current month)
  Stream<List<ChatMessage>> getMessages({int limit = 50}) {
    final monthDoc = _getCurrentMonthDocument();
    return monthDoc.snapshots().map((snapshot) {
      if (!snapshot.exists) {
        return <ChatMessage>[];
      }

      final data = snapshot.data() as Map<String, dynamic>?;
      final messagesData = data?['messages'] as List<dynamic>? ?? [];

      // Convert to ChatMessage objects and sort by timestamp (newest first, then reverse for display)
      final messages = messagesData
          .map((messageData) =>
              ChatMessage.fromMap(messageData as Map<String, dynamic>))
          .toList();

      // Sort by timestamp descending, then take limit, then reverse for chronological order
      messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
      final limitedMessages = messages.take(limit).toList();
      return limitedMessages.reversed.toList();
    });
  }

  // Send a message
  Future<String> sendMessage({
    required String senderId,
    required String senderName,
    String? senderPhotoUrl,
    required String content,
    MessageType type = MessageType.text,
    String? replyToMessageId,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // Parse mentions from content
      final mentions = parseMentions(content);

      // Generate unique ID for the message
      final messageId = _firestore.collection('temp').doc().id;

      final message = ChatMessage(
        id: messageId,
        senderId: senderId,
        senderName: senderName,
        senderPhotoUrl: senderPhotoUrl,
        content: content,
        type: type,
        timestamp: DateTime.now(),
        isRead: false,
        readBy: [senderId], // Sender has automatically read their own message
        replyToMessageId: replyToMessageId,
        metadata: metadata,
        mentions: mentions,
      );

      final monthDoc = _getCurrentMonthDocument();

      // Add message to the messages array using arrayUnion
      await monthDoc.set({
        'messages': FieldValue.arrayUnion([message.toMap()]),
        'lastUpdated': FieldValue.serverTimestamp(),
        'messageCount': FieldValue.increment(1),
      }, SetOptions(merge: true));

      print('ChatService: Message sent with ID: $messageId');
      return messageId;
    } catch (e) {
      print('ChatService: Error sending message: $e');
      throw Exception('Failed to send message: $e');
    }
  }

  // Upload image to Firebase Storage and send as message
  Future<String> sendImageMessage({
    required String senderId,
    required String senderName,
    String? senderPhotoUrl,
    required Uint8List imageData,
    required String fileName,
    String? replyToMessageId,
    Map<String, dynamic>? metadata,
  }) async {
    try {
      // Upload image to Firebase Storage
      final storageRef = _storage.ref().child(
          'chat_images/${DateTime.now().millisecondsSinceEpoch}_$fileName');
      final uploadTask = storageRef.putData(imageData);
      final snapshot = await uploadTask;
      final downloadUrl = await snapshot.ref.getDownloadURL();

      // Send message with image URL
      return await sendMessage(
        senderId: senderId,
        senderName: senderName,
        senderPhotoUrl: senderPhotoUrl,
        content: downloadUrl,
        type: MessageType.image,
        replyToMessageId: replyToMessageId,
        metadata: {
          'fileName': fileName,
          'fileSize': imageData.length,
          ...?metadata,
        },
      );
    } catch (e) {
      print('ChatService: Error sending image message: $e');
      throw Exception('Failed to send image message: $e');
    }
  }

  // Send a system message (announcements, notifications, etc.)
  Future<String> sendSystemMessage({
    required String content,
    Map<String, dynamic>? metadata,
  }) async {
    return await sendMessage(
      senderId: 'system',
      senderName: 'System',
      content: content,
      type: MessageType.system,
      metadata: metadata,
    );
  }

  // Mark message as read
  Future<void> markMessageAsRead(String messageId, String userId) async {
    try {
      final messageResult =
          await _findAndUpdateMessage(messageId, (messageData) {
        final readBy = List<String>.from(messageData['readBy'] ?? []);
        if (!readBy.contains(userId)) {
          readBy.add(userId);
          messageData['readBy'] = readBy;
          messageData['isRead'] = true;
        }
        return messageData;
      });

      if (messageResult == null) {
        print('ChatService: Message not found for ID: $messageId');
      }
    } catch (e) {
      print('ChatService: Error marking message as read: $e');
    }
  }

  // Mark multiple messages as read
  Future<void> markMultipleMessagesAsRead(
      List<String> messageIds, String userId) async {
    try {
      for (String messageId in messageIds) {
        await markMessageAsRead(messageId, userId);
      }
    } catch (e) {
      print('ChatService: Error marking multiple messages as read: $e');
    }
  }

  // Get unread message count for a user
  Future<int> getUnreadMessageCount(String userId) async {
    try {
      final monthDoc = _getCurrentMonthDocument();
      final snapshot = await monthDoc.get();

      if (!snapshot.exists) return 0;

      final data = snapshot.data() as Map<String, dynamic>?;
      final messagesData = data?['messages'] as List<dynamic>? ?? [];

      int unreadCount = 0;
      for (var messageData in messagesData) {
        final readBy = List<String>.from(messageData['readBy'] ?? []);
        final senderId = messageData['senderId'] ?? '';

        // Don't count own messages as unread
        if (senderId != userId && !readBy.contains(userId)) {
          unreadCount++;
        }
      }

      return unreadCount;
    } catch (e) {
      print('ChatService: Error getting unread message count: $e');
      return 0;
    }
  }

  // Stream of unread message count
  Stream<int> getUnreadMessageCountStream(String userId) {
    final monthDoc = _getCurrentMonthDocument();
    return monthDoc.snapshots().map((snapshot) {
      if (!snapshot.exists) return 0;

      final data = snapshot.data() as Map<String, dynamic>?;
      final messagesData = data?['messages'] as List<dynamic>? ?? [];

      int unreadCount = 0;
      for (var messageData in messagesData) {
        final readBy = List<String>.from(messageData['readBy'] ?? []);
        final senderId = messageData['senderId'] ?? '';

        // Don't count own messages as unread
        if (senderId != userId && !readBy.contains(userId)) {
          unreadCount++;
        }
      }

      return unreadCount;
    });
  }

  // Delete a message
  Future<void> deleteMessage(String messageId, String userId) async {
    try {
      final messageResult = await _findAndRemoveMessage(messageId, userId);

      if (messageResult == null) {
        print(
            'ChatService: Message not found or permission denied for ID: $messageId');
      }
    } catch (e) {
      print('ChatService: Error deleting message: $e');
    }
  }

  // Get message by ID
  Future<ChatMessage?> getMessageById(String messageId) async {
    try {
      final monthDoc = _getCurrentMonthDocument();
      final snapshot = await monthDoc.get();

      if (!snapshot.exists) return null;

      final data = snapshot.data() as Map<String, dynamic>?;
      final messagesData = data?['messages'] as List<dynamic>? ?? [];

      for (var messageData in messagesData) {
        if (messageData['id'] == messageId) {
          return ChatMessage.fromMap(messageData as Map<String, dynamic>);
        }
      }

      return null;
    } catch (e) {
      print('ChatService: Error getting message by ID: $e');
      return null;
    }
  }

  // Search messages in current month
  Future<List<ChatMessage>> searchMessages(String query,
      {int limit = 20}) async {
    try {
      final monthDoc = _getCurrentMonthDocument();
      final snapshot = await monthDoc.get();

      if (!snapshot.exists) return [];

      final data = snapshot.data() as Map<String, dynamic>?;
      final messagesData = data?['messages'] as List<dynamic>? ?? [];

      final matchingMessages = <ChatMessage>[];

      for (var messageData in messagesData) {
        final content = messageData['content']?.toString().toLowerCase() ?? '';
        if (content.contains(query.toLowerCase())) {
          matchingMessages
              .add(ChatMessage.fromMap(messageData as Map<String, dynamic>));
        }

        if (matchingMessages.length >= limit) break;
      }

      // Sort by timestamp descending
      matchingMessages.sort((a, b) => b.timestamp.compareTo(a.timestamp));

      return matchingMessages;
    } catch (e) {
      print('ChatService: Error searching messages: $e');
      return [];
    }
  }

  // Update user online status
  Future<void> updateUserStatus(String userId, bool isOnline) async {
    try {
      // Get user info from users collection to store display name
      final userDoc = await _firestore.collection('users').doc(userId).get();
      String displayName = 'User';
      String? photoUrl;

      if (userDoc.exists) {
        final userData = userDoc.data() as Map<String, dynamic>;
        displayName = userData['name'] ?? userData['email'] ?? 'User';
        photoUrl = userData['photoUrl'];
      }

      await _firestore.collection(_userStatusCollection).doc(userId).set({
        'isOnline': isOnline,
        'lastSeen': FieldValue.serverTimestamp(),
        'displayName': displayName,
        'photoUrl': photoUrl,
      }, SetOptions(merge: true));
    } catch (e) {
      print('ChatService: Error updating user status: $e');
    }
  }

  // Update user status with heartbeat
  Future<void> updateUserHeartbeat(String userId) async {
    try {
      // Get user info from users collection to store display name
      final userDoc = await _firestore.collection('users').doc(userId).get();
      String displayName = 'User';
      String? photoUrl;

      if (userDoc.exists) {
        final userData = userDoc.data() as Map<String, dynamic>;
        displayName = userData['name'] ?? userData['email'] ?? 'User';
        photoUrl = userData['photoUrl'];
      }

      await _firestore.collection(_userStatusCollection).doc(userId).set({
        'isOnline': true,
        'lastSeen': FieldValue.serverTimestamp(),
        'displayName': displayName,
        'photoUrl': photoUrl,
      }, SetOptions(merge: true));
    } catch (e) {
      print('ChatService: Error updating user heartbeat: $e');
    }
  }

  // Stream of online users (considers lastSeen timestamp)
  Stream<List<String>> getOnlineUsersStream() {
    return _firestore
        .collection(_userStatusCollection)
        .snapshots()
        .map((snapshot) {
      final now = DateTime.now();
      final onlineThreshold =
          now.subtract(const Duration(minutes: 5)); // 5 minutes threshold

      return snapshot.docs
          .where((doc) {
            final data = doc.data();
            final isOnline = data['isOnline'] == true;
            final lastSeen = data['lastSeen'] as Timestamp?;

            if (!isOnline || lastSeen == null) return false;

            // Check if lastSeen is within the threshold
            return lastSeen.toDate().isAfter(onlineThreshold);
          })
          .map((doc) => doc.id)
          .toList();
    });
  }

  // Clean up stale online statuses
  Future<void> cleanupStaleOnlineStatuses() async {
    try {
      final now = DateTime.now();
      final staleThreshold =
          now.subtract(const Duration(minutes: 10)); // 10 minutes threshold

      final staleUsers = await _firestore
          .collection(_userStatusCollection)
          .where('isOnline', isEqualTo: true)
          .where('lastSeen', isLessThan: Timestamp.fromDate(staleThreshold))
          .get();

      final batch = _firestore.batch();

      for (var doc in staleUsers.docs) {
        batch.update(doc.reference, {'isOnline': false});
      }

      if (staleUsers.docs.isNotEmpty) {
        await batch.commit();
        print(
            'ChatService: Cleaned up ${staleUsers.docs.length} stale online statuses');
      }
    } catch (e) {
      print('ChatService: Error cleaning up stale online statuses: $e');
    }
  }

  // Get chat statistics
  Future<Map<String, dynamic>> getChatStatistics() async {
    try {
      final monthDoc = _getCurrentMonthDocument();
      final messagesSnapshot = await monthDoc.get();
      final userStatusSnapshot =
          await _firestore.collection(_userStatusCollection).get();

      final data = messagesSnapshot.data() as Map<String, dynamic>?;
      final messagesData = data?['messages'] as List<dynamic>? ?? [];
      final messageCount = messagesData.length;

      final onlineUsers = userStatusSnapshot.docs
          .where((doc) => doc.data()['isOnline'] == true)
          .length;

      // Count messages by type
      final messageCounts = <String, int>{};
      for (var messageData in messagesData) {
        final type = messageData['type'] ?? 'text';
        messageCounts[type] = (messageCounts[type] ?? 0) + 1;
      }

      return {
        'totalMessages': messageCount,
        'onlineUsers': onlineUsers,
        'totalUsers': userStatusSnapshot.docs.length,
        'messagesByType': messageCounts,
        'currentMonth': _getMonthDocumentId(DateTime.now()),
      };
    } catch (e) {
      print('ChatService: Error getting chat statistics: $e');
      return {};
    }
  }

  // Search users for mentions
  Future<List<Map<String, String>>> searchUsers(String query) async {
    try {
      print('ChatService: Searching users with query: "$query"');

      // First try to get any users from the collection (without isActive filter)
      final allUsersSnapshot =
          await _firestore.collection('users').limit(20).get();

      print(
          'ChatService: Found ${allUsersSnapshot.docs.length} total users in collection');

      // Search only active users first
      Query usersQuery = _firestore
          .collection('users')
          .where('isActive', isEqualTo: true)
          .orderBy('name')
          .limit(20);

      final usersSnapshot = await usersQuery.get();
      print('ChatService: Found ${usersSnapshot.docs.length} active users');

      List<Map<String, String>> users = [];

      for (var doc in usersSnapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final displayName = data['name'] ?? data['email'] ?? 'User';
        print(
            'ChatService: User ${doc.id}: $displayName (isActive: ${data['isActive']})');

        // Filter by query if provided
        if (query.isEmpty ||
            displayName.toLowerCase().contains(query.toLowerCase())) {
          users.add({
            'id': doc.id,
            'displayName': displayName,
            'photoUrl': data['photoUrl'] ?? '',
          });
          print('ChatService: Added user to suggestions: $displayName');
        }
      }

      // If no active users found, try getting any users (even inactive ones)
      if (users.isEmpty && allUsersSnapshot.docs.isNotEmpty) {
        print('ChatService: No active users found, trying all users');
        for (var doc in allUsersSnapshot.docs) {
          final data = doc.data();
          final displayName = data['name'] ?? data['email'] ?? 'User';
          print(
              'ChatService: All users - ${doc.id}: $displayName (isActive: ${data['isActive'] ?? 'null'})');

          // Filter by query if provided
          if (query.isEmpty ||
              displayName.toLowerCase().contains(query.toLowerCase())) {
            users.add({
              'id': doc.id,
              'displayName': displayName,
              'photoUrl': data['photoUrl'] ?? '',
            });
            print('ChatService: Added any user to suggestions: $displayName');
          }
        }
      }

      print('ChatService: Returning ${users.length} users for mentions');
      return users;
    } catch (e) {
      print('ChatService: Error searching users: $e');
      return [];
    }
  }

  // Helper method to find and update a message
  Future<Map<String, dynamic>?> _findAndUpdateMessage(
      String messageId,
      Map<String, dynamic> Function(Map<String, dynamic>)
          updateFunction) async {
    final monthDoc = _getCurrentMonthDocument();
    final snapshot = await monthDoc.get();

    if (!snapshot.exists) return null;

    final docData = snapshot.data() as Map<String, dynamic>?;
    final messagesData =
        List<Map<String, dynamic>>.from(docData?['messages'] ?? []);

    bool found = false;
    for (int i = 0; i < messagesData.length; i++) {
      if (messagesData[i]['id'] == messageId) {
        messagesData[i] = updateFunction(messagesData[i]);
        found = true;
        break;
      }
    }

    if (found) {
      await monthDoc.update({'messages': messagesData});
      return messagesData.firstWhere((msg) => msg['id'] == messageId);
    }

    return null;
  }

  // Helper method to find and remove a message
  Future<Map<String, dynamic>?> _findAndRemoveMessage(
      String messageId, String userId) async {
    final monthDoc = _getCurrentMonthDocument();
    final snapshot = await monthDoc.get();

    if (!snapshot.exists) return null;

    final docData = snapshot.data() as Map<String, dynamic>?;
    final messagesData =
        List<Map<String, dynamic>>.from(docData?['messages'] ?? []);

    Map<String, dynamic>? removedMessage;

    for (int i = 0; i < messagesData.length; i++) {
      if (messagesData[i]['id'] == messageId) {
        // Check if user has permission to delete (own message or admin)
        if (messagesData[i]['senderId'] == userId) {
          removedMessage = messagesData.removeAt(i);
          break;
        }
      }
    }

    if (removedMessage != null) {
      await monthDoc.update({
        'messages': messagesData,
        'messageCount': FieldValue.increment(-1),
      });
    }

    return removedMessage;
  }

  // Edit a message
  Future<void> editMessage(
    String messageId,
    String newContent,
    String userId,
  ) async {
    try {
      final messageResult =
          await _findAndUpdateMessage(messageId, (messageData) {
        // Check if user can edit (must be sender)
        if (messageData['senderId'] == userId) {
          messageData['content'] = newContent;
          messageData['metadata'] = {
            ...?messageData['metadata'],
            'edited': true,
            'editedAt': DateTime.now().toIso8601String(),
            'editedBy': userId,
          };
        }
        return messageData;
      });

      if (messageResult == null) {
        print(
            'ChatService: Message not found or permission denied for editing ID: $messageId');
      }
    } catch (e) {
      print('ChatService: Error editing message: $e');
    }
  }

  // Clean up old messages (for array structure, this will be implemented differently)
  Future<void> cleanupOldMessages({int daysOld = 30}) async {
    try {
      // For array-based structure, we'd need to search through all month documents
      // and remove old messages from arrays. This is more complex than the subcollection approach.
      // For now, we'll just log that this functionality needs to be implemented.
      print(
          'ChatService: Cleanup old messages not yet implemented for array structure');

      // In the future, this would involve:
      // 1. Finding all month documents older than cutoff
      // 2. Removing or archiving them entirely
      // 3. Or filtering out old messages from current month arrays
    } catch (e) {
      print('ChatService: Error cleaning up old messages: $e');
    }
  }

  // Parse mentions from message content
  static List<String> parseMentions(String content) {
    final mentionRegex = RegExp(r'@\[([^\]]+)\]\(([^)]+)\)');
    final matches = mentionRegex.allMatches(content);
    return matches.map((match) => match.group(2)!).toList();
  }

  // Format content with mentions for display
  static String formatMentionsForDisplay(String content) {
    final mentionRegex = RegExp(r'@\[([^\]]+)\]\(([^)]+)\)');
    return content.replaceAllMapped(mentionRegex, (match) {
      return '@${match.group(1)}'; // Just show @username
    });
  }
}
