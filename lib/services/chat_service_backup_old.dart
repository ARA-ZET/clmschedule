// import 'package:cloud_firestore/cloud_firestore.dart';
// import 'package:firebase_storage/firebase_storage.dart';
// import 'dart:async';
// import 'dart:typed_data';
// import '../models/chat_message.dart';

// class ChatService {
//   final FirebaseFirestore _firestore;
//   final FirebaseStorage _storage = FirebaseStorage.instance;
//   static const String _chatMonthsCollection = 'chat_months';
//   static const String _userStatusCollection = 'user_status';

//   ChatService(this._firestore);

//   // Get month document ID for a given date
//   String _getMonthDocumentId(DateTime date) {
//     return '${date.year}-${date.month.toString().padLeft(2, '0')}';
//   }

//   // Get current month document reference
//   DocumentReference _getCurrentMonthDocument() {
//     final now = DateTime.now();
//     final monthId = _getMonthDocumentId(now);
//     return _firestore.collection(_chatMonthsCollection).doc(monthId);
//   }

//   // Get month document reference for specific date
//   DocumentReference _getMonthDocument(DateTime date) {
//     final monthId = _getMonthDocumentId(date);
//     return _firestore.collection(_chatMonthsCollection).doc(monthId);
//   }

//   // Find message by ID in monthly documents (searches current and previous months)
//   Future<Map<String, dynamic>?> _findMessageInMonths(String messageId) async {
//     // Try current month first
//     final currentMonth = _getCurrentMonthDocument();
//     final currentSnapshot = await currentMonth.get();
    
//     if (currentSnapshot.exists) {
//       final data = currentSnapshot.data() as Map<String, dynamic>?;
//       final messages = data?['messages'] as List<dynamic>? ?? [];
      
//       for (var messageData in messages) {
//         if (messageData['id'] == messageId) {
//           return {
//             'message': messageData,
//             'monthDoc': currentMonth,
//           };
//         }
//       }
//     }

//     // Search previous months (up to 3 months back)
//     final now = DateTime.now();
//     for (int i = 1; i <= 3; i++) {
//       final pastDate = DateTime(now.year, now.month - i, 1);
//       final pastMonth = _getMonthDocument(pastDate);
//       final pastSnapshot = await pastMonth.get();
      
//       if (pastSnapshot.exists) {
//         final data = pastSnapshot.data() as Map<String, dynamic>?;
//         final messages = data?['messages'] as List<dynamic>? ?? [];
        
//         for (var messageData in messages) {
//           if (messageData['id'] == messageId) {
//             return {
//               'message': messageData,
//               'monthDoc': pastMonth,
//             };
//           }
//         }
//       }
//     }

//     return null;
//   }

//   // Stream of all chat messages ordered by timestamp (current month + previous months)
//   Stream<List<ChatMessage>> getMessages({int limit = 50}) {
//     return _getCurrentMonthMessagesStream(limit: limit);
//   }

//   // Get messages from current month
//   Stream<List<ChatMessage>> _getCurrentMonthMessagesStream({int limit = 50}) {
//     final monthDoc = _getCurrentMonthDocument();
//     return monthDoc.snapshots().map((snapshot) {
//       if (!snapshot.exists) {
//         return <ChatMessage>[];
//       }
      
//       final data = snapshot.data() as Map<String, dynamic>?;
//       final messagesData = data?['messages'] as List<dynamic>? ?? [];
      
//       // Convert to ChatMessage objects and sort by timestamp (newest first, then reverse for display)
//       final messages = messagesData
//           .map((messageData) => ChatMessage.fromMap(messageData as Map<String, dynamic>))
//           .toList();
      
//       // Sort by timestamp descending, then take limit, then reverse for chronological order
//       messages.sort((a, b) => b.timestamp.compareTo(a.timestamp));
//       final limitedMessages = messages.take(limit).toList();
//       return limitedMessages.reversed.toList();
//     });
//   }

//   // Stream of messages with pagination (from current month)
//   Stream<List<ChatMessage>> getMessagesWithPagination({
//     int limit = 50,
//     DocumentSnapshot? lastDocument,
//   }) {
//     // For array-based structure, pagination works differently
//     // We'll implement this later if needed
//     return getMessages(limit: limit);
//   }

//   // Send a message
//   Future<String> sendMessage({
//     required String senderId,
//     required String senderName,
//     String? senderPhotoUrl,
//     required String content,
//     MessageType type = MessageType.text,
//     String? replyToMessageId,
//     Map<String, dynamic>? metadata,
//   }) async {
//     try {
//       // Parse mentions from content
//       final mentions = parseMentions(content);
      
