import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import 'package:url_launcher/url_launcher.dart';
import '../providers/ai_chat_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/job_list_provider.dart';
import '../services/ai_chat_service.dart';

/// Side panel widget for AI chat — sits alongside the main content.
class AiChatPanel extends riverpod.ConsumerStatefulWidget {
  final VoidCallback onClose;

  const AiChatPanel({super.key, required this.onClose});

  @override
  riverpod.ConsumerState<AiChatPanel> createState() => _AiChatPanelState();
}

class _AiChatPanelState extends riverpod.ConsumerState<AiChatPanel>
    with SingleTickerProviderStateMixin {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _messageFocusNode = FocusNode();
  late AnimationController _typingAnimController;

  @override
  void initState() {
    super.initState();
    _typingAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final authProvider = ref.read(authRiverpod);
      final aiChatProvider = ref.read(aiChatRiverpod);
      final userName = authProvider.appUser?.name ?? 'User';
      aiChatProvider.initialize(userName);
      _syncDataContext();
      _scrollToBottom();
    });
  }

  /// Sync the current month from JobListProvider into AiChatProvider
  void _syncDataContext() {
    final aiChatProvider = ref.read(aiChatRiverpod);
    final jobListProvider = ref.read(jobListRiverpod);
    final monthId = jobListProvider.currentMonthDisplay;
    aiChatProvider.updateDataContext(monthId: monthId);
  }

  @override
  void dispose() {
    _messageController.dispose();
    _scrollController.dispose();
    _messageFocusNode.dispose();
    _typingAnimController.dispose();
    super.dispose();
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.animateTo(
            _scrollController.position.maxScrollExtent,
            duration: const Duration(milliseconds: 300),
            curve: Curves.easeOut,
          );
        }
      });
    }
  }

  Future<void> _sendMessage() async {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;

    _messageController.clear();
    final provider = ref.read(aiChatRiverpod);
    await provider.sendMessage(text);
    _scrollToBottom();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        border: Border(
          left: BorderSide(color: Colors.grey.shade300, width: 1),
        ),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(child: _buildMessageList()),
          _buildInputArea(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.deepPurple.shade700, Colors.deepPurple.shade500],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.white.withValues(alpha: 0.25),
                  Colors.white.withValues(alpha: 0.10),
                ],
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child:
                const Icon(Icons.auto_awesome, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Pelisa',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.3,
                  ),
                ),
                riverpod.Consumer(
                  builder: (context, ref, _) {
                    final provider = ref.watch(aiChatRiverpod);
                    final monthLabel = provider.currentMonthId;
                    final statusText = provider.isLoading
                        ? 'Thinking...'
                        : monthLabel != null
                            ? 'Synced: $monthLabel'
                            : 'CLM Assistant';
                    return Text(
                      statusText,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          riverpod.Consumer(
            builder: (context, ref, _) {
              return _HeaderIconButton(
                icon: Icons.psychology_rounded,
                onPressed: () => _showKnowledgeManager(context),
                tooltip: 'Teach Pelisa',
              );
            },
          ),
          const SizedBox(width: 4),
          riverpod.Consumer(
            builder: (context, ref, _) {
              final provider = ref.watch(aiChatRiverpod);
              return _HeaderIconButton(
                icon: Icons.sync_rounded,
                onPressed: () {
                  _syncDataContext();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(
                          'Data synced for ${provider.currentMonthId ?? 'current month'}'),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  );
                },
                tooltip: 'Sync schedule & job list data',
              );
            },
          ),
          const SizedBox(width: 4),
          riverpod.Consumer(
            builder: (context, ref, _) {
              final provider = ref.watch(aiChatRiverpod);
              return _HeaderIconButton(
                icon: Icons.refresh_rounded,
                onPressed: provider.clearConversation,
                tooltip: 'New conversation',
              );
            },
          ),
          const SizedBox(width: 4),
          _HeaderIconButton(
            icon: Icons.close_rounded,
            onPressed: widget.onClose,
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }

  Widget _buildMessageList() {
    return riverpod.Consumer(
      builder: (context, ref, _) {
        final provider = ref.watch(aiChatRiverpod);
        final messages = provider.messages;

        if (messages.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.chat_bubble_outline_rounded,
                    size: 40, color: Colors.grey.shade300),
                const SizedBox(height: 10),
                Text('Start a conversation...',
                    style:
                        TextStyle(color: Colors.grey.shade400, fontSize: 13)),
              ],
            ),
          );
        }

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scrollToBottom();
        });

        final showTyping = provider.isLoading && !provider.isStreaming;

        return ListView.builder(
          controller: _scrollController,
          padding: const EdgeInsets.fromLTRB(10, 12, 10, 6),
          itemCount: messages.length + (showTyping ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == messages.length && showTyping) {
              return _buildTypingIndicator();
            }
            final message = messages[index];
            final isFirst =
                index == 0 || messages[index - 1].role != message.role;
            return _buildMessageBubble(message,
                showAvatar: isFirst, messageIndex: index);
          },
        );
      },
    );
  }

  Widget _buildTypingIndicator() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _buildAssistantAvatar(),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(16),
                topRight: Radius.circular(16),
                bottomRight: Radius.circular(16),
                bottomLeft: Radius.circular(4),
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.05),
                  blurRadius: 4,
                  offset: const Offset(0, 1),
                ),
              ],
            ),
            child: AnimatedBuilder(
              animation: _typingAnimController,
              builder: (context, _) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(3, (i) {
                    final delay = i * 0.2;
                    final value = ((_typingAnimController.value + delay) % 1.0);
                    final opacity =
                        0.3 + 0.7 * (value < 0.5 ? value * 2 : (1 - value) * 2);
                    return Padding(
                      padding: EdgeInsets.only(right: i < 2 ? 4 : 0),
                      child: Opacity(
                        opacity: opacity,
                        child: Container(
                          width: 7,
                          height: 7,
                          decoration: BoxDecoration(
                            color: Colors.deepPurple.shade300,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssistantAvatar() {
    return Container(
      width: 26,
      height: 26,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [Colors.deepPurple.shade400, Colors.deepPurple.shade600],
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Icon(Icons.auto_awesome, size: 14, color: Colors.white),
    );
  }

  Widget _buildMessageBubble(AiChatMessage message,
      {bool showAvatar = true, required int messageIndex}) {
    final isUser = message.role == 'user';

    return Padding(
      padding: EdgeInsets.only(bottom: showAvatar ? 10 : 3),
      child: Row(
        mainAxisAlignment:
            isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            if (showAvatar)
              _buildAssistantAvatar()
            else
              const SizedBox(width: 26),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Column(
              crossAxisAlignment:
                  isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onLongPress: () {
                    Clipboard.setData(ClipboardData(text: message.content));
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: const Text('Message copied'),
                        duration: const Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    );
                  },
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isUser ? Colors.deepPurple.shade600 : Colors.white,
                      borderRadius: BorderRadius.only(
                        topLeft: const Radius.circular(16),
                        topRight: const Radius.circular(16),
                        bottomLeft: Radius.circular(isUser ? 16 : 4),
                        bottomRight: Radius.circular(isUser ? 4 : 16),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: isUser
                              ? Colors.deepPurple.shade200
                                  .withValues(alpha: 0.3)
                              : Colors.black.withValues(alpha: 0.05),
                          blurRadius: 4,
                          offset: const Offset(0, 1),
                        ),
                      ],
                    ),
                    child: isUser
                        ? SelectableText(
                            message.content,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              height: 1.4,
                            ),
                          )
                        : MarkdownBody(
                            data: message.content,
                            selectable: true,
                            onTapLink: (text, href, title) {
                              if (href != null) {
                                launchUrl(Uri.parse(href),
                                    mode: LaunchMode.externalApplication);
                              }
                            },
                            styleSheet: MarkdownStyleSheet(
                              p: TextStyle(
                                color: Colors.grey.shade800,
                                fontSize: 13,
                                height: 1.4,
                              ),
                              strong: TextStyle(
                                color: Colors.grey.shade900,
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                              ),
                              em: TextStyle(
                                color: Colors.grey.shade800,
                                fontSize: 13,
                                fontStyle: FontStyle.italic,
                              ),
                              a: TextStyle(
                                color: Colors.deepPurple.shade600,
                                fontSize: 13,
                                decoration: TextDecoration.underline,
                                decorationColor: Colors.deepPurple.shade300,
                              ),
                              code: TextStyle(
                                color: Colors.deepPurple.shade800,
                                fontSize: 12,
                                fontFamily: 'monospace',
                                backgroundColor: Colors.deepPurple.shade50,
                              ),
                              codeblockDecoration: BoxDecoration(
                                color: Colors.grey.shade100,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                    color: Colors.grey.shade300, width: 0.5),
                              ),
                              codeblockPadding: const EdgeInsets.all(10),
                              blockquoteDecoration: BoxDecoration(
                                border: Border(
                                  left: BorderSide(
                                      color: Colors.deepPurple.shade300,
                                      width: 3),
                                ),
                              ),
                              blockquotePadding: const EdgeInsets.only(
                                  left: 12, top: 4, bottom: 4),
                              listBullet: TextStyle(
                                color: Colors.grey.shade700,
                                fontSize: 13,
                              ),
                              tableHead: TextStyle(
                                color: Colors.grey.shade900,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                              tableBody: TextStyle(
                                color: Colors.grey.shade700,
                                fontSize: 12,
                              ),
                              tableBorder: TableBorder.all(
                                color: Colors.grey.shade300,
                                width: 0.5,
                              ),
                              tableHeadAlign: TextAlign.left,
                              tableCellsPadding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              h1: TextStyle(
                                color: Colors.grey.shade900,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                              h2: TextStyle(
                                color: Colors.grey.shade900,
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                              h3: TextStyle(
                                color: Colors.grey.shade900,
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                              horizontalRuleDecoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                      color: Colors.grey.shade300, width: 1),
                                ),
                              ),
                              pPadding: const EdgeInsets.only(bottom: 6),
                              h1Padding: const EdgeInsets.only(bottom: 8),
                              h2Padding: const EdgeInsets.only(bottom: 6),
                              h3Padding: const EdgeInsets.only(bottom: 4),
                              listIndent: 20,
                            ),
                          ),
                  ),
                ),
                if (message.action != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: _buildActionWidget(message.action!, messageIndex),
                  ),
                // Save-to-knowledge button for assistant messages (skip welcome)
                if (!isUser && messageIndex > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _SmallActionButton(
                          icon: Icons.lightbulb_outline_rounded,
                          tooltip: 'Save as knowledge',
                          onPressed: () => _showAddKnowledgeFromMessage(
                              context, message.content),
                        ),
                        const SizedBox(width: 4),
                        _SmallActionButton(
                          icon: Icons.content_copy_rounded,
                          tooltip: 'Copy',
                          onPressed: () {
                            Clipboard.setData(
                                ClipboardData(text: message.content));
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: const Text('Copied'),
                                duration: const Duration(seconds: 1),
                                behavior: SnackBarBehavior.floating,
                                shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(10)),
                              ),
                            );
                          },
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          if (isUser) const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _buildActionWidget(AiChatAction action, int messageIndex) {
    switch (action.type) {
      case 'jobPendingConfirmation':
        return _buildConfirmationCard(action, messageIndex);
      case 'jobAdded':
        return _buildStatusBadge(
          Icons.check_circle_rounded,
          'Job added to Job List',
          Colors.green.shade600,
        );
      case 'jobCancelled':
        return _buildStatusBadge(
          Icons.cancel_rounded,
          'Cancelled',
          Colors.grey.shade500,
        );
      case 'updatePendingConfirmation':
        return _buildUpdateConfirmationCard(action, messageIndex);
      case 'jobUpdated':
        return _buildStatusBadge(
          Icons.check_circle_rounded,
          'Job updated',
          Colors.blue.shade600,
        );
      case 'updateCancelled':
        return _buildStatusBadge(
          Icons.cancel_rounded,
          'Update cancelled',
          Colors.grey.shade500,
        );
      case 'multiJobPendingConfirmation':
        return _buildMultiJobConfirmationCard(action, messageIndex);
      case 'multiJobAdded':
        return _buildStatusBadge(
          Icons.check_circle_rounded,
          '${action.jobsData?.length ?? ''} Jobs added to Job List',
          Colors.green.shade600,
        );
      case 'multiJobCancelled':
        return _buildStatusBadge(
          Icons.cancel_rounded,
          'Cancelled',
          Colors.grey.shade500,
        );
      case 'schedulePendingConfirmation':
        return _buildScheduleConfirmationCard(action, messageIndex);
      case 'scheduleJobsAdded':
        return _buildStatusBadge(
          Icons.check_circle_rounded,
          '${action.scheduleJobsData?.length ?? ''} Jobs added to Schedule',
          Colors.green.shade600,
        );
      case 'scheduleJobsCancelled':
        return _buildStatusBadge(
          Icons.cancel_rounded,
          'Cancelled',
          Colors.grey.shade500,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  Widget _buildConfirmationCard(AiChatAction action, int messageIndex) {
    final jobData = action.jobData!;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pending_actions_rounded,
                  size: 14, color: Colors.orange.shade700),
              const SizedBox(width: 4),
              Text(
                'Confirm new job',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.orange.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _buildJobDetailRow('Client', jobData['client'] ?? ''),
          _buildJobDetailRow('Date', jobData['dateDisplay'] ?? ''),
          _buildJobDetailRow('Man-days', '${jobData['manDays'] ?? 0}'),
          _buildJobDetailRow('Type', jobData['jobTypeName'] ?? ''),
          if ((jobData['area'] as String?)?.isNotEmpty == true)
            _buildJobDetailRow('Area', jobData['area']),
          if ((jobData['amount'] as num?) != null &&
              (jobData['amount'] as num) > 0)
            _buildJobDetailRow('Amount', 'R${jobData['amount']}'),
          if ((jobData['collectionAddress'] as String?)?.isNotEmpty == true)
            _buildJobDetailRow(
                'Collection Address', jobData['collectionAddress']),
          if ((jobData['specialInstructions'] as String?)?.isNotEmpty == true)
            _buildJobDetailRow('Instructions', jobData['specialInstructions']),
          const SizedBox(height: 8),
          riverpod.Consumer(
            builder: (context, ref, _) {
              final provider = ref.watch(aiChatRiverpod);
              final isLoading = provider.isLoading;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ConfirmButton(
                    label: 'Confirm',
                    icon: Icons.check_rounded,
                    color: Colors.green.shade600,
                    isLoading: isLoading,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.confirmPendingJob(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                  const SizedBox(width: 8),
                  _ConfirmButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    color: Colors.red.shade400,
                    isLoading: false,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.cancelPendingJob(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildMultiJobConfirmationCard(AiChatAction action, int messageIndex) {
    final jobsData = action.jobsData!;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.orange.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.shade200, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.playlist_add_check_rounded,
                  size: 14, color: Colors.orange.shade700),
              const SizedBox(width: 4),
              Text(
                'Confirm ${jobsData.length} jobs',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.orange.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...jobsData.asMap().entries.map((entry) {
            final i = entry.key;
            final job = entry.value;
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade100),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i + 1}. ${job['client'] ?? ''}',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${job['jobTypeName'] ?? job['jobTypeId'] ?? ''} · ${job['manDays'] ?? 0} man-days · ${job['dateDisplay'] ?? job['date'] ?? ''}'
                      '${(job['area'] as String?)?.isNotEmpty == true ? ' · ${job['area']}' : ''}'
                      '${(job['amount'] as num?) != null && (job['amount'] as num) > 0 ? ' · R${job['amount']}' : ''}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 4),
          riverpod.Consumer(
            builder: (context, ref, _) {
              final provider = ref.watch(aiChatRiverpod);
              final isLoading = provider.isLoading;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ConfirmButton(
                    label: 'Confirm All',
                    icon: Icons.check_rounded,
                    color: Colors.green.shade600,
                    isLoading: isLoading,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.confirmPendingMultipleJobs(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                  const SizedBox(width: 8),
                  _ConfirmButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    color: Colors.red.shade400,
                    isLoading: false,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.cancelPendingMultipleJobs(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleConfirmationCard(AiChatAction action, int messageIndex) {
    final scheduleJobs = action.scheduleJobsData!;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.purple.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.purple.shade200, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.calendar_month_rounded,
                  size: 14, color: Colors.purple.shade700),
              const SizedBox(width: 4),
              Text(
                'Confirm ${scheduleJobs.length} schedule job${scheduleJobs.length == 1 ? '' : 's'}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.purple.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ...scheduleJobs.asMap().entries.map((entry) {
            final i = entry.key;
            final job = entry.value;
            final distributorName =
                job['distributorName'] as String? ?? 'Unassigned';
            final clients = (job['clients'] as List?)
                    ?.map((c) => c.toString())
                    .join(', ') ??
                '';
            final areas = (job['workingAreas'] as List?)
                    ?.map((a) => a.toString())
                    .join(', ') ??
                '';
            final date =
                job['dateDisplay'] as String? ?? job['date'] as String? ?? '';
            final workMaps = job['workMaps'] as List? ?? [];
            return Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.purple.shade100),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${i + 1}. $distributorName',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Colors.grey.shade800,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${clients.isNotEmpty ? clients : 'No clients'}'
                      '${areas.isNotEmpty ? ' · $areas' : ''}'
                      '${date.isNotEmpty ? ' · $date' : ''}',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    if (workMaps.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        '🗺️ ${workMaps.length} work area map${workMaps.length == 1 ? '' : 's'} included',
                        style: TextStyle(
                          fontSize: 9,
                          color: Colors.blue.shade600,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            );
          }),
          const SizedBox(height: 4),
          riverpod.Consumer(
            builder: (context, ref, _) {
              final provider = ref.watch(aiChatRiverpod);
              final isLoading = provider.isLoading;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ConfirmButton(
                    label: 'Confirm All',
                    icon: Icons.check_rounded,
                    color: Colors.green.shade600,
                    isLoading: isLoading,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.confirmPendingScheduleJobs(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                  const SizedBox(width: 8),
                  _ConfirmButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    color: Colors.red.shade400,
                    isLoading: false,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.cancelPendingScheduleJobs(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildUpdateConfirmationCard(AiChatAction action, int messageIndex) {
    final updateData = action.updateData!;
    final changes = Map<String, dynamic>.from(updateData['changes'] as Map);
    final client = updateData['client'] as String? ?? '';
    final dateDisplay = updateData['dateDisplay'] as String? ?? '';

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blue.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.blue.shade200, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.edit_rounded, size: 14, color: Colors.blue.shade700),
              const SizedBox(width: 4),
              Text(
                'Confirm update',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.blue.shade800,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$client — $dateDisplay',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade700,
            ),
          ),
          const SizedBox(height: 6),
          ...changes.entries.map((entry) {
            final change = Map<String, dynamic>.from(entry.value as Map);
            final label = change['label'] as String? ?? entry.key;
            final oldDisplay = change['oldDisplay'] as String? ?? '—';
            final newDisplay = change['newDisplay'] as String? ?? '';
            return _buildChangeRow(label, oldDisplay, newDisplay);
          }),
          const SizedBox(height: 8),
          riverpod.Consumer(
            builder: (context, ref, _) {
              final provider = ref.watch(aiChatRiverpod);
              final isLoading = provider.isLoading;
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _ConfirmButton(
                    label: 'Confirm',
                    icon: Icons.check_rounded,
                    color: Colors.blue.shade600,
                    isLoading: isLoading,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.confirmPendingUpdate(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                  const SizedBox(width: 8),
                  _ConfirmButton(
                    label: 'Cancel',
                    icon: Icons.close_rounded,
                    color: Colors.red.shade400,
                    isLoading: false,
                    onPressed: isLoading
                        ? null
                        : () {
                            provider.cancelPendingUpdate(messageIndex);
                            _scrollToBottom();
                          },
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildChangeRow(String label, String oldValue, String newValue) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 75,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: TextStyle(fontSize: 11, color: Colors.grey.shade800),
                children: [
                  TextSpan(
                    text: oldValue,
                    style: TextStyle(
                      decoration: TextDecoration.lineThrough,
                      color: Colors.red.shade400,
                    ),
                  ),
                  const TextSpan(text: '  →  '),
                  TextSpan(
                    text: newValue,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: Colors.green.shade700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJobDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 75,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputArea() {
    return riverpod.Consumer(
      builder: (context, ref, _) {
        final provider = ref.watch(aiChatRiverpod);
        return Container(
          padding: const EdgeInsets.fromLTRB(10, 6, 6, 10),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.05),
                blurRadius: 6,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _messageController,
                      focusNode: _messageFocusNode,
                      enabled: !provider.isLoading,
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        hintText: 'Ask Pelisa...',
                        hintStyle: TextStyle(
                          color: Colors.grey.shade400,
                          fontSize: 13,
                        ),
                        filled: true,
                        fillColor: Colors.grey.shade100,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(20),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 8),
                        isDense: true,
                      ),
                      maxLines: 4,
                      minLines: 1,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Material(
                    color: provider.isLoading
                        ? Colors.grey.shade300
                        : Colors.deepPurple.shade600,
                    borderRadius: BorderRadius.circular(18),
                    child: InkWell(
                      onTap: provider.isLoading ? null : _sendMessage,
                      borderRadius: BorderRadius.circular(18),
                      child: Container(
                        width: 36,
                        height: 36,
                        alignment: Alignment.center,
                        child: provider.isLoading
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.grey.shade500,
                                ),
                              )
                            : const Icon(Icons.arrow_upward_rounded,
                                color: Colors.white, size: 18),
                      ),
                    ),
                  ),
                ],
              ),
              // Quick teach shortcut
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: GestureDetector(
                  onTap: () => _showQuickTeach(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.psychology_rounded,
                          size: 12, color: Colors.deepPurple.shade300),
                      const SizedBox(width: 4),
                      Text(
                        'Teach Pelisa something new',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.deepPurple.shade300,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// Show the knowledge management dialog
  void _showKnowledgeManager(BuildContext context) {
    final provider = ref.read(aiChatRiverpod);
    showDialog(
      context: context,
      builder: (ctx) => _KnowledgeManagerDialog(provider: provider),
    );
  }

  /// Show dialog to save an assistant message as knowledge
  void _showAddKnowledgeFromMessage(BuildContext context, String content) {
    final controller = TextEditingController(text: content);
    String category = 'fact';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Row(
            children: [
              Icon(Icons.lightbulb_rounded,
                  size: 20, color: Colors.amber.shade600),
              const SizedBox(width: 8),
              const Text('Save as Knowledge',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ],
          ),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Edit the text to keep only the key fact or rule:',
                    style:
                        TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                const SizedBox(height: 8),
                TextField(
                  controller: controller,
                  maxLines: 5,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.all(10),
                    hintText: 'e.g. "Man-days represent the number of workers '
                        'assigned, not calendar days"',
                    hintStyle:
                        TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  ),
                ),
                const SizedBox(height: 12),
                Text('Category:',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: Colors.grey.shade700)),
                const SizedBox(height: 4),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final cat in [
                      ('fact', 'Fact', Icons.info_outline_rounded),
                      ('correction', 'Correction', Icons.edit_rounded),
                      ('workflow', 'Workflow', Icons.route_rounded),
                      ('preference', 'Preference', Icons.tune_rounded),
                    ])
                      ChoiceChip(
                        label: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(cat.$3, size: 13),
                            const SizedBox(width: 4),
                            Text(cat.$2, style: const TextStyle(fontSize: 11)),
                          ],
                        ),
                        selected: category == cat.$1,
                        onSelected: (_) =>
                            setDialogState(() => category = cat.$1),
                        selectedColor: Colors.deepPurple.shade100,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton.icon(
              onPressed: () async {
                if (controller.text.trim().isEmpty) return;
                final provider = ref.read(aiChatRiverpod);
                await provider.addKnowledge(
                  content: controller.text.trim(),
                  category: category,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: const Text(
                          'Knowledge saved \u2014 Pelisa will remember'),
                      duration: const Duration(seconds: 2),
                      behavior: SnackBarBehavior.floating,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                  );
                }
              },
              icon: const Icon(Icons.save_rounded, size: 16),
              label: const Text('Save', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }

  /// Quick teach \u2014 opens a simple dialog to add a new fact directly
  void _showQuickTeach(BuildContext context) {
    _showAddKnowledgeFromMessage(context, '');
  }
}

/// Small icon button shown below assistant messages
class _SmallActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _SmallActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(3),
          child: Icon(icon, size: 13, color: Colors.grey.shade400),
        ),
      ),
    );
  }
}

/// Dialog for managing all knowledge entries
class _KnowledgeManagerDialog extends StatefulWidget {
  final AiChatProvider provider;

  const _KnowledgeManagerDialog({required this.provider});

  @override
  State<_KnowledgeManagerDialog> createState() =>
      _KnowledgeManagerDialogState();
}

class _KnowledgeManagerDialogState extends State<_KnowledgeManagerDialog> {
  List<AiKnowledgeEntry>? _entries;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadEntries();
  }

  Future<void> _loadEntries() async {
    final entries = await widget.provider.getKnowledge();
    if (mounted) {
      setState(() {
        _entries = List.from(entries);
        _isLoading = false;
      });
    }
  }

  IconData _categoryIcon(String category) {
    switch (category) {
      case 'correction':
        return Icons.edit_rounded;
      case 'workflow':
        return Icons.route_rounded;
      case 'preference':
        return Icons.tune_rounded;
      default:
        return Icons.info_outline_rounded;
    }
  }

  Color _categoryColor(String category) {
    switch (category) {
      case 'correction':
        return Colors.orange.shade600;
      case 'workflow':
        return Colors.blue.shade600;
      case 'preference':
        return Colors.teal.shade600;
      default:
        return Colors.deepPurple.shade600;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.psychology_rounded,
              size: 22, color: Colors.deepPurple.shade600),
          const SizedBox(width: 8),
          const Expanded(
            child: Text("Pelisa's Knowledge",
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          IconButton(
            icon: const Icon(Icons.add_rounded, size: 20),
            tooltip: 'Add knowledge',
            onPressed: _showAddEntry,
          ),
        ],
      ),
      content: SizedBox(
        width: 450,
        height: 350,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _entries == null || _entries!.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.lightbulb_outline_rounded,
                            size: 40, color: Colors.grey.shade300),
                        const SizedBox(height: 10),
                        Text(
                          'No knowledge entries yet',
                          style: TextStyle(
                              color: Colors.grey.shade500, fontSize: 13),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Teach Pelisa about your system by adding facts,\n'
                          'corrections, workflows, or preferences.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              color: Colors.grey.shade400, fontSize: 11),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _showAddEntry,
                          icon: const Icon(Icons.add_rounded, size: 16),
                          label: const Text('Add First Entry',
                              style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _entries!.length,
                    separatorBuilder: (_, __) =>
                        Divider(height: 1, color: Colors.grey.shade200),
                    itemBuilder: (context, index) {
                      final entry = _entries![index];
                      final color = _categoryColor(entry.category);
                      return ListTile(
                        dense: true,
                        leading: Icon(_categoryIcon(entry.category),
                            size: 18, color: color),
                        title: Text(
                          entry.content,
                          style: const TextStyle(fontSize: 12, height: 1.3),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        subtitle: Text(
                          '${entry.category} \u2022 by ${entry.addedBy}',
                          style: TextStyle(
                              fontSize: 10, color: Colors.grey.shade500),
                        ),
                        trailing: IconButton(
                          icon: Icon(Icons.delete_outline_rounded,
                              size: 16, color: Colors.red.shade300),
                          tooltip: 'Remove',
                          onPressed: () async {
                            await widget.provider.removeKnowledge(entry.id);
                            setState(() {
                              _entries!.removeAt(index);
                            });
                          },
                        ),
                      );
                    },
                  ),
      ),
      actions: [
        TextButton.icon(
          onPressed: () {
            widget.provider.refreshKnowledge();
            _loadEntries();
          },
          icon: const Icon(Icons.refresh_rounded, size: 14),
          label: const Text('Refresh', style: TextStyle(fontSize: 12)),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close', style: TextStyle(fontSize: 12)),
        ),
      ],
    );
  }

  void _showAddEntry() {
    final controller = TextEditingController();
    String category = 'fact';
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Knowledge',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  maxLines: 4,
                  autofocus: true,
                  style: const TextStyle(fontSize: 13),
                  decoration: InputDecoration(
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8)),
                    contentPadding: const EdgeInsets.all(10),
                    hintText:
                        'e.g. "Junk collection jobs always need a trailer"',
                    hintStyle:
                        TextStyle(fontSize: 12, color: Colors.grey.shade400),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 6,
                  children: [
                    for (final cat in [
                      ('fact', 'Fact'),
                      ('correction', 'Correction'),
                      ('workflow', 'Workflow'),
                      ('preference', 'Preference'),
                    ])
                      ChoiceChip(
                        label:
                            Text(cat.$2, style: const TextStyle(fontSize: 11)),
                        selected: category == cat.$1,
                        onSelected: (_) =>
                            setDialogState(() => category = cat.$1),
                        selectedColor: Colors.deepPurple.shade100,
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                if (controller.text.trim().isEmpty) return;
                await widget.provider.addKnowledge(
                  content: controller.text.trim(),
                  category: category,
                );
                if (ctx.mounted) Navigator.pop(ctx);
                _loadEntries();
              },
              child: const Text('Save', style: TextStyle(fontSize: 13)),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final String tooltip;

  const _HeaderIconButton({
    required this.icon,
    required this.onPressed,
    required this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.white.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: onPressed,
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 30,
            height: 30,
            child: Icon(icon,
                color: Colors.white.withValues(alpha: 0.9), size: 16),
          ),
        ),
      ),
    );
  }
}

class _ConfirmButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool isLoading;
  final VoidCallback? onPressed;

  const _ConfirmButton({
    required this.label,
    required this.icon,
    required this.color,
    required this.isLoading,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: onPressed != null ? color : Colors.grey.shade300,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isLoading)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                )
              else
                Icon(icon, size: 13, color: Colors.white),
              const SizedBox(width: 4),
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
