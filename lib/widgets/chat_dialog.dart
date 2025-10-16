import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'dart:typed_data';
import '../models/chat_message.dart';
import '../providers/chat_provider.dart';
import '../providers/auth_provider.dart';

class ChatDialog extends StatefulWidget {
  const ChatDialog({super.key});

  @override
  State<ChatDialog> createState() => _ChatDialogState();
}

class _ChatDialogState extends State<ChatDialog> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  String? _replyToMessageId;
  ChatMessage? _replyToMessage;

  // Mention functionality
  bool _showMentionDropdown = false;
  List<Map<String, String>> _mentionSuggestions = [];
  String _currentMentionQuery = '';
  int _mentionStartIndex = -1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToBottom();
      _markAllMessagesAsRead();
    });
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  String _getDateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final messageDate = DateTime(date.year, date.month, date.day);

    if (messageDate == today) {
      return 'Today';
    } else if (messageDate == yesterday) {
      return 'Yesterday';
    } else if (now.difference(messageDate).inDays < 7) {
      // Show day of week for this week
      const weekdays = [
        'Monday',
        'Tuesday',
        'Wednesday',
        'Thursday',
        'Friday',
        'Saturday',
        'Sunday'
      ];
      return weekdays[messageDate.weekday - 1];
    } else if (messageDate.year == now.year) {
      // Show month and day for this year
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      return '${months[messageDate.month - 1]} ${messageDate.day}';
    } else {
      // Show full date for other years
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec'
      ];
      return '${months[messageDate.month - 1]} ${messageDate.day}, ${messageDate.year}';
    }
  }

  Widget _buildDateHeader(String dateLabel) {
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.grey[200],
            borderRadius: BorderRadius.circular(16),
          ),
          child: Text(
            dateLabel,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: Colors.grey[700],
            ),
          ),
        ),
      ),
    );
  }

  List<Widget> _buildChatItems(
      List<ChatMessage> messages, ChatProvider chatProvider) {
    if (messages.isEmpty) return [];

    List<Widget> items = [];
    String? lastDateLabel;

    for (int i = 0; i < messages.length; i++) {
      final message = messages[i];
      final dateLabel = _getDateLabel(message.timestamp);

      // Add date header if the date has changed
      if (lastDateLabel != dateLabel) {
        items.add(_buildDateHeader(dateLabel));
        lastDateLabel = dateLabel;
      }

      // Add the message
      items.add(MessageBubble(
        message: message,
        onReply: () => _setReply(message),
        onDelete: () => chatProvider.deleteMessage(message.id),
      ));
    }

    return items;
  }

  void _markAllMessagesAsRead() {
    final chatProvider = context.read<ChatProvider>();
    chatProvider.markAllMessagesAsRead();
  }

  void _sendMessage() {
    final content = _messageController.text.trim();
    if (content.isEmpty) return;

    final chatProvider = context.read<ChatProvider>();
    chatProvider.sendMessage(content, replyToMessageId: _replyToMessageId);

    _messageController.clear();
    _clearReply();
    _scrollToBottom();
  }

  void _setReply(ChatMessage message) {
    setState(() {
      _replyToMessageId = message.id;
      _replyToMessage = message;
    });
    _messageFocusNode.requestFocus();
  }

  void _clearReply() {
    setState(() {
      _replyToMessageId = null;
      _replyToMessage = null;
    });
  }

  Future<void> _pickImage() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1080,
        imageQuality: 85,
      );

      if (image != null) {
        final Uint8List imageData = await image.readAsBytes();
        final String fileName = image.name;

        final chatProvider = context.read<ChatProvider>();
        await chatProvider.sendImageMessage(
          imageData,
          fileName,
          replyToMessageId: _replyToMessageId,
        );

        _clearReply();
        _scrollToBottom();
      }
    } catch (e) {
      print('Error picking image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to pick image: $e')),
        );
      }
    }
  }

  // Handle text changes for mention detection
  void _onTextChanged(String text) {
    final cursorPosition = _messageController.selection.baseOffset;

    // Check if user typed '@'
    if (cursorPosition > 0 && text[cursorPosition - 1] == '@') {
      _mentionStartIndex = cursorPosition - 1;
      _currentMentionQuery = '';
      _showMentionDropdown = true;
      _searchUsers('');
    } else if (_showMentionDropdown && _mentionStartIndex >= 0) {
      // Update mention query
      final mentionEnd = cursorPosition;
      if (mentionEnd > _mentionStartIndex + 1) {
        _currentMentionQuery =
            text.substring(_mentionStartIndex + 1, mentionEnd);
        _searchUsers(_currentMentionQuery);
      } else {
        _hideMentionDropdown();
      }
    } else {
      _hideMentionDropdown();
    }

    setState(() {});
  }

  // Search for users to mention
  Future<void> _searchUsers(String query) async {
    try {
      print('ChatDialog: Searching for users with query: "$query"');
      final chatProvider = context.read<ChatProvider>();
      final users = await chatProvider.searchUsers(query);
      print('ChatDialog: Got ${users.length} users from search');
      setState(() {
        _mentionSuggestions = users;
      });
      print(
          'ChatDialog: Updated _mentionSuggestions with ${_mentionSuggestions.length} users');
    } catch (e) {
      print('Error searching users: $e');
    }
  }

  // Insert mention into text
  void _insertMention(Map<String, String> user) {
    final text = _messageController.text;
    final cursorPosition = _messageController.selection.baseOffset;

    // Create mention text: @[DisplayName](userId)
    final mentionText = '@[${user['displayName']}](${user['id']})';

    // Replace from @ to cursor position
    final beforeMention = text.substring(0, _mentionStartIndex);
    final afterMention = text.substring(cursorPosition);
    final newText = beforeMention + mentionText + afterMention;

    _messageController.text = newText;
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: beforeMention.length + mentionText.length),
    );

    _hideMentionDropdown();
  }

  // Hide mention dropdown
  void _hideMentionDropdown() {
    setState(() {
      _showMentionDropdown = false;
      _mentionSuggestions = [];
      _currentMentionQuery = '';
      _mentionStartIndex = -1;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 600,
        height: 700,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).colorScheme.surface,
        ),
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.chat,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Team Chat',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: Theme.of(context).colorScheme.onPrimary,
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                  const Spacer(),
                  Consumer<ChatProvider>(
                    builder: (context, chatProvider, child) {
                      final onlineCount = chatProvider.onlineUsers.length;
                      return Row(
                        children: [
                          Icon(
                            Icons.circle,
                            size: 8,
                            color: Colors.green,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '$onlineCount online',
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onPrimary,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: Theme.of(context).colorScheme.onPrimary,
                    ),
                  ),
                ],
              ),
            ),

            // Messages List
            Expanded(
              child: Consumer<ChatProvider>(
                builder: (context, chatProvider, child) {
                  if (chatProvider.isLoading) {
                    return const Center(
                      child: CircularProgressIndicator(),
                    );
                  }

                  if (chatProvider.error != null) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 48,
                            color: Colors.red,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Error loading messages',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            chatProvider.error!,
                            style: Theme.of(context).textTheme.bodyMedium,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: () {
                              chatProvider.clearError();
                              chatProvider.refreshMessages();
                            },
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    );
                  }

                  if (chatProvider.messages.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.chat_bubble_outline,
                            size: 64,
                            color: Colors.grey,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No messages yet',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'Start the conversation!',
                            style: Theme.of(context).textTheme.bodyMedium,
                          ),
                        ],
                      ),
                    );
                  }

                  final chatItems =
                      _buildChatItems(chatProvider.messages, chatProvider);
                  return ListView(
                    controller: _scrollController,
                    padding: const EdgeInsets.all(16),
                    children: chatItems,
                  );
                },
              ),
            ),

            // Reply Preview
            if (_replyToMessage != null)
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  border: Border(
                    top: BorderSide(color: Colors.grey[300]!),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.reply, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Replying to ${_replyToMessage!.senderName}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey[600],
                            ),
                          ),
                          Text(
                            _replyToMessage!.content,
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey[600],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      onPressed: _clearReply,
                      icon: Icon(Icons.close, size: 16),
                      constraints:
                          const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ),
              ),

            // Message Input
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.grey[300]!),
                ),
              ),
              child: Row(
                children: [
                  FloatingActionButton(
                    onPressed: _pickImage,
                    mini: true,
                    backgroundColor: Colors.grey[100],
                    child: const Icon(Icons.image, color: Colors.grey),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      children: [
                        // Mention dropdown
                        if (_showMentionDropdown &&
                            _mentionSuggestions.isNotEmpty)
                          Container(
                            constraints: const BoxConstraints(maxHeight: 150),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: [
                                BoxShadow(
                                  color: Colors.grey.withOpacity(0.3),
                                  blurRadius: 8,
                                  offset: const Offset(0, -2),
                                ),
                              ],
                            ),
                            child: ListView.builder(
                              shrinkWrap: true,
                              itemCount: _mentionSuggestions.length,
                              itemBuilder: (context, index) {
                                final user = _mentionSuggestions[index];
                                return ListTile(
                                  dense: true,
                                  leading: CircleAvatar(
                                    radius: 16,
                                    backgroundImage:
                                        user['photoUrl']!.isNotEmpty
                                            ? NetworkImage(user['photoUrl']!)
                                            : null,
                                    child: user['photoUrl']!.isEmpty
                                        ? Text(
                                            user['displayName']!.isNotEmpty
                                                ? user['displayName']![0]
                                                    .toUpperCase()
                                                : '?',
                                            style:
                                                const TextStyle(fontSize: 12),
                                          )
                                        : null,
                                  ),
                                  title: Text(
                                    user['displayName']!,
                                    style: const TextStyle(fontSize: 14),
                                  ),
                                  onTap: () => _insertMention(user),
                                );
                              },
                            ),
                          ),
                        TextField(
                          controller: _messageController,
                          focusNode: _messageFocusNode,
                          decoration: InputDecoration(
                            hintText: 'Type a message...',
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                          ),
                          textInputAction: TextInputAction.send,
                          onChanged: _onTextChanged,
                          onSubmitted: (_) => _sendMessage(),
                          maxLines: null,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Consumer<ChatProvider>(
                    builder: (context, chatProvider, child) {
                      return FloatingActionButton(
                        onPressed: chatProvider.isSending ? null : _sendMessage,
                        mini: true,
                        child: chatProvider.isSending
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.send),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class MessageBubble extends StatelessWidget {
  final ChatMessage message;
  final VoidCallback? onReply;
  final VoidCallback? onDelete;

  const MessageBubble({
    super.key,
    required this.message,
    this.onReply,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    final currentUser = authProvider.user;
    final isOwnMessage = currentUser?.uid == message.senderId;
    final isSystem = message.isSystem;

    if (isSystem) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.grey[200],
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              message.content,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onLongPress: () => _showMessageOptions(context),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment:
              isOwnMessage ? MainAxisAlignment.end : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!isOwnMessage) ...[
              CircleAvatar(
                radius: 16,
                backgroundImage: message.senderPhotoUrl != null
                    ? NetworkImage(message.senderPhotoUrl!)
                    : null,
                child: message.senderPhotoUrl == null
                    ? Text(
                        message.senderName.isNotEmpty
                            ? message.senderName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(fontSize: 12),
                      )
                    : null,
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Container(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.7,
                ),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isOwnMessage
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey[200],
                  borderRadius: BorderRadius.circular(16).copyWith(
                    bottomLeft: isOwnMessage
                        ? const Radius.circular(16)
                        : const Radius.circular(4),
                    bottomRight: isOwnMessage
                        ? const Radius.circular(4)
                        : const Radius.circular(16),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (!isOwnMessage)
                      Text(
                        message.senderName,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    if (message.hasReply) ...[
                      Container(
                        padding: const EdgeInsets.all(8),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Replying to message...', // In a real app, you'd fetch the original message
                          style: TextStyle(
                            fontSize: 11,
                            fontStyle: FontStyle.italic,
                            color: isOwnMessage
                                ? Colors.white70
                                : Colors.grey[600],
                          ),
                        ),
                      ),
                    ],
                    _buildMessageContent(context, isOwnMessage),
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _formatTime(message.timestamp),
                          style: TextStyle(
                            fontSize: 10,
                            color: isOwnMessage
                                ? Colors.white70
                                : Colors.grey[600],
                          ),
                        ),
                        if (message.metadata?['edited'] == true) ...[
                          const SizedBox(width: 4),
                          Text(
                            'edited',
                            style: TextStyle(
                              fontSize: 10,
                              fontStyle: FontStyle.italic,
                              color: isOwnMessage
                                  ? Colors.white70
                                  : Colors.grey[600],
                            ),
                          ),
                        ],
                        if (isOwnMessage) ...[
                          const SizedBox(width: 4),
                          _buildReadStatusIcon(currentUser?.uid ?? ''),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
            if (isOwnMessage) ...[
              const SizedBox(width: 8),
              CircleAvatar(
                radius: 16,
                backgroundImage: message.senderPhotoUrl != null
                    ? NetworkImage(message.senderPhotoUrl!)
                    : null,
                child: message.senderPhotoUrl == null
                    ? Text(
                        message.senderName.isNotEmpty
                            ? message.senderName[0].toUpperCase()
                            : '?',
                        style: const TextStyle(fontSize: 12),
                      )
                    : null,
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMessageContent(BuildContext context, bool isOwnMessage) {
    if (message.isImage) {
      return GestureDetector(
        onTap: () => _showFullImage(context),
        child: Container(
          constraints: const BoxConstraints(
            maxWidth: 200,
            maxHeight: 200,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isOwnMessage ? Colors.white30 : Colors.grey[300]!,
              width: 1,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.network(
              message.content,
              fit: BoxFit.cover,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                );
              },
              errorBuilder: (context, error, stackTrace) {
                print('Image loading error: $error');
                return Container(
                  width: 200,
                  height: 200,
                  decoration: BoxDecoration(
                    color: Colors.grey[200],
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.broken_image,
                          color: Colors.red, size: 32),
                      const SizedBox(height: 8),
                      Text(
                        'Image failed to load',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.grey[600],
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      );
    } else {
      return _buildTextWithMentions(context, isOwnMessage);
    }
  }

  Widget _buildTextWithMentions(BuildContext context, bool isOwnMessage) {
    final text = message.content;
    final mentionRegex = RegExp(r'@\[([^\]]+)\]\(([^)]+)\)');
    final matches = mentionRegex.allMatches(text).toList();

    if (matches.isEmpty) {
      // No mentions, show regular text
      return Text(
        text,
        style: TextStyle(
          color: isOwnMessage
              ? Theme.of(context).colorScheme.onPrimary
              : Colors.black87,
        ),
      );
    }

    // Build RichText with mentions
    List<TextSpan> spans = [];
    int lastEnd = 0;

    for (final match in matches) {
      // Add text before mention
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: text.substring(lastEnd, match.start),
          style: TextStyle(
            color: isOwnMessage
                ? Theme.of(context).colorScheme.onPrimary
                : Colors.black87,
          ),
        ));
      }

      // Add mention with italic style
      spans.add(TextSpan(
        text: '@${match.group(1)}',
        style: TextStyle(
          color: isOwnMessage
              ? Theme.of(context).colorScheme.onPrimary
              : Colors.black87,
          fontStyle: FontStyle.italic,
          fontWeight: FontWeight.w500,
        ),
      ));

      lastEnd = match.end;
    }

    // Add remaining text
    if (lastEnd < text.length) {
      spans.add(TextSpan(
        text: text.substring(lastEnd),
        style: TextStyle(
          color: isOwnMessage
              ? Theme.of(context).colorScheme.onPrimary
              : Colors.black87,
        ),
      ));
    }

    return RichText(
      text: TextSpan(children: spans),
    );
  }

  void _showFullImage(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: InteractiveViewer(
            child: Image.network(
              message.content,
              fit: BoxFit.contain,
              errorBuilder: (context, error, stackTrace) {
                return Container(
                  width: double.infinity,
                  height: 300,
                  color: Colors.grey[200],
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.broken_image, color: Colors.red, size: 64),
                      SizedBox(height: 16),
                      Text(
                        'Failed to load full-size image',
                        style: TextStyle(color: Colors.red),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildReadStatusIcon(String currentUserId) {
    final readStatus = message.getReadStatus(currentUserId);

    switch (readStatus) {
      case MessageReadStatus.sent:
        return Icon(
          Icons.done,
          size: 12,
          color: Colors.white70,
        );
      case MessageReadStatus.delivered:
        return Icon(
          Icons.done_all,
          size: 12,
          color: Colors.white70,
        );
      case MessageReadStatus.readByAll:
        return Icon(
          Icons.done_all,
          size: 12,
          color: Colors.blue[200],
        );
      case MessageReadStatus.none:
        return const SizedBox.shrink();
    }
  }

  void _showMessageOptions(BuildContext context) {
    final authProvider = context.read<AuthProvider>();
    final currentUser = authProvider.user;
    final isOwnMessage = currentUser?.uid == message.senderId;

    showModalBottomSheet(
      context: context,
      builder: (context) => Container(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (onReply != null)
              ListTile(
                leading: const Icon(Icons.reply),
                title: const Text('Reply'),
                onTap: () {
                  Navigator.pop(context);
                  onReply!();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy'),
              onTap: () {
                Navigator.pop(context);
                // Copy to clipboard functionality would go here
              },
            ),
            if (isOwnMessage && onDelete != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title:
                    const Text('Delete', style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteConfirmation(context);
                },
              ),
          ],
        ),
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Message'),
        content: const Text('Are you sure you want to delete this message?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              onDelete?.call();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime timestamp) {
    final now = DateTime.now();
    final difference = now.difference(timestamp);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}