//       final message = ChatMessage(
//         id: '', // Will be set by Firestore
//         senderId: senderId,
//         senderName: senderName,
//         senderPhotoUrl: senderPhotoUrl,
//         content: content,
//         type: type,
//         timestamp: DateTime.now(),
//         isRead: false,
//         readBy: [senderId], // Sender has automatically read their own message
//         replyToMessageId: replyToMessageId,
//         metadata: metadata,
//         mentions: mentions,
//       );

//       // Generate unique ID for the message
//       final messageId = _firestore.collection('temp').doc().id;
      
//       // Create message with ID
//       final messageWithId = message.copyWith(id: messageId);
      
//       final monthDoc = _getCurrentMonthDocument();
      
//       // Add message to the messages array using arrayUnion
//       await monthDoc.set({
//         'messages': FieldValue.arrayUnion([messageWithId.toMap()]),
//         'lastUpdated': FieldValue.serverTimestamp(),
//         'messageCount': FieldValue.increment(1),
//       }, SetOptions(merge: true));

//       print('ChatService: Message sent with ID: $messageId');
//       return messageId;
//     } catch (e) {
//       print('ChatService: Error sending message: $e');
//       throw Exception('Failed to send message: $e');
//     }
//   }

//   // Upload image to Firebase Storage and send as message
//   Future<String> sendImageMessage({
//     required String senderId,
//     required String senderName,
//     String? senderPhotoUrl,
//     required Uint8List imageData,
//     required String fileName,
//     String? replyToMessageId,
//     Map<String, dynamic>? metadata,
//   }) async {
//     try {
//       // Upload image to Firebase Storage
//       final storageRef = _storage.ref().child(
//           'chat_images/${DateTime.now().millisecondsSinceEpoch}_$fileName');
//       final uploadTask = storageRef.putData(imageData);
//       final snapshot = await uploadTask;
//       final downloadUrl = await snapshot.ref.getDownloadURL();

//       // Send message with image URL
//       return await sendMessage(
//         senderId: senderId,
//         senderName: senderName,
//         senderPhotoUrl: senderPhotoUrl,
//         content: downloadUrl,
//         type: MessageType.image,
//         replyToMessageId: replyToMessageId,
//         metadata: {
//           'fileName': fileName,
//           'fileSize': imageData.length,
//           ...?metadata,
//         },
//       );
//     } catch (e) {
//       print('ChatService: Error sending image message: $e');
//       throw Exception('Failed to send image message: $e');
//     }
//   }

//   // Send a system message (announcements, notifications, etc.)
//   Future<String> sendSystemMessage({
//     required String content,
//     Map<String, dynamic>? metadata,
//   }) async {
//     return await sendMessage(
//       senderId: 'system',
//       senderName: 'System',
//       content: content,
//       type: MessageType.system,
//       metadata: metadata,
//     );
//   }

//   // Mark message as read
//   Future<void> markMessageAsRead(String messageId, String userId) async {
//     try {
//       final messageDoc = await _findMessageDocument(messageId);
//       if (messageDoc != null) {
//         await messageDoc.update({
//           'readBy': FieldValue.arrayUnion([userId]),
//           'isRead': true,
//         });
//       }
//     } catch (e) {
//       print('ChatService: Error marking message as read: $e');
//     }
//   }

//   // Mark multiple messages as read
//   Future<void> markMultipleMessagesAsRead(
//       List<String> messageIds, String userId) async {
//     try {
//       final batch = _firestore.batch();

//       for (String messageId in messageIds) {
//         final messageDoc = await _findMessageDocument(messageId);
//         if (messageDoc != null) {
//           batch.update(messageDoc, {
//             'readBy': FieldValue.arrayUnion([userId]),
//             'isRead': true,
//           });
//         }
//       }

//       await batch.commit();
//     } catch (e) {
//       print('ChatService: Error marking multiple messages as read: $e');
//     }
//   }

//   // Get unread message count for a user
//   Future<int> getUnreadMessageCount(String userId) async {
//     try {
//       final monthDoc = _getCurrentMonthDocument();
//       final querySnapshot = await monthDoc
//           .collection(_messagesSubcollection)
//           .where('readBy', whereNotIn: [
//         [userId]
//       ]).get();

//       return querySnapshot.docs.length;
//     } catch (e) {
//       print('ChatService: Error getting unread message count: $e');
//       return 0;
//     }
//   }

