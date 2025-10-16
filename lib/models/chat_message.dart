import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

enum MessageType {
  text,
  image,
  file,
  system,
}

enum MessageReadStatus {
  none, // Not sender's message or status not applicable
  sent, // Message sent (single tick)
  delivered, // Message delivered to some users (double tick)
  readByAll, // Message read by multiple users (double tick, blue)
}

extension MessageTypeExtension on MessageType {
  String get value {
    switch (this) {
      case MessageType.text:
        return 'text';
      case MessageType.image:
        return 'image';
      case MessageType.file:
        return 'file';
      case MessageType.system:
        return 'system';
    }
  }

  static MessageType fromValue(String value) {
    switch (value) {
      case 'text':
        return MessageType.text;
      case 'image':
        return MessageType.image;
      case 'file':
        return MessageType.file;
      case 'system':
        return MessageType.system;
      default:
        return MessageType.text;
    }
  }
}

class ChatMessage {
  final String id;
  final String senderId;
  final String senderName;
  final String? senderPhotoUrl;
  final String content;
  final MessageType type;
  final DateTime timestamp;
  final bool isRead;
  final List<String> readBy;
  final String? replyToMessageId;
  final Map<String, dynamic>? metadata;
  final List<String> mentions; // List of mentioned user IDs

  const ChatMessage({
    required this.id,
    required this.senderId,
    required this.senderName,
    this.senderPhotoUrl,
    required this.content,
    this.type = MessageType.text,
    required this.timestamp,
    this.isRead = false,
    this.readBy = const [],
    this.replyToMessageId,
    this.metadata,
    this.mentions = const [],
  });

  ChatMessage copyWith({
    String? id,
    String? senderId,
    String? senderName,
    String? senderPhotoUrl,
    String? content,
    MessageType? type,
    DateTime? timestamp,
    bool? isRead,
    List<String>? readBy,
    String? replyToMessageId,
    Map<String, dynamic>? metadata,
    List<String>? mentions,
  }) {
    return ChatMessage(
      id: id ?? this.id,
      senderId: senderId ?? this.senderId,
      senderName: senderName ?? this.senderName,
      senderPhotoUrl: senderPhotoUrl ?? this.senderPhotoUrl,
      content: content ?? this.content,
      type: type ?? this.type,
      timestamp: timestamp ?? this.timestamp,
      isRead: isRead ?? this.isRead,
      readBy: readBy ?? this.readBy,
      replyToMessageId: replyToMessageId ?? this.replyToMessageId,
      metadata: metadata ?? this.metadata,
      mentions: mentions ?? this.mentions,
    );
  }

  factory ChatMessage.fromFirestore(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    return ChatMessage(
      id: doc.id,
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? 'Unknown User',
      senderPhotoUrl: data['senderPhotoUrl'],
      content: data['content'] ?? '',
      type: MessageTypeExtension.fromValue(data['type'] ?? 'text'),
      timestamp: (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now(),
      isRead: data['isRead'] ?? false,
      readBy: List<String>.from(data['readBy'] ?? []),
      replyToMessageId: data['replyToMessageId'],
      metadata: data['metadata'],
      mentions: List<String>.from(data['mentions'] ?? []),
    );
  }

  factory ChatMessage.fromMap(Map<String, dynamic> data) {
    return ChatMessage(
      id: data['id'] ?? '',
      senderId: data['senderId'] ?? '',
      senderName: data['senderName'] ?? 'Unknown User',
      senderPhotoUrl: data['senderPhotoUrl'],
      content: data['content'] ?? '',
      type: MessageTypeExtension.fromValue(data['type'] ?? 'text'),
      timestamp: data['timestamp'] is Timestamp
          ? (data['timestamp'] as Timestamp).toDate()
          : DateTime.parse(
              data['timestamp'] ?? DateTime.now().toIso8601String()),
      isRead: data['isRead'] ?? false,
      readBy: List<String>.from(data['readBy'] ?? []),
      replyToMessageId: data['replyToMessageId'],
      metadata: data['metadata'],
      mentions: List<String>.from(data['mentions'] ?? []),
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'senderId': senderId,
      'senderName': senderName,
      'senderPhotoUrl': senderPhotoUrl,
      'content': content,
      'type': type.value,
      'timestamp': Timestamp.fromDate(timestamp),
      'isRead': isRead,
      'readBy': readBy,
      'replyToMessageId': replyToMessageId,
      'metadata': metadata,
      'mentions': mentions,
    };
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'senderId': senderId,
      'senderName': senderName,
      'senderPhotoUrl': senderPhotoUrl,
      'content': content,
      'type': type.value,
      'timestamp': timestamp.toIso8601String(),
      'isRead': isRead,
      'readBy': readBy,
      'replyToMessageId': replyToMessageId,
      'metadata': metadata,
      'mentions': mentions,
    };
  }

  bool get isSystem => type == MessageType.system;
  bool get isText => type == MessageType.text;
  bool get isImage => type == MessageType.image;
  bool get isFile => type == MessageType.file;
  bool get hasReply => replyToMessageId != null;
  bool get hasMentions => mentions.isNotEmpty;

  // Read receipt status helpers
  bool get isSent => true; // Message exists, so it's sent
  bool get isDelivered => readBy.isNotEmpty;
  bool get isReadByAll => readBy.length > 1; // More than just sender

  // Get read status for UI display
  MessageReadStatus getReadStatus(String currentUserId) {
    if (senderId != currentUserId) {
      return MessageReadStatus.none; // Not sender's message
    }

    if (readBy.length <= 1) {
      return MessageReadStatus.sent; // Only sender has read it
    } else if (readBy.length == 2) {
      return MessageReadStatus.delivered; // One other person read it
    } else {
      return MessageReadStatus.readByAll; // Multiple people read it
    }
  }

  Color getMessageColor(bool isDark) {
    if (isSystem) {
      return isDark ? Colors.grey[800]! : Colors.grey[200]!;
    }
    return isDark ? Colors.blue[800]! : Colors.blue[100]!;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is ChatMessage &&
        other.id == id &&
        other.senderId == senderId &&
        other.content == content &&
        other.timestamp == timestamp;
  }

  @override
  int get hashCode {
    return id.hashCode ^
        senderId.hashCode ^
        content.hashCode ^
        timestamp.hashCode;
  }

  @override
  String toString() {
    return 'ChatMessage(id: $id, senderId: $senderId, senderName: $senderName, content: $content, type: $type, timestamp: $timestamp)';
  }
}
