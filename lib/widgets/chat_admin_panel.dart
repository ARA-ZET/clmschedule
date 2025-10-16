import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/chat_provider.dart';
import '../providers/auth_provider.dart';

class ChatAdminPanel extends StatefulWidget {
  const ChatAdminPanel({super.key});

  @override
  State<ChatAdminPanel> createState() => _ChatAdminPanelState();
}

class _ChatAdminPanelState extends State<ChatAdminPanel> {
  final TextEditingController _systemMessageController =
      TextEditingController();
  Map<String, dynamic>? _statistics;
  bool _isLoadingStats = false;

  @override
  void initState() {
    super.initState();
    _loadStatistics();
  }

  @override
  void dispose() {
    _systemMessageController.dispose();
    super.dispose();
  }

  Future<void> _loadStatistics() async {
    setState(() {
      _isLoadingStats = true;
    });

    final chatProvider = context.read<ChatProvider>();
    final stats = await chatProvider.getChatStatistics();

    setState(() {
      _statistics = stats;
      _isLoadingStats = false;
    });
  }

  void _sendSystemMessage() {
    final content = _systemMessageController.text.trim();
    if (content.isEmpty) return;

    final chatProvider = context.read<ChatProvider>();
    chatProvider.sendSystemMessage(content);
    _systemMessageController.clear();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('System message sent')),
    );
  }

  void _cleanupOldMessages() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Cleanup Old Messages'),
        content: const Text(
          'This will delete messages older than 30 days. This action cannot be undone. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              final chatProvider = context.read<ChatProvider>();
              chatProvider.cleanupOldMessages();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Old messages cleanup initiated')),
              );
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authProvider = context.read<AuthProvider>();

    if (!authProvider.isAdmin) {
      return const Center(
        child: Text('Access denied. Admin privileges required.'),
      );
    }

    return Dialog(
      child: Container(
        width: 500,
        height: 600,
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.admin_panel_settings, size: 28),
                const SizedBox(width: 12),
                Text(
                  'Chat Administration',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const Spacer(),
                IconButton(
                  onPressed: () => Navigator.pop(context),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 24),

            // Statistics Section
            Text(
              'Chat Statistics',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),

            if (_isLoadingStats)
              const Center(child: CircularProgressIndicator())
            else if (_statistics != null)
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Column(
                  children: [
                    _buildStatRow('Total Messages',
                        '${_statistics!['totalMessages'] ?? 0}'),
                    _buildStatRow(
                        'Total Users', '${_statistics!['totalUsers'] ?? 0}'),
                    _buildStatRow(
                        'Online Users', '${_statistics!['onlineUsers'] ?? 0}'),
                    _buildStatRow('Messages This Week',
                        '${_statistics!['messagesLastWeek'] ?? 0}'),
                  ],
                ),
              ),

            const SizedBox(height: 24),

            // System Message Section
            Text(
              'Send System Message',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _systemMessageController,
              decoration: const InputDecoration(
                hintText: 'Enter system announcement...',
                border: OutlineInputBorder(),
              ),
              maxLines: 3,
            ),
            const SizedBox(height: 12),
            Consumer<ChatProvider>(
              builder: (context, chatProvider, child) {
                return ElevatedButton.icon(
                  onPressed: chatProvider.isSending ? null : _sendSystemMessage,
                  icon: chatProvider.isSending
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send),
                  label: const Text('Send System Message'),
                );
              },
            ),

            const SizedBox(height: 24),

            // Maintenance Section
            Text(
              'Maintenance',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _loadStatistics,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Refresh Stats'),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _cleanupOldMessages,
                  icon: const Icon(Icons.delete_sweep),
                  label: const Text('Cleanup Old Messages'),
                  style: ElevatedButton.styleFrom(
                    foregroundColor: Colors.red,
                  ),
                ),
              ],
            ),

            const Spacer(),

            if (context.watch<ChatProvider>().error != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.red[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error, color: Colors.red),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        context.watch<ChatProvider>().error!,
                        style: TextStyle(color: Colors.red[700]),
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          context.read<ChatProvider>().clearError(),
                      icon: Icon(Icons.close, color: Colors.red),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            value,
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
        ],
      ),
    );
  }
}