//   // Stream of unread message count
//   Stream<int> getUnreadMessageCountStream(String userId) {
//     final monthDoc = _getCurrentMonthDocument();
//     return monthDoc
//         .collection(_messagesSubcollection)
//         .where('senderId', isNotEqualTo: userId)
//         .snapshots()
//         .map((snapshot) {
//       int unreadCount = 0;
//       for (var doc in snapshot.docs) {
//         final data = doc.data();
//         final readBy = List<String>.from(data['readBy'] ?? []);
//         if (!readBy.contains(userId)) {
//           unreadCount++;
//         }
//       }
//       return unreadCount;
//     });
//   }

//   // Delete a message (admin only)
//   Future<void> deleteMessage(String messageId, String userId) async {
//     try {
//       final messageDoc = await _findMessageDocument(messageId);
//       if (messageDoc != null) {
//         await messageDoc.delete();
//         print('ChatService: Message deleted: $messageId');
//       }
//     } catch (e) {
//       print('ChatService: Error deleting message: $e');
//       throw Exception('Failed to delete message: $e');
//     }
//   }

//   // Edit a message
//   Future<void> editMessage(
//     String messageId,
//     String newContent,
//     String userId,
//   ) async {
//     try {
//       final messageDoc = await _findMessageDocument(messageId);
//       if (messageDoc != null) {
//         await messageDoc.update({
//           'content': newContent,
//           'metadata.edited': true,
//           'metadata.editedAt': FieldValue.serverTimestamp(),
//           'metadata.editedBy': userId,
//         });
//         print('ChatService: Message edited: $messageId');
//       }
//     } catch (e) {
//       print('ChatService: Error editing message: $e');
//       throw Exception('Failed to edit message: $e');
//     }
//   }

//   // Get a specific message by ID
//   Future<ChatMessage?> getMessageById(String messageId) async {
//     try {
//       final messageDoc = await _findMessageDocument(messageId);
//       if (messageDoc != null) {
//         final docSnapshot = await messageDoc.get();
//         if (docSnapshot.exists) {
//           return ChatMessage.fromFirestore(docSnapshot);
//         }
//       }
//       return null;
//     } catch (e) {
//       print('ChatService: Error getting message by ID: $e');
//       return null;
//     }
//   }

//   // Search messages in current month
//   Future<List<ChatMessage>> searchMessages(String query,
//       {int limit = 20}) async {
//     try {
//       final monthDoc = _getCurrentMonthDocument();
//       final querySnapshot = await monthDoc
//           .collection(_messagesSubcollection)
//           .where('content', isGreaterThanOrEqualTo: query)
//           .where('content', isLessThan: query + '\uf8ff')
//           .orderBy('content')
//           .orderBy('timestamp', descending: true)
//           .limit(limit)
//           .get();

//       return querySnapshot.docs
//           .map((doc) => ChatMessage.fromFirestore(doc))
//           .toList();
//     } catch (e) {
//       print('ChatService: Error searching messages: $e');
//       return [];
//     }
//   }

//   // Update user online status
//   Future<void> updateUserStatus(String userId, bool isOnline) async {
//     try {
//       await _firestore.collection(_userStatusCollection).doc(userId).set({
//         'isOnline': isOnline,
//         'lastSeen': FieldValue.serverTimestamp(),
//       }, SetOptions(merge: true));
//     } catch (e) {
//       print('ChatService: Error updating user status: $e');
//     }
//   }

//   // Stream of online users (considers lastSeen timestamp)
//   Stream<List<String>> getOnlineUsersStream() {
//     return _firestore
//         .collection(_userStatusCollection)
//         .snapshots()
//         .map((snapshot) {
//       final now = DateTime.now();
//       final onlineThreshold = now.subtract(const Duration(minutes: 5)); // 5 minutes threshold
      
//       return snapshot.docs.where((doc) {
//         final data = doc.data() as Map<String, dynamic>?;
//         if (data == null) return false;
        
//         final isOnline = data['isOnline'] == true;
//         final lastSeen = data['lastSeen'] as Timestamp?;
        
//         if (!isOnline || lastSeen == null) return false;
        
//         // Check if lastSeen is within the threshold
//         return lastSeen.toDate().isAfter(onlineThreshold);
//       }).map((doc) => doc.id).toList();
//     });
//   }

//   // Clean up stale online statuses
//   Future<void> cleanupStaleOnlineStatuses() async {
//     try {
//       final now = DateTime.now();
//       final staleThreshold = now.subtract(const Duration(minutes: 10)); // 10 minutes threshold
      
//       final staleUsers = await _firestore
//           .collection(_userStatusCollection)
//           .where('isOnline', isEqualTo: true)
//           .where('lastSeen', isLessThan: Timestamp.fromDate(staleThreshold))
//           .get();
          
//       final batch = _firestore.batch();
      
//       for (var doc in staleUsers.docs) {
//         batch.update(doc.reference, {'isOnline': false});
//       }
      
//       if (staleUsers.docs.isNotEmpty) {
//         await batch.commit();
//         print('ChatService: Cleaned up ${staleUsers.docs.length} stale online statuses');
//       }
//     } catch (e) {
//       print('ChatService: Error cleaning up stale online statuses: $e');
//     }
//   }

//   // Update user status with heartbeat
//   Future<void> updateUserHeartbeat(String userId) async {
//     try {
//       await _firestore.collection(_userStatusCollection).doc(userId).set({
//         'isOnline': true,
//         'lastSeen': FieldValue.serverTimestamp(),
//       }, SetOptions(merge: true));
//     } catch (e) {
//       print('ChatService: Error updating user heartbeat: $e');
//     }
//   }

//   // Clean up old messages (older than specified days)
//   Future<void> cleanupOldMessages({int daysOld = 30}) async {
//     try {
//       final cutoffDate = DateTime.now().subtract(Duration(days: daysOld));

//       // This would require more complex logic to clean up entire months
//       // For now, we'll just clean up messages older than cutoff in current month
//       final monthDoc = _getCurrentMonthDocument();
//       final oldMessages = await monthDoc
//           .collection(_messagesSubcollection)
//           .where('timestamp', isLessThan: cutoffDate)
//           .get();

//       final batch = _firestore.batch();
//       for (var doc in oldMessages.docs) {
//         batch.delete(doc.reference);
//       }
//       await batch.commit();

//       print('ChatService: Cleaned up ${oldMessages.docs.length} old messages');
//     } catch (e) {
//       print('ChatService: Error cleaning up old messages: $e');
//     }
//   }

//   // Get chat statistics
//   Future<Map<String, dynamic>> getChatStatistics() async {
//     try {
//       final monthDoc = _getCurrentMonthDocument();
//       final messagesSnapshot =
//           await monthDoc.collection(_messagesSubcollection).get();
//       final userStatusSnapshot =
//           await _firestore.collection(_userStatusCollection).get();

//       final messageCount = messagesSnapshot.docs.length;
//       final onlineUsers = userStatusSnapshot.docs
//           .where((doc) => doc.data()['isOnline'] == true)
//           .length;

//       // Count messages by type
//       final messageCounts = <String, int>{};
//       for (var doc in messagesSnapshot.docs) {
//         final data = doc.data();
//         final type = data['type'] ?? 'text';
//         messageCounts[type] = (messageCounts[type] ?? 0) + 1;
//       }

//       return {
//         'totalMessages': messageCount,
//         'onlineUsers': onlineUsers,
//         'totalUsers': userStatusSnapshot.docs.length,
//         'messagesByType': messageCounts,
//         'currentMonth': _getMonthDocumentId(DateTime.now()),
//       };
//     } catch (e) {
//       print('ChatService: Error getting chat statistics: $e');
//       return {};
//     }
//   }

//   // Search users for mentions
//   Future<List<Map<String, String>>> searchUsers(String query) async {
//     try {
//       // For now, get all users from user_status collection
//       // In a real app, you'd have a dedicated users collection
//       final userStatusSnapshot = await _firestore
//           .collection(_userStatusCollection)
//           .limit(20)
//           .get();

//       List<Map<String, String>> users = [];
      
//       for (var doc in userStatusSnapshot.docs) {
//         final data = doc.data();
//         final displayName = data['displayName'] ?? data['email'] ?? 'User';
        
//         // Filter by query if provided
//         if (query.isEmpty || displayName.toLowerCase().contains(query.toLowerCase())) {
//           users.add({
//             'id': doc.id,
//             'displayName': displayName,
//             'photoUrl': data['photoUrl'] ?? '',
//           });
//         }
//       }

//       return users;
//     } catch (e) {
//       print('ChatService: Error searching users: $e');
//       return [];
//     }
//   }

//   // Parse mentions from message content
//   static List<String> parseMentions(String content) {
//     final mentionRegex = RegExp(r'@\[([^\]]+)\]\(([^)]+)\)');
//     final matches = mentionRegex.allMatches(content);
//     return matches.map((match) => match.group(2)!).toList();
//   }

//   // Format content with mentions for display
//   static String formatMentionsForDisplay(String content) {
//     final mentionRegex = RegExp(r'@\[([^\]]+)\]\(([^)]+)\)');
//     return content.replaceAllMapped(mentionRegex, (match) {
//       return '@${match.group(1)}'; // Just show @username
//     });
//   }
// }
