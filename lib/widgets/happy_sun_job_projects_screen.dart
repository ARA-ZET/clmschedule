import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:image_picker/image_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:video_player/video_player.dart';
import 'package:image/image.dart' as img;
import 'dart:typed_data';
import '../models/happy_sun_project.dart';
import '../models/happy_sun_shared.dart'; // For CategorizedTools, ChecklistData, GroupedToolItem, ToolChecklistItem
import '../models/inventory_tool.dart';
import '../models/job_list_item.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/inventory_provider.dart';
import '../providers/auth_provider.dart';
import '../config/flavor_config.dart';
import 'happy_sun_checkout_screen.dart';
import 'happy_sun_checklist_screen.dart';
import 'happy_sun_checkin_screen.dart';

class HappySunJobProjectsScreen extends StatefulWidget {
  const HappySunJobProjectsScreen({super.key});

  @override
  State<HappySunJobProjectsScreen> createState() =>
      _HappySunJobProjectsScreenState();
}

class _HappySunJobProjectsScreenState extends State<HappySunJobProjectsScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final Map<String, int> _cardTabIndices = {}; // Track tab index per project ID

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  int _getCardTabIndex(String projectId) {
    return _cardTabIndices[projectId] ?? 0;
  }

  void _setCardTabIndex(String projectId, int index) {
    setState(() {
      _cardTabIndices[projectId] = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Consumer<HappySunProjectProvider>(
      builder: (context, happySunProvider, child) {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);

        final allProjects = happySunProvider.projects;
        final pendingCount = allProjects.where((project) {
          final projectDate = DateTime(project.scheduledDate.year,
              project.scheduledDate.month, project.scheduledDate.day);
          return projectDate.isAfter(today);
        }).length;
        final inProgressCount = allProjects.where((project) {
          final projectDate = DateTime(project.scheduledDate.year,
              project.scheduledDate.month, project.scheduledDate.day);
          return projectDate.isAtSameMomentAs(today);
        }).length;
        final completedCount = allProjects.where((project) {
          final projectDate = DateTime(project.scheduledDate.year,
              project.scheduledDate.month, project.scheduledDate.day);
          return projectDate.isBefore(today);
        }).length;

        return Column(
          children: [
            // Sync status banner (Happy Sun offline support)
            if (FlavorConfig.instance.isHappySun)
              _buildSyncStatusBanner(happySunProvider),
            // Top bar with tabs and month filters
            Material(
              elevation: 2,
              child: Container(
                color: Theme.of(context).colorScheme.surface,
                padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 8 : 16,
                  vertical: isMobile ? 4 : 8,
                ),
                child: isMobile
                    ? _buildMobileHeader(
                        context,
                        happySunProvider,
                        allProjects.length,
                        pendingCount,
                        inProgressCount,
                        completedCount,
                        now,
                      )
                    : Row(
                        children: [
                          // Tabs on the left
                          Expanded(
                            child: TabBar(
                              controller: _tabController,
                              isScrollable: true,
                              tabs: [
                                Tab(
                                    text:
                                        'All Projects (${allProjects.length})'),
                                Tab(text: 'Confirmed ($pendingCount)'),
                                Tab(text: 'In Progress ($inProgressCount)'),
                                Tab(text: 'Completed ($completedCount)'),
                              ],
                            ),
                          ),
                          const SizedBox(width: 24),
                          // Month filters on the right
                          const SizedBox(width: 12),
                          _buildMonthButton(
                            context,
                            happySunProvider,
                            'Last Month',
                            DateTime(now.year, now.month - 1),
                          ),
                          const SizedBox(width: 8),
                          _buildMonthButton(
                            context,
                            happySunProvider,
                            'This Month',
                            DateTime(now.year, now.month),
                          ),
                          const SizedBox(width: 8),
                          _buildMonthButton(
                            context,
                            happySunProvider,
                            'Next Month',
                            DateTime(now.year, now.month + 1),
                          ),
                          const SizedBox(width: 16),
                          OutlinedButton.icon(
                            onPressed: () =>
                                _showMonthPicker(context, happySunProvider),
                            icon: const Icon(Icons.calendar_today, size: 18),
                            label: Text(
                              _getMonthYearText(happySunProvider.currentMonth),
                            ),
                            style: OutlinedButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                            ),
                          ),
                          // Sign out button for Happy Sun flavor
                          if (FlavorConfig.instance.isHappySun) ...[
                            const SizedBox(width: 16),
                            IconButton(
                              icon: const Icon(Icons.logout, color: Colors.red),
                              tooltip: 'Sign Out',
                              onPressed: () async {
                                final confirmed = await showDialog<bool>(
                                  context: context,
                                  builder: (context) => AlertDialog(
                                    title: const Text('Sign Out'),
                                    content: const Text(
                                        'Are you sure you want to sign out?'),
                                    actions: [
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(false),
                                        child: const Text('Cancel'),
                                      ),
                                      TextButton(
                                        onPressed: () =>
                                            Navigator.of(context).pop(true),
                                        child: const Text('Sign Out'),
                                      ),
                                    ],
                                  ),
                                );

                                if (confirmed == true && context.mounted) {
                                  await context.read<AuthProvider>().signOut();
                                }
                              },
                            ),
                          ],
                        ],
                      ),
              ),
            ),
            Expanded(
              child: isMobile
                  ? _buildJobsList(_getSelectedStatus())
                  : TabBarView(
                      controller: _tabController,
                      children: [
                        _buildJobsList('all'),
                        _buildJobsList('confirmed'),
                        _buildJobsList('in-progress'),
                        _buildJobsList('completed'),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  String _getSelectedStatus() {
    switch (_tabController.index) {
      case 0:
        return 'all';
      case 1:
        return 'confirmed';
      case 2:
        return 'in-progress';
      case 3:
        return 'completed';
      default:
        return 'all';
    }
  }

  Widget _buildSyncStatusBanner(HappySunProjectProvider provider) {
    final syncStatus = provider.syncStatus;
    if (syncStatus == null) return const SizedBox.shrink();

    final isOnline = syncStatus['isOnline'] as bool;
    final pendingChanges = syncStatus['pendingChanges'] as int;

    // Show offline indicator with pending changes count
    if (!isOnline && pendingChanges > 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.orange.shade700,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.cloud_off, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'Offline - $pendingChanges change${pendingChanges > 1 ? "s" : ""} will sync when online',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    // Show syncing indicator
    if (isOnline && pendingChanges > 0) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.blue.shade700,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.1),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation(Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'Syncing $pendingChanges change${pendingChanges > 1 ? "s" : ""}...',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w500,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      );
    }

    return const SizedBox.shrink();
  }

  Widget _buildMobileHeader(
    BuildContext context,
    HappySunProjectProvider happySunProvider,
    int allCount,
    int pendingCount,
    int inProgressCount,
    int completedCount,
    DateTime now,
  ) {
    return Column(
      children: [
        // Status filter dropdown
        Row(
          spacing: 8,
          children: [
            const Icon(Icons.filter_list, size: 18),
            Expanded(
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButton<int>(
                  value: _tabController.index,
                  isExpanded: true,
                  underline: const SizedBox(),
                  icon: const Icon(Icons.arrow_drop_down, size: 20),
                  style: const TextStyle(fontSize: 14, color: Colors.black87),
                  onChanged: (int? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _tabController.animateTo(newValue);
                      });
                    }
                  },
                  items: [
                    DropdownMenuItem(
                      value: 0,
                      child: Text('All Projects ($allCount)'),
                    ),
                    DropdownMenuItem(
                      value: 1,
                      child: Text('Confirmed ($pendingCount)'),
                    ),
                    DropdownMenuItem(
                      value: 2,
                      child: Text('In Progress ($inProgressCount)'),
                    ),
                    DropdownMenuItem(
                      value: 3,
                      child: Text('Completed ($completedCount)'),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: () => _showMonthPicker(context, happySunProvider),
              icon: const Icon(Icons.calendar_month, size: 20),
              tooltip: _getMonthYearText(happySunProvider.currentMonth),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            // Sign out button for Happy Sun flavor (mobile)
            if (FlavorConfig.instance.isHappySun)
              IconButton(
                icon: const Icon(Icons.logout, color: Colors.red, size: 20),
                tooltip: 'Sign Out',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('Sign Out'),
                      content: const Text('Are you sure you want to sign out?'),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(false),
                          child: const Text('Cancel'),
                        ),
                        TextButton(
                          onPressed: () => Navigator.of(context).pop(true),
                          child: const Text('Sign Out'),
                        ),
                      ],
                    ),
                  );

                  if (confirmed == true && context.mounted) {
                    await context.read<AuthProvider>().signOut();
                  }
                },
              ),
          ],
        ),
      ],
    );
  }

  Widget _buildJobsList(String statusFilter) {
    return Consumer2<HappySunProjectProvider, JobListProvider>(
      builder: (context, happySunProvider, jobListProvider, child) {
        if (happySunProvider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        if (happySunProvider.error != null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 48, color: Colors.red),
                const SizedBox(height: 16),
                Text('Error: ${happySunProvider.error}'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    // Refresh
                    happySunProvider.setMonth(
                      happySunProvider.currentMonth.year,
                      happySunProvider.currentMonth.month,
                    );
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        var projects = happySunProvider.projects;

        // Apply date-based status filter
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);

        if (statusFilter != 'all') {
          projects = projects.where((project) {
            final projectDate = DateTime(project.scheduledDate.year,
                project.scheduledDate.month, project.scheduledDate.day);

            if (statusFilter == 'confirmed') {
              return projectDate.isAfter(today);
            } else if (statusFilter == 'in-progress') {
              return projectDate.isAtSameMomentAs(today);
            } else if (statusFilter == 'completed') {
              return projectDate.isBefore(today);
            }
            return true;
          }).toList();
        }

        // Sort projects by date (ascending)
        projects.sort((a, b) => a.scheduledDate.compareTo(b.scheduledDate));

        if (projects.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.work_outline, size: 64, color: Colors.grey.shade400),
                const SizedBox(height: 16),
                Text(
                  statusFilter == 'all'
                      ? 'No Happy Sun jobs this month'
                      : statusFilter == 'confirmed'
                          ? 'No jobs scheduled after today'
                          : statusFilter == 'in-progress'
                              ? 'No jobs scheduled for today'
                              : 'No jobs scheduled before today',
                  style: TextStyle(
                    fontSize: 18,
                    color: Colors.grey.shade600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Add window cleaning or solar panel cleaning jobs\nto the Job List to get started',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey.shade500),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: projects.length,
          itemBuilder: (context, index) {
            final project = projects[index];
            // Get corresponding JobListItem for client details
            final jobListItem = jobListProvider.jobListItems.firstWhere(
              (item) => item.id == project.jobListItemId,
              orElse: () => JobListItem(
                id: project.id,
                invoice: '',
                amount: 0,
                client: 'Unknown Client',
                jobStatusId: project.statusId,
                invoiceStatusId: 'pending',
                jobTypeId: project.isWindowCleaning
                    ? 'windowCleaning'
                    : 'solarPanelCleaning',
                area: '',
                quantity: 0,
                manDays: 0,
                date: project.scheduledDate,
                collectionAddress: '',
                collectionDate: project.scheduledDate,
                specialInstructions: '',
                quantityDistributed: 0,
                invoiceDetails: '',
                reportAddresses: '',
                whoToInvoice: '',
              ),
            );

            return _buildProjectCard(context, project, jobListItem);
          },
        );
      },
    );
  }

  Widget _buildProjectCard(
      BuildContext context, HappySunProject project, JobListItem jobListItem) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    // Determine border color based on date
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final projectDate = DateTime(project.scheduledDate.year,
        project.scheduledDate.month, project.scheduledDate.day);

    Color borderColor;
    if (projectDate.isBefore(today)) {
      borderColor = Colors.green;
    } else if (projectDate.isAfter(today)) {
      borderColor = Colors.blue;
    } else {
      borderColor = Colors.orange;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: borderColor,
              width: isMobile ? 6 : 10,
            ),
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: isMobile
            ? _buildMobileProjectCard(
                context, project, jobListItem, borderColor)
            : _buildDesktopProjectCard(context, project, jobListItem),
      ),
    );
  }

  Widget _buildDesktopProjectCard(
      BuildContext context, HappySunProject project, JobListItem jobListItem) {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section 1: Project Details
          Expanded(
            flex: 1,
            child: _buildProjectDetailsSection(project, jobListItem),
          ),
          const VerticalDivider(width: 32),
          // Section 2: Checkout
          Expanded(
            flex: 1,
            child: _buildCheckoutSection(context, project),
          ),
          const VerticalDivider(width: 32),
          // Section 3: Checklist
          Expanded(
            flex: 1,
            child: _buildChecklistSection(context, project),
          ),
          const VerticalDivider(width: 32),
          // Section 4: Checkin
          Expanded(
            flex: 1,
            child: _buildCheckinSection(context, project),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileProjectCard(BuildContext context, HappySunProject project,
      JobListItem jobListItem, Color borderColor) {
    final currentTabIndex = _getCardTabIndex(project.id);

    // Determine status icons
    final hasCheckout = project.startTime != null;
    final hasChecklist = project.checklistData?.isCompleted == true;
    final hasCheckin = project.checkin?.isCompleted == true;

    return Column(
      children: [
        // Tab bar
        Container(
          decoration: BoxDecoration(
            color: borderColor.withOpacity(0.1),
            border: Border(
              bottom: BorderSide(color: Colors.grey.shade200),
            ),
          ),
          child: Row(
            children: [
              _buildMobileTab(
                icon: Icons.info_outline,
                label: 'Details',
                isSelected: currentTabIndex == 0,
                onTap: () => _setCardTabIndex(project.id, 0),
              ),
              _buildMobileTab(
                icon: hasCheckout ? Icons.check_circle : Icons.logout,
                label: 'Checkout',
                isSelected: currentTabIndex == 1,
                onTap: () => _setCardTabIndex(project.id, 1),
                statusColor: hasCheckout ? Colors.green : null,
              ),
              _buildMobileTab(
                icon: hasChecklist ? Icons.check_circle : Icons.checklist,
                label: 'Checklist',
                isSelected: currentTabIndex == 2,
                onTap: () => _setCardTabIndex(project.id, 2),
                statusColor: hasChecklist ? Colors.green : null,
              ),
              _buildMobileTab(
                icon: hasCheckin ? Icons.check_circle : Icons.assignment_return,
                label: 'Check-in',
                isSelected: currentTabIndex == 3,
                onTap: () => _setCardTabIndex(project.id, 3),
                statusColor: hasCheckin ? Colors.green : null,
              ),
            ],
          ),
        ),
        // Content
        Padding(
          padding: const EdgeInsets.all(16),
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _buildMobileCardContent(
              context,
              project,
              jobListItem,
              currentTabIndex,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMobileTab({
    required IconData icon,
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
    Color? statusColor,
  }) {
    return Expanded(
      child: InkWell(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? Colors.orange : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color:
                    statusColor ?? (isSelected ? Colors.orange : Colors.grey),
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected ? Colors.orange : Colors.grey,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileCardContent(
    BuildContext context,
    HappySunProject project,
    JobListItem jobListItem,
    int tabIndex,
  ) {
    switch (tabIndex) {
      case 0:
        return _buildProjectDetailsSection(project, jobListItem);
      case 1:
        return _buildCheckoutSection(context, project);
      case 2:
        return _buildChecklistSection(context, project);
      case 3:
        return _buildCheckinSection(context, project);
      default:
        return _buildProjectDetailsSection(project, jobListItem);
    }
  }

  Widget _buildProjectDetailsSection(
      HappySunProject project, JobListItem jobListItem) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              project.isWindowCleaning
                  ? Icons.cleaning_services
                  : Icons.solar_power,
              color: Colors.orange,
              size: 20,
            ),
            const SizedBox(width: 8),
            const Text(
              'Project Details',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _buildDetailRow('Client', jobListItem.client),
        _buildDetailRow('Address', jobListItem.area),
        _buildDetailRow(
          'Date',
          '${jobListItem.date.day}/${jobListItem.date.month}/${jobListItem.date.year}',
        ),
        _buildDetailRow(
          'Time',
          '${jobListItem.date.hour.toString().padLeft(2, '0')}:${jobListItem.date.minute.toString().padLeft(2, '0')}',
        ),
        _buildDetailRow(
          'Staff Needed',
          '${jobListItem.manDays.toStringAsFixed(jobListItem.manDays % 1 == 0 ? 0 : 1)} ${jobListItem.manDays == 1 ? 'Cleaner' : 'Cleaners'}',
        ),
        _buildDetailRow(
          'Type',
          jobListItem.jobTypeId,
        ),
        // Special Instructions section (if available)
        if (jobListItem.specialInstructions.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.blue.shade200),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: Colors.blue.shade700),
                    const SizedBox(width: 6),
                    Text(
                      'Special Instructions',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Colors.blue.shade700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  jobListItem.specialInstructions,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade800,
                  ),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: 16),
        // Row with three buttons
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showToolsDialog(context, project),
                icon: Icon(
                    project.toolsNeeded != null ? Icons.build : Icons.edit,
                    size: 18),
                label: Text(
                  project.toolsNeeded != null
                      ? 'Tools (${project.toolsNeeded!.totalCount})'
                      : 'Add Tools',
                  style: const TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.orange,
                  side: const BorderSide(color: Colors.orange),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _handleBeforeImages(context, project),
                icon: Icon(
                    project.beforeImages != null &&
                            project.beforeImages!.isNotEmpty
                        ? Icons.photo_library
                        : Icons.add_photo_alternate,
                    size: 18),
                label: Text(
                  project.beforeImages != null &&
                          project.beforeImages!.isNotEmpty
                      ? 'Before (${project.beforeImages!.length})'
                      : 'Before',
                  style: const TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.blue,
                  side: const BorderSide(color: Colors.blue),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _handleAfterImages(context, project),
                icon: Icon(
                    project.afterImages != null &&
                            project.afterImages!.isNotEmpty
                        ? Icons.photo_camera
                        : Icons.add_a_photo,
                    size: 18),
                label: Text(
                  project.afterImages != null && project.afterImages!.isNotEmpty
                      ? 'After (${project.afterImages!.length})'
                      : 'After',
                  style: const TextStyle(fontSize: 12),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.green,
                  side: const BorderSide(color: Colors.green),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 12),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildCheckoutSection(BuildContext context, HappySunProject project) {
    final hasCheckout = project.startTime != null;
    final toolsUsed = project.toolsUsedCategorized;
    final totalToolsTaken = toolsUsed?.totalCount ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              hasCheckout ? Icons.check_circle : Icons.radio_button_unchecked,
              color: hasCheckout ? Colors.green : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 8),
            const Text(
              'Checkout',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (hasCheckout) ...[
          if (project.startTime != null)
            _buildDetailRow(
              'Time',
              '${project.startTime!.hour.toString().padLeft(2, '0')}:${project.startTime!.minute.toString().padLeft(2, '0')}',
            ),
          _buildDetailRow('Tools Taken', '$totalToolsTaken'),
          if (toolsUsed != null) ...[
            const SizedBox(height: 8),
            _buildDetailRow('Team Tools',
                '${toolsUsed.teamTools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity)}'),
            _buildDetailRow('Individual',
                '${toolsUsed.individualTools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity)}'),
            _buildDetailRow('Extras',
                '${toolsUsed.extras.fold<int>(0, (sum, tool) => sum + tool.totalQuantity)}'),
            if (toolsUsed.accessories.isNotEmpty)
              _buildDetailRow('Accessories',
                  '${toolsUsed.accessories.fold<int>(0, (sum, tool) => sum + tool.totalQuantity)}'),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _showToolsTakenDialog(context, project),
              icon: const Icon(Icons.list, size: 16),
              label: const Text('View Tools'),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.green,
                side: const BorderSide(color: Colors.green),
              ),
            ),
          ],
        ] else ...[
          const Text(
            'Not checked out yet',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _handleCheckout(context, project),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Start Checkout'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildChecklistSection(BuildContext context, HappySunProject project) {
    final hasStarted = project.startTime != null;
    final isComplete = project.checklistData?.isCompleted == true;
    final hasProgress = project.checklistData != null && !isComplete;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isComplete
                  ? Icons.check_circle
                  : hasProgress
                      ? Icons.pending
                      : Icons.radio_button_unchecked,
              color: isComplete
                  ? Colors.green
                  : hasProgress
                      ? Colors.blue
                      : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 8),
            const Text(
              'Checklist',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (!hasStarted) ...[
          const Text(
            'Complete checkout first',
            style: TextStyle(color: Colors.grey),
          ),
        ] else if (isComplete)
          ..._buildChecklistDetails(context, project, project.checklistData!)
        else if (hasProgress) ...[
          _buildDetailRow('Status', 'In Progress'),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _handleChecklist(context, project),
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('Resume Checklist'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ] else ...[
          // Job started but checklist not done yet
          const Text(
            'Checklist not started',
            style: TextStyle(color: Colors.orange),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _handleChecklist(context, project),
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('Start Checklist'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCheckinSection(BuildContext context, HappySunProject project) {
    final hasStarted = project.checklistData?.isCompleted == true;
    final isComplete = project.checkin?.isCompleted == true;
    final hasProgress = project.checkin != null && !isComplete;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isComplete
                  ? Icons.check_circle
                  : hasProgress
                      ? Icons.pending
                      : Icons.radio_button_unchecked,
              color: isComplete
                  ? Colors.green
                  : hasProgress
                      ? Colors.purple
                      : Colors.grey,
              size: 20,
            ),
            const SizedBox(width: 8),
            const Text(
              'Check-in',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (isComplete) ...[
          if (project.endTime != null)
            _buildDetailRow(
              'Time',
              '${project.endTime!.hour.toString().padLeft(2, '0')}:${project.endTime!.minute.toString().padLeft(2, '0')}',
            ),
          if (project.workDuration != null)
            _buildDetailRow(
              'Duration',
              '${project.workDuration!.inHours}h ${project.workDuration!.inMinutes.remainder(60)}m',
            ),
          _buildDetailRow('Status', 'Complete'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _showCheckinDetailsDialog(context, project),
            icon: const Icon(Icons.visibility, size: 18),
            label: const Text('View Check-in Details'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.green,
            ),
          ),
        ] else if (hasProgress) ...[
          const Text(
            'Check-in in progress',
            style: TextStyle(color: Colors.purple, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _handleCheckin(context, project),
            icon: const Icon(Icons.edit, size: 18),
            label: const Text('Resume Check-in'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
            ),
          ),
        ] else if (project.startTime == null) ...[
          const Text(
            'Complete checkout first',
            style: TextStyle(color: Colors.grey),
          ),
        ] else if (!hasStarted) ...[
          const Text(
            'Complete checklist first',
            style: TextStyle(color: Colors.grey),
          ),
        ] else ...[
          const Text(
            'Ready for check-in',
            style: TextStyle(color: Colors.orange, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _handleCheckin(context, project),
            icon: const Icon(Icons.assignment_return, size: 18),
            label: const Text('Check In Tools'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.purple,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDetailRow(String label, String value,
      {TextStyle? valueStyle, Color? color}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 80,
            child: Text(
              '$label:',
              style: const TextStyle(
                fontWeight: FontWeight.w500,
                color: Colors.grey,
                fontSize: 12,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: valueStyle ??
                  TextStyle(
                    fontSize: 12,
                    color: color,
                    fontWeight: color != null ? FontWeight.w600 : null,
                  ),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildChecklistDetails(BuildContext context,
      HappySunProject project, ChecklistData checklistData) {
    final toolsWithNotes =
        checklistData.items.where((item) => item.notes.isNotEmpty).length;

    return [
      _buildDetailRow(
        'Time',
        '${checklistData.completedAt.hour.toString().padLeft(2, '0')}:${checklistData.completedAt.minute.toString().padLeft(2, '0')}',
      ),
      _buildDetailRow(
        'Tools Verified',
        '${checklistData.verifiedCount} / ${checklistData.totalTools}',
      ),
      if (checklistData.brokenCount > 0)
        _buildDetailRow(
          'Broken Tools',
          '${checklistData.brokenCount}',
          color: Colors.orange,
        ),
      if (checklistData.missingCount > 0)
        _buildDetailRow(
          'Missing Tools',
          '${checklistData.missingCount}',
          color: Colors.red,
        ),
      if (toolsWithNotes > 0)
        _buildDetailRow(
          'Tools with Notes',
          '$toolsWithNotes',
          color: Colors.blue,
        ),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => _handleChecklist(context, project),
        icon: const Icon(Icons.checklist, size: 16),
        label: const Text('View Checklist'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.blue,
          side: const BorderSide(color: Colors.blue),
        ),
      ),
    ];
  }

  void _handleCheckout(BuildContext context, HappySunProject project) {
    // Navigate to the checkout screen
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HappySunCheckoutScreen(project: project),
      ),
    );
  }

  void _showToolsTakenDialog(BuildContext context, HappySunProject project) {
    final toolsUsed = project.toolsUsedCategorized;
    if (toolsUsed == null) return;
    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      builder: (context) => Consumer<InventoryProvider>(
        builder: (context, inventoryProvider, child) => Dialog(
          insetPadding: isMobile
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          child: Container(
            width: isMobile ? double.infinity : 700,
            height: isMobile ? double.infinity : null,
            constraints: isMobile ? null : const BoxConstraints(maxHeight: 800),
            child: Column(
              mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: EdgeInsets.all(isMobile ? 12 : 16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.green.shade700, Colors.green.shade500],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        padding: EdgeInsets.all(isMobile ? 8 : 10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius:
                              BorderRadius.circular(isMobile ? 8 : 10),
                        ),
                        child: Icon(
                          Icons.inventory_2,
                          color: Colors.white,
                          size: isMobile ? 20 : 28,
                        ),
                      ),
                      SizedBox(width: isMobile ? 8 : 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Checkout Details',
                              style: TextStyle(
                                fontSize: isMobile ? 16 : 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            if (project.startTime != null)
                              Text(
                                'Checked out at ${project.startTime!.hour.toString().padLeft(2, '0')}:${project.startTime!.minute.toString().padLeft(2, '0')} on ${project.scheduledDate.day}/${project.scheduledDate.month}/${project.scheduledDate.year}',
                                style: TextStyle(
                                  fontSize: isMobile ? 10 : 12,
                                  color: Colors.white70,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close,
                            color: Colors.white, size: isMobile ? 20 : 24),
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                // Info banner
                Container(
                  padding: EdgeInsets.all(isMobile ? 8 : 12),
                  color: Colors.green.shade50,
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Colors.green.shade700,
                          size: isMobile ? 16 : 20),
                      SizedBox(width: isMobile ? 6 : 8),
                      Expanded(
                        child: Text(
                          'All tools below were checked out and are saved in the database',
                          style: TextStyle(
                            fontSize: isMobile ? 10 : 12,
                            color: Colors.green.shade700,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Tools list
                Flexible(
                  child: ListView(
                    padding: EdgeInsets.all(isMobile ? 12 : 16),
                    children: [
                      if (toolsUsed.teamTools.isNotEmpty) ...[
                        _buildToolCategorySection(
                          'Team Tools',
                          toolsUsed.teamTools,
                          Colors.blue,
                          project,
                          inventoryProvider.tools,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (toolsUsed.individualTools.isNotEmpty) ...[
                        _buildToolCategorySection(
                          'Individual Tools',
                          toolsUsed.individualTools,
                          Colors.green,
                          project,
                          inventoryProvider.tools,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (toolsUsed.extras.isNotEmpty) ...[
                        _buildToolCategorySection(
                          'Extras',
                          toolsUsed.extras,
                          Colors.purple,
                          project,
                          inventoryProvider.tools,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (toolsUsed.accessories.isNotEmpty) ...[
                        _buildToolCategorySection(
                          'Accessories',
                          toolsUsed.accessories,
                          Colors.orange,
                          project,
                          inventoryProvider.tools,
                        ),
                      ],
                    ],
                  ),
                ),
                // Footer with summary
                Container(
                  padding: EdgeInsets.all(isMobile ? 12 : 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    border: Border(
                      top: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      isMobile
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Total Tools: ${toolsUsed.totalCount}',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Team: ${toolsUsed.teamTools.fold<int>(0, (sum, t) => sum + t.totalQuantity)} • '
                                  'Individual: ${toolsUsed.individualTools.fold<int>(0, (sum, t) => sum + t.totalQuantity)} • '
                                  'Extras: ${toolsUsed.extras.fold<int>(0, (sum, t) => sum + t.totalQuantity)} • '
                                  'Accessories: ${toolsUsed.accessories.fold<int>(0, (sum, t) => sum + t.totalQuantity)}',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.grey.shade600,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                SizedBox(
                                  width: double.infinity,
                                  child: ElevatedButton.icon(
                                    onPressed: () => Navigator.pop(context),
                                    icon: const Icon(Icons.check, size: 18),
                                    label: const Text('Close'),
                                    style: ElevatedButton.styleFrom(
                                      backgroundColor: Colors.green,
                                      foregroundColor: Colors.white,
                                    ),
                                  ),
                                ),
                              ],
                            )
                          : Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Total Tools: ${toolsUsed.totalCount}',
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      'Team: ${toolsUsed.teamTools.fold<int>(0, (sum, t) => sum + t.totalQuantity)} • '
                                      'Individual: ${toolsUsed.individualTools.fold<int>(0, (sum, t) => sum + t.totalQuantity)} • '
                                      'Extras: ${toolsUsed.extras.fold<int>(0, (sum, t) => sum + t.totalQuantity)} • '
                                      'Accessories: ${toolsUsed.accessories.fold<int>(0, (sum, t) => sum + t.totalQuantity)}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Colors.grey.shade600,
                                      ),
                                    ),
                                  ],
                                ),
                                ElevatedButton.icon(
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.check),
                                  label: const Text('Close'),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: Colors.green,
                                    foregroundColor: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _showCheckinDetailsDialog(
      BuildContext context, HappySunProject project) {
    final toolsUsed = project.toolsUsedCategorized;
    if (toolsUsed == null) return;

    final isMobile = MediaQuery.of(context).size.width < 600;

    showDialog(
      context: context,
      builder: (context) => Consumer<InventoryProvider>(
        builder: (context, inventoryProvider, child) => Dialog(
          insetPadding: isMobile
              ? EdgeInsets.zero
              : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
          child: Container(
            width: isMobile ? double.infinity : 600,
            height: isMobile ? double.infinity : null,
            constraints: isMobile ? null : const BoxConstraints(maxHeight: 700),
            child: Column(
              mainAxisSize: isMobile ? MainAxisSize.max : MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: EdgeInsets.all(isMobile ? 12 : 20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.green.shade700, Colors.green.shade500],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.check_circle,
                        color: Colors.white,
                        size: isMobile ? 20 : 32,
                      ),
                      SizedBox(width: isMobile ? 10 : 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Check-in Completed',
                              style: TextStyle(
                                fontSize: isMobile ? 14 : 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            SizedBox(height: isMobile ? 2 : 4),
                            if (project.endTime != null)
                              Text(
                                'Completed at ${project.endTime!.hour.toString().padLeft(2, '0')}:${project.endTime!.minute.toString().padLeft(2, '0')} on ${project.scheduledDate.day}/${project.scheduledDate.month}/${project.scheduledDate.year}',
                                style: TextStyle(
                                  fontSize: isMobile ? 9 : 12,
                                  color: Colors.white70,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.close,
                            color: Colors.white, size: isMobile ? 20 : 24),
                        onPressed: () => Navigator.pop(context),
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    ],
                  ),
                ),
                // Summary banner
                Container(
                  padding: EdgeInsets.all(isMobile ? 10 : 16),
                  color: Colors.green.shade50,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildSummaryColumn(
                        'Total Tools',
                        '${toolsUsed.totalCount}',
                        Icons.build_circle,
                        Colors.green,
                        isMobile,
                      ),
                      if (project.workDuration != null)
                        _buildSummaryColumn(
                          'Duration',
                          '${project.workDuration!.inHours}h ${project.workDuration!.inMinutes.remainder(60)}m',
                          Icons.timer,
                          Colors.green,
                          isMobile,
                        ),
                      if (project.checklistData != null)
                        _buildSummaryColumn(
                          'Status',
                          'All tools checked',
                          Icons.verified,
                          Colors.green,
                          isMobile,
                        ),
                    ],
                  ),
                ),
                // Tools list
                Expanded(
                  child: ListView(
                    padding: EdgeInsets.all(isMobile ? 10 : 16),
                    children: [
                      if (toolsUsed.teamTools.isNotEmpty) ...[
                        _buildCheckinToolCategory(
                          'Team Tools',
                          toolsUsed.teamTools,
                          Colors.blue,
                          project,
                          inventoryProvider.tools,
                          isMobile,
                        ),
                        SizedBox(height: isMobile ? 10 : 16),
                      ],
                      if (toolsUsed.individualTools.isNotEmpty) ...[
                        _buildCheckinToolCategory(
                          'Individual Tools',
                          toolsUsed.individualTools,
                          Colors.green,
                          project,
                          inventoryProvider.tools,
                          isMobile,
                        ),
                        SizedBox(height: isMobile ? 10 : 16),
                      ],
                      if (toolsUsed.extras.isNotEmpty) ...[
                        _buildCheckinToolCategory(
                          'Extras',
                          toolsUsed.extras,
                          Colors.purple,
                          project,
                          inventoryProvider.tools,
                          isMobile,
                        ),
                        SizedBox(height: isMobile ? 10 : 16),
                      ],
                      if (toolsUsed.accessories.isNotEmpty) ...[
                        _buildCheckinToolCategory(
                          'Accessories',
                          toolsUsed.accessories,
                          Colors.orange,
                          project,
                          inventoryProvider.tools,
                          isMobile,
                        ),
                      ],
                    ],
                  ),
                ),
                // Footer
                Container(
                  padding: EdgeInsets.all(isMobile ? 10 : 16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    border: Border(
                      top: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      ElevatedButton.icon(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.check, size: isMobile ? 16 : 20),
                        label: Text(
                          'Close',
                          style: TextStyle(fontSize: isMobile ? 13 : 14),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          padding: EdgeInsets.symmetric(
                            horizontal: isMobile ? 16 : 20,
                            vertical: isMobile ? 10 : 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSummaryColumn(
      String label, String value, IconData icon, Color color,
      [bool isMobile = false]) {
    return Column(
      children: [
        Icon(icon, color: color, size: isMobile ? 18 : 24),
        SizedBox(height: isMobile ? 4 : 8),
        Text(
          value,
          style: TextStyle(
            fontSize: isMobile ? 13 : 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        SizedBox(height: isMobile ? 2 : 4),
        Text(
          label,
          style: TextStyle(
            fontSize: isMobile ? 9 : 12,
            color: Colors.grey.shade600,
          ),
        ),
      ],
    );
  }

  Widget _buildCheckinToolCategory(
    String title,
    List<GroupedToolItem> tools,
    Color color,
    HappySunProject project,
    List<InventoryTool> inventoryTools, [
    bool isMobile = false,
  ]) {
    // Check if checklist exists to show condition status
    final hasChecklist = project.checklistData != null;
    final checklistItems = hasChecklist
        ? {for (var item in project.checklistData!.items) item.toolId: item}
        : <String, ToolChecklistItem>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: color, size: isMobile ? 16 : 20),
            SizedBox(width: isMobile ? 6 : 8),
            Text(
              title,
              style: TextStyle(
                fontSize: isMobile ? 13 : 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            SizedBox(width: isMobile ? 6 : 8),
            Container(
              padding: EdgeInsets.symmetric(
                  horizontal: isMobile ? 6 : 8, vertical: isMobile ? 1 : 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
              ),
              child: Text(
                '${tools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity)}',
                style: TextStyle(
                  fontSize: isMobile ? 10 : 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ],
        ),
        SizedBox(height: isMobile ? 8 : 12),
        ...tools.map((tool) => Card(
              elevation: 0,
              color: Colors.grey.shade50,
              margin: EdgeInsets.only(bottom: isMobile ? 6 : 8),
              child: Padding(
                padding: EdgeInsets.all(isMobile ? 8 : 12),
                child: Row(
                  children: [
                    Icon(
                      _getCategoryIcon(tool.category),
                      size: isMobile ? 16 : 20,
                      color: color,
                    ),
                    SizedBox(width: isMobile ? 8 : 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tool.baseName,
                            style: TextStyle(
                              fontSize: isMobile ? 12 : 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(height: isMobile ? 3 : 4),
                          Wrap(
                            spacing: isMobile ? 3 : 4,
                            runSpacing: isMobile ? 3 : 4,
                            children: tool.toolIds.map((id) {
                              final readableId =
                                  _getReadableToolId(id, inventoryTools);
                              final checklistItem = checklistItems[id];
                              final hasNote =
                                  checklistItem?.notes.isNotEmpty ?? false;

                              return Container(
                                padding: EdgeInsets.symmetric(
                                  horizontal: isMobile ? 6 : 8,
                                  vertical: isMobile ? 3 : 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.1),
                                  borderRadius:
                                      BorderRadius.circular(isMobile ? 10 : 12),
                                  border: Border.all(
                                    color: Colors.green.withOpacity(0.3),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check,
                                      size: isMobile ? 10 : 12,
                                      color: Colors.green.shade700,
                                    ),
                                    SizedBox(width: isMobile ? 3 : 4),
                                    Text(
                                      readableId,
                                      style: TextStyle(
                                        fontSize: isMobile ? 9 : 11,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                    if (hasNote) ...[
                                      SizedBox(width: isMobile ? 3 : 4),
                                      Icon(
                                        Icons.note,
                                        size: isMobile ? 10 : 12,
                                        color: Colors.blue.shade700,
                                      ),
                                    ],
                                  ],
                                ),
                              );
                            }).toList(),
                          ),
                        ],
                      ),
                    ),
                    Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: isMobile ? 8 : 12,
                        vertical: isMobile ? 4 : 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(isMobile ? 10 : 12),
                      ),
                      child: Text(
                        '×${tool.totalQuantity}',
                        style: TextStyle(
                          fontSize: isMobile ? 12 : 14,
                          fontWeight: FontWeight.bold,
                          color: Colors.green.shade700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )),
      ],
    );
  }

  String _getReadableToolId(String firestoreId, List<InventoryTool> tools) {
    final tool = tools.firstWhere(
      (t) => t.id == firestoreId,
      orElse: () => InventoryTool(
        id: firestoreId,
        toolId: firestoreId,
        name: 'Unknown',
        description: '',
        category: 'Unknown',
        qrCode: '',
        createdAt: DateTime.now(),
      ),
    );
    return tool.toolId;
  }

  Widget _buildToolCategorySection(
    String title,
    List<GroupedToolItem> tools,
    Color color,
    HappySunProject project,
    List<InventoryTool> inventoryTools,
  ) {
    // Check if checklist exists to show condition status
    final hasChecklist = project.checklistData != null;
    final checklistItems = hasChecklist
        ? {for (var item in project.checklistData!.items) item.toolId: item}
        : <String, ToolChecklistItem>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 20,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: color.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '${tools.fold<int>(0, (sum, tool) => sum + tool.totalQuantity)}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...tools.map((tool) => Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          _getCategoryIcon(tool.category),
                          size: 20,
                          color: color,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tool.baseName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        Text(
                          '×${tool.totalQuantity}',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.grey.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      tool.category,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    if (tool.toolIds.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: tool.toolIds.map((id) {
                          final readableId =
                              _getReadableToolId(id, inventoryTools);
                          final checklistItem = checklistItems[id];
                          final hasIssue = checklistItem != null &&
                              checklistItem.status != 'present';
                          final hasNote =
                              checklistItem?.notes.isNotEmpty ?? false;

                          return Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: hasIssue
                                  ? (checklistItem.status == 'broken'
                                      ? Colors.orange.withOpacity(0.2)
                                      : Colors.red.withOpacity(0.2))
                                  : color.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: hasIssue
                                    ? (checklistItem.status == 'broken'
                                        ? Colors.orange
                                        : Colors.red)
                                    : color.withOpacity(0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  readableId,
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w500,
                                    color: hasIssue
                                        ? (checklistItem.status == 'broken'
                                            ? Colors.orange.shade700
                                            : Colors.red.shade700)
                                        : color,
                                  ),
                                ),
                                if (hasIssue) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    checklistItem.status == 'broken'
                                        ? Icons.build
                                        : Icons.warning,
                                    size: 12,
                                    color: checklistItem.status == 'broken'
                                        ? Colors.orange.shade700
                                        : Colors.red.shade700,
                                  ),
                                ] else if (hasNote) ...[
                                  const SizedBox(width: 4),
                                  Icon(
                                    Icons.note,
                                    size: 12,
                                    color: Colors.blue.shade700,
                                  ),
                                ],
                              ],
                            ),
                          );
                        }).toList(),
                      ),
                      // Show legend if there are issues
                      if (hasChecklist &&
                          tool.toolIds.any((id) {
                            final item = checklistItems[id];
                            return item != null && item.status != 'present';
                          })) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.amber.shade50,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: Colors.amber.shade200),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.info_outline,
                                  size: 16, color: Colors.amber.shade700),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'Some tools have condition notes. Check checklist for details.',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.amber.shade900,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                ),
              ),
            )),
      ],
    );
  }

  void _handleChecklist(BuildContext context, HappySunProject project) async {
    // Navigate to the checklist screen and wait for result
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HappySunChecklistScreen(project: project),
      ),
    );
    // UI will auto-refresh via provider stream subscription
  }

  void _handleCheckin(BuildContext context, HappySunProject project) async {
    // Navigate to the checkin screen
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HappySunCheckinScreen(project: project),
      ),
    );
    // UI will auto-refresh via provider stream subscription
  }

  void _showToolsDialog(BuildContext context, HappySunProject project) async {
    final inventoryProvider = context.read<InventoryProvider>();
    final projectProvider = context.read<HappySunProjectProvider>();

    // Initialize inventory if needed
    if (inventoryProvider.tools.isEmpty && !inventoryProvider.isLoading) {
      inventoryProvider.initialize();
    }

    if (!context.mounted) return;

    // Show streamlined inline tools dialog
    await showDialog(
      context: context,
      builder: (context) => _InlineToolsDialog(
        project: project,
        currentTools: project.toolsNeeded ?? CategorizedTools.empty(),
        availableTools: inventoryProvider.tools,
        onSave: (updatedTools) async {
          // Update the project with new categorized tools
          await projectProvider.updateToolsNeeded(
            project.id,
            project.scheduledDate,
            updatedTools,
          );

          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Tools updated successfully'),
                backgroundColor: Colors.green,
              ),
            );
          }
        },
      ),
    );
  }

  Widget _buildMonthButton(
    BuildContext context,
    HappySunProjectProvider provider,
    String label,
    DateTime targetMonth,
  ) {
    final isSelected = provider.currentMonth.year == targetMonth.year &&
        provider.currentMonth.month == targetMonth.month;

    return ElevatedButton(
      onPressed: () {
        provider.setMonth(targetMonth.year, targetMonth.month);
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: isSelected ? Colors.orange : null,
        foregroundColor: isSelected ? Colors.white : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        elevation: isSelected ? 2 : 0,
      ),
      child: Text(label),
    );
  }

  String _getMonthYearText(DateTime date) {
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
    return '${months[date.month - 1]} ${date.year}';
  }

  Future<void> _showMonthPicker(
    BuildContext context,
    HappySunProjectProvider provider,
  ) async {
    final currentMonth = provider.currentMonth;
    int? selectedYear = currentMonth.year;
    int? selectedMonth = currentMonth.month;

    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Select Month'),
              content: SizedBox(
                width: 300,
                height: 400,
                child: Column(
                  children: [
                    // Year selector
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.chevron_left),
                          onPressed: () {
                            setState(() {
                              selectedYear = selectedYear! - 1;
                            });
                          },
                        ),
                        Text(
                          '$selectedYear',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.chevron_right),
                          onPressed: () {
                            setState(() {
                              selectedYear = selectedYear! + 1;
                            });
                          },
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    // Month grid
                    Expanded(
                      child: GridView.builder(
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: 3,
                          childAspectRatio: 2,
                          crossAxisSpacing: 8,
                          mainAxisSpacing: 8,
                        ),
                        itemCount: 12,
                        itemBuilder: (context, index) {
                          final month = index + 1;
                          final isSelected = month == selectedMonth;
                          const monthNames = [
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

                          return ElevatedButton(
                            onPressed: () {
                              setState(() {
                                selectedMonth = month;
                              });
                            },
                            style: ElevatedButton.styleFrom(
                              backgroundColor:
                                  isSelected ? Colors.orange : null,
                              foregroundColor: isSelected ? Colors.white : null,
                            ),
                            child: Text(monthNames[index]),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context, {
                      'year': selectedYear!,
                      'month': selectedMonth!,
                    });
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.orange,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('OK'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      provider.setMonth(result['year']!, result['month']!);
    }
  }

  IconData _getCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'cleaning':
        return Icons.cleaning_services;
      case 'safety':
        return Icons.shield;
      case 'electrical':
        return Icons.electrical_services;
      case 'access':
        return Icons.stairs;
      default:
        return Icons.build;
    }
  }

  // Handle before images - open viewer
  void _handleBeforeImages(BuildContext context, HappySunProject project) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ImageViewerScreen(
          project: project,
          imageType: 'before',
          title: 'Before Images',
          addButtonText: 'Add from Gallery',
        ),
      ),
    );
  }

  // Handle after images - open viewer
  void _handleAfterImages(BuildContext context, HappySunProject project) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => _ImageViewerScreen(
          project: project,
          imageType: 'after',
          title: 'After Images',
          addButtonText: 'Take Photo',
        ),
      ),
    );
  }
}

// Image Viewer Screen - View and add before/after images
class _ImageViewerScreen extends StatefulWidget {
  final HappySunProject project;
  final String imageType; // 'before' or 'after'
  final String title;
  final String addButtonText;

  const _ImageViewerScreen({
    required this.project,
    required this.imageType,
    required this.title,
    required this.addButtonText,
  });

  @override
  State<_ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<_ImageViewerScreen> {
  late PageController _pageController;
  int _currentPage = 0;
  bool _isUploading = false;
  double _uploadProgress = 0.0;
  String _uploadStatus = '';

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  List<String> get _images {
    return widget.imageType == 'before'
        ? (widget.project.beforeImages ?? [])
        : (widget.project.afterImages ?? []);
  }

  Future<void> _addImages() async {
    try {
      final picker = ImagePicker();
      List<XFile> pickedFiles = [];

      if (widget.imageType == 'before') {
        // Show dialog to choose between image and video
        final mediaType = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Add Media'),
            content: const Text('What would you like to add?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'image'),
                child: const Text('Images'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'video'),
                child: const Text('Video'),
              ),
            ],
          ),
        );

        if (mediaType == null) return;

        if (mediaType == 'image') {
          pickedFiles = await picker.pickMultiImage();
        } else {
          final pickedFile =
              await picker.pickVideo(source: ImageSource.gallery);
          if (pickedFile != null) {
            pickedFiles = [pickedFile];
          }
        }
      } else {
        // For after, show choice between camera photo or video
        final mediaType = await showDialog<String>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Capture Media'),
            content: const Text('What would you like to capture?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, 'image'),
                child: const Text('Photo'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, 'video'),
                child: const Text('Video'),
              ),
            ],
          ),
        );

        if (mediaType == null) return;

        if (mediaType == 'image') {
          final pickedFile = await picker.pickImage(
              source: ImageSource.camera, imageQuality: 80);
          if (pickedFile != null) {
            pickedFiles = [pickedFile];
          }
        } else {
          final pickedFile = await picker.pickVideo(source: ImageSource.camera);
          if (pickedFile != null) {
            pickedFiles = [pickedFile];
          }
        }
      }

      if (pickedFiles.isEmpty) return;

      if (!mounted) return;

      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
        _uploadStatus = 'Preparing upload...';
      });

      final projectProvider = context.read<HappySunProjectProvider>();
      final List<String> uploadedUrls = [];

      // Upload images to Firebase Storage
      for (int i = 0; i < pickedFiles.length; i++) {
        final pickedFile = pickedFiles[i];
        setState(() {
          _uploadStatus = 'Processing file ${i + 1}/${pickedFiles.length}...';
        });

        Uint8List bytes = await pickedFile.readAsBytes();
        final fileName = DateTime.now().millisecondsSinceEpoch.toString();

        // Get file extension from the picked file, default to jpg if not available
        String extension = 'jpg';
        if (pickedFile.name.contains('.')) {
          extension = pickedFile.name.split('.').last.toLowerCase();
        } else if (pickedFile.path.contains('.')) {
          extension = pickedFile.path.split('.').last.toLowerCase();
        }

        // Convert HEIC/HEIF images to PNG for better browser compatibility
        if (['heic', 'heif'].contains(extension)) {
          try {
            setState(() {
              _uploadStatus = 'Converting ${extension.toUpperCase()} to PNG...';
            });
            final image = img.decodeImage(bytes);
            if (image != null) {
              bytes = Uint8List.fromList(img.encodePng(image));
              extension = 'png';
            }
          } catch (e) {
            print('Error converting HEIC to PNG: $e');
            // Continue with original if conversion fails
          }
        }

        final monthFolder =
            '${widget.project.scheduledDate.year}-${widget.project.scheduledDate.month.toString().padLeft(2, '0')}';
        final ref = FirebaseStorage.instance.ref().child(
            'happySunProjects/$monthFolder/${widget.project.id}/${widget.imageType}/$fileName.$extension');

        // Set metadata with correct content type
        final metadata = SettableMetadata(
          contentType: _getContentType(extension),
        );

        setState(() {
          _uploadStatus = 'Uploading ${i + 1}/${pickedFiles.length}...';
        });

        // Upload with progress tracking
        final uploadTask = ref.putData(bytes, metadata);

        uploadTask.snapshotEvents.listen((TaskSnapshot snapshot) {
          final progress = snapshot.bytesTransferred / snapshot.totalBytes;
          if (mounted) {
            setState(() {
              _uploadProgress = progress;
            });
          }
        });

        await uploadTask;
        final url = await ref.getDownloadURL();
        uploadedUrls.add(url);
      }

      // Update project with new images
      final updatedImages = [
        ..._images,
        ...uploadedUrls,
      ];

      final fieldName =
          widget.imageType == 'before' ? 'beforeImages' : 'afterImages';
      await projectProvider.updateProjectFields(
        widget.project.id,
        widget.project.scheduledDate,
        {fieldName: updatedImages},
      );

      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
        _uploadStatus = '';
      });

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              '${uploadedUrls.length} media file(s) uploaded successfully'),
          backgroundColor: Colors.green,
        ),
      );

      // Navigate to first new image
      if (uploadedUrls.isNotEmpty) {
        _pageController.animateToPage(
          _images.length - uploadedUrls.length,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
        );
      }
    } catch (e, stackTrace) {
      print('Upload error: $e');
      print('Stack trace: $stackTrace');
      if (!mounted) return;
      setState(() {
        _isUploading = false;
        _uploadProgress = 0.0;
        _uploadStatus = '';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error uploading: ${e.toString()}'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
        ),
      );
    }
  }

  Future<void> _deleteImage(int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Image'),
        content: const Text('Are you sure you want to delete this image?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final projectProvider = context.read<HappySunProjectProvider>();
      final updatedImages = List<String>.from(_images)..removeAt(index);

      final fieldName =
          widget.imageType == 'before' ? 'beforeImages' : 'afterImages';
      await projectProvider.updateProjectFields(
        widget.project.id,
        widget.project.scheduledDate,
        {fieldName: updatedImages},
      );

      if (!mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Image deleted'),
          backgroundColor: Colors.orange,
        ),
      );

      // Navigate to previous page if current page is deleted
      if (_currentPage >= updatedImages.length) {
        final newPage = updatedImages.isEmpty ? 0 : updatedImages.length - 1;
        _pageController.jumpToPage(newPage);
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error deleting image: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalPages = _images.length + 1; // Images + add page

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        backgroundColor:
            widget.imageType == 'before' ? Colors.blue : Colors.green,
        actions: [
          if (_currentPage < _images.length)
            IconButton(
              icon: const Icon(Icons.delete),
              onPressed: () => _deleteImage(_currentPage),
              tooltip: 'Delete Image',
            ),
        ],
      ),
      body: Stack(
        children: [
          PageView.builder(
            controller: _pageController,
            onPageChanged: (page) {
              setState(() => _currentPage = page);
            },
            itemCount: totalPages,
            itemBuilder: (context, index) {
              // Last page is the add button
              if (index == _images.length) {
                return _buildAddImagePage();
              }

              // Regular image/video pages
              return _buildMediaPage(_images[index]);
            },
          ),
          // Navigation arrows
          if (totalPages > 1)
            Positioned.fill(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (_currentPage > 0)
                    IconButton(
                      icon: const Icon(Icons.arrow_back_ios, size: 40),
                      color: Colors.white,
                      onPressed: () {
                        _pageController.previousPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                    )
                  else
                    const SizedBox(width: 48),
                  if (_currentPage < totalPages - 1)
                    IconButton(
                      icon: const Icon(Icons.arrow_forward_ios, size: 40),
                      color: Colors.white,
                      onPressed: () {
                        _pageController.nextPage(
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeInOut,
                        );
                      },
                    )
                  else
                    const SizedBox(width: 48),
                ],
              ),
            ),
          // Page indicator
          Positioned(
            bottom: 16,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '${_currentPage + 1} / $totalPages',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMediaPage(String mediaUrl) {
    if (_isVideo(mediaUrl)) {
      return _VideoPlayerWidget(videoUrl: mediaUrl);
    }

    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 4.0,
      child: Center(
        child: Image.network(
          mediaUrl,
          fit: BoxFit.contain,
          loadingBuilder: (context, child, loadingProgress) {
            if (loadingProgress == null) return child;
            return Center(
              child: CircularProgressIndicator(
                value: loadingProgress.expectedTotalBytes != null
                    ? loadingProgress.cumulativeBytesLoaded /
                        loadingProgress.expectedTotalBytes!
                    : null,
              ),
            );
          },
          errorBuilder: (context, error, stackTrace) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.broken_image, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text(
                    'Failed to load image',
                    style: TextStyle(color: Colors.grey),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildAddImagePage() {
    return Container(
      color: Colors.grey.shade100,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              widget.imageType == 'before'
                  ? Icons.add_photo_alternate
                  : Icons.add_a_photo,
              size: 120,
              color: widget.imageType == 'before' ? Colors.blue : Colors.green,
            ),
            const SizedBox(height: 32),
            if (_isUploading) ...[
              SizedBox(
                width: 200,
                child: Column(
                  children: [
                    LinearProgressIndicator(
                      value: _uploadProgress,
                      backgroundColor: Colors.grey.shade300,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        widget.imageType == 'before'
                            ? Colors.blue
                            : Colors.green,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '${(_uploadProgress * 100).toInt()}%',
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _uploadStatus,
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey.shade600,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ],
            if (!_isUploading)
              ElevatedButton.icon(
                onPressed: _addImages,
                icon: Icon(
                  widget.imageType == 'before'
                      ? Icons.photo_library
                      : Icons.camera_alt,
                ),
                label: Text(widget.addButtonText),
                style: ElevatedButton.styleFrom(
                  backgroundColor:
                      widget.imageType == 'before' ? Colors.blue : Colors.green,
                  foregroundColor: Colors.white,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                  textStyle: const TextStyle(fontSize: 18),
                ),
              ),
            if (_images.isEmpty) ...[
              const SizedBox(height: 24),
              Text(
                'No ${widget.imageType} images yet',
                style: TextStyle(
                  fontSize: 16,
                  color: Colors.grey.shade600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _getContentType(String extension) {
    switch (extension.toLowerCase()) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'heic':
        return 'image/heic';
      case 'heif':
        return 'image/heif';
      case 'bmp':
        return 'image/bmp';
      case 'tiff':
      case 'tif':
        return 'image/tiff';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'avi':
        return 'video/x-msvideo';
      case 'mkv':
        return 'video/x-matroska';
      case 'webm':
        return 'video/webm';
      case '3gp':
        return 'video/3gpp';
      default:
        return 'image/jpeg'; // Default fallback
    }
  }

  bool _isVideo(String url) {
    final extension = url.split('.').last.toLowerCase().split('?').first;
    return ['mp4', 'mov', 'avi', 'mkv', 'webm', '3gp'].contains(extension);
  }
}

// Video Player Widget for playing videos with controls
class _VideoPlayerWidget extends StatefulWidget {
  final String videoUrl;

  const _VideoPlayerWidget({required this.videoUrl});

  @override
  State<_VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<_VideoPlayerWidget> {
  late VideoPlayerController _controller;
  bool _isInitialized = false;
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      print('🎥 Initializing video player for: ${widget.videoUrl}');

      // Parse and validate the URL
      final uri = Uri.parse(widget.videoUrl);
      print('   Parsed URI: $uri');
      print('   Scheme: ${uri.scheme}');
      print('   Host: ${uri.host}');

      _controller = VideoPlayerController.networkUrl(
        uri,
        videoPlayerOptions: VideoPlayerOptions(
          mixWithOthers: true,
          allowBackgroundPlayback: false,
        ),
      );

      _controller.addListener(() {
        if (_controller.value.hasError) {
          final errorDesc =
              _controller.value.errorDescription ?? 'Unknown error';
          print('❌ Video player error: $errorDesc');
          print(
              '   Error type: ${_controller.value.errorDescription.runtimeType}');
          if (mounted) {
            setState(() {
              _hasError = true;
              _errorMessage = errorDesc;
            });
          }
        }
      });

      print('   Initializing controller...');
      await _controller.initialize();
      print('✅ Video initialized successfully');
      print('   Duration: ${_controller.value.duration}');
      print('   Size: ${_controller.value.size}');
      print('   Aspect Ratio: ${_controller.value.aspectRatio}');

      if (mounted) {
        setState(() => _isInitialized = true);
        // Auto play on load
        _controller.play();
      }
    } catch (e, stackTrace) {
      print('❌ Error initializing video: $e');
      print('   Error type: ${e.runtimeType}');
      print('   Stack trace: $stackTrace');
      if (mounted) {
        setState(() {
          _hasError = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              const Text(
                'Failed to load video',
                style: TextStyle(
                  color: Colors.grey,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _errorMessage ?? 'Unknown error',
                style: TextStyle(color: Colors.grey.shade600, fontSize: 12),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              Text(
                'Video URL: ${widget.videoUrl}',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 10),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      );
    }

    if (!_isInitialized) {
      return const Center(
        child: CircularProgressIndicator(),
      );
    }

    return Center(
      child: AspectRatio(
        aspectRatio: _controller.value.aspectRatio,
        child: Stack(
          alignment: Alignment.center,
          children: [
            VideoPlayer(_controller),
            // Play/Pause overlay
            _buildControlsOverlay(),
            // Progress bar at bottom
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildProgressBar(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsOverlay() {
    return GestureDetector(
      onTap: () {
        setState(() {
          if (_controller.value.isPlaying) {
            _controller.pause();
          } else {
            _controller.play();
          }
        });
      },
      child: Container(
        color: Colors.transparent,
        child: Center(
          child: AnimatedOpacity(
            opacity: _controller.value.isPlaying ? 0.0 : 1.0,
            duration: const Duration(milliseconds: 300),
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: Icon(
                _controller.value.isPlaying ? Icons.pause : Icons.play_arrow,
                color: Colors.white,
                size: 50,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar() {
    return VideoProgressIndicator(
      _controller,
      allowScrubbing: true,
      colors: VideoProgressColors(
        playedColor: Colors.blue,
        bufferedColor: Colors.grey,
        backgroundColor: Colors.white24,
      ),
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
    );
  }
}

// Inline Tools Dialog - Shows all tools with quick add/remove buttons
class _InlineToolsDialog extends StatefulWidget {
  final HappySunProject project;
  final CategorizedTools currentTools;
  final List<dynamic> availableTools;
  final Function(CategorizedTools) onSave;

  const _InlineToolsDialog({
    required this.project,
    required this.currentTools,
    required this.availableTools,
    required this.onSave,
  });

  @override
  State<_InlineToolsDialog> createState() => _InlineToolsDialogState();
}

class _InlineToolsDialogState extends State<_InlineToolsDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Working copies of tools
  late Map<String, _ToolEntry> _teamTools;
  late Map<String, _ToolEntry> _individualTools;
  late Map<String, _ToolEntry> _extrasTools;
  late Map<String, _ToolEntry> _accessoriesTools;

  bool _hasChanges = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _initializeTools();
  }

  void _initializeTools() {
    // Group available tools by base name and category
    final toolsByBaseName = <String, List<dynamic>>{};
    for (final tool in widget.availableTools) {
      final baseName = _extractBaseName(tool.name);
      toolsByBaseName.putIfAbsent(baseName, () => []).add(tool);
    }

    // Initialize team tools
    _teamTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty &&
          tools.first.toolType.toString() == 'ToolType.team') {
        final category = tools.first.category;
        final currentQty = widget.currentTools.teamTools
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _teamTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }

    // Initialize individual tools
    _individualTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty &&
          tools.first.toolType.toString() == 'ToolType.individual') {
        final category = tools.first.category;
        final currentQty = widget.currentTools.individualTools
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _individualTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }

    // Initialize extras
    _extrasTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty &&
          tools.first.toolType.toString() == 'ToolType.extras') {
        final category = tools.first.category;
        final currentQty = widget.currentTools.extras
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _extrasTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }

    // Initialize accessories
    _accessoriesTools = {};
    for (final entry in toolsByBaseName.entries) {
      final baseName = entry.key;
      final tools = entry.value;
      if (tools.isNotEmpty &&
          tools.first.toolType.toString() == 'ToolType.accessories') {
        final category = tools.first.category;
        final currentQty = widget.currentTools.accessories
            .where((t) => t.baseName == baseName)
            .fold(0, (sum, t) => sum + t.totalQuantity);
        _accessoriesTools[baseName] = _ToolEntry(
          baseName: baseName,
          category: category,
          quantity: currentQty,
          availableCount: tools.length,
        );
      }
    }
  }

  String _extractBaseName(String toolName) {
    // Extract "Ladder" from "Ladder #1"
    final parts = toolName.split(' #');
    return parts.first;
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  void _incrementTool(String baseName, Map<String, _ToolEntry> toolsMap) {
    setState(() {
      final entry = toolsMap[baseName]!;
      if (entry.quantity < entry.availableCount) {
        entry.quantity++;
        _hasChanges = true;
      }
    });
  }

  void _decrementTool(String baseName, Map<String, _ToolEntry> toolsMap) {
    setState(() {
      final entry = toolsMap[baseName]!;
      if (entry.quantity > 0) {
        entry.quantity--;
        _hasChanges = true;
      }
    });
  }

  CategorizedTools _buildCategorizedTools() {
    debugPrint('\n🔧 Building categorized tools with accessories...');

    // Helper to get base name
    String getBaseName(String toolName) {
      final hashIndex = toolName.lastIndexOf('#');
      if (hashIndex > 0) {
        return toolName.substring(0, hashIndex).trim();
      }
      return toolName;
    }

    // Track all tools including accessories
    final Map<String, Map<String, dynamic>> allToolsMap = {};

    // Track manually selected accessories first
    final Map<String, int> manualAccessories = {};
    for (final entry
        in _accessoriesTools.entries.where((e) => e.value.quantity > 0)) {
      manualAccessories[entry.key] = entry.value.quantity;
    }

    // Process team tools and their accessories
    debugPrint('   Processing team tools...');
    for (final entry in _teamTools.entries.where((e) => e.value.quantity > 0)) {
      final baseName = entry.key;
      final toolEntry = entry.value;

      debugPrint('      Team tool: $baseName × ${toolEntry.quantity}');
      allToolsMap[baseName] = {
        'category': toolEntry.category,
        'quantity': toolEntry.quantity,
        'type': 'team',
      };

      // Find accessories for this tool using requiredAccessories
      final matchingTools = widget.availableTools
          .where((t) => getBaseName(t.name) == baseName)
          .toList();

      if (matchingTools.isNotEmpty) {
        final tool = matchingTools.first;
        debugPrint('         Checking accessories for: ${tool.name}');
        debugPrint(
            '         Required accessories: ${tool.requiredAccessories.length}');

        // Process requiredAccessories (base name + quantity per tool)
        for (final accessoryReq in tool.requiredAccessories) {
          final accessoryBaseName = accessoryReq.baseName;
          final qtyPerTool = accessoryReq.quantity;
          final totalQty = qtyPerTool * toolEntry.quantity;

          debugPrint(
              '            + Accessory: $accessoryBaseName ($qtyPerTool × ${toolEntry.quantity} = $totalQty)');

          // Find the actual accessory tool to get its category
          final accessoryTool = widget.availableTools
              .where((t) => getBaseName(t.name) == accessoryBaseName)
              .firstOrNull;

          if (accessoryTool != null) {
            // Add required accessories (accumulate across multiple parent tools)
            if (!allToolsMap.containsKey(accessoryBaseName)) {
              allToolsMap[accessoryBaseName] = {
                'category': accessoryTool.category,
                'quantity': totalQty,
                'type': 'accessories',
              };
              debugPrint(
                  '            ✓ Added accessory with quantity $totalQty');
            } else {
              // Accumulate - add to existing quantity
              final currentQty = allToolsMap[accessoryBaseName]!['quantity'];
              allToolsMap[accessoryBaseName]!['quantity'] =
                  currentQty + totalQty;
              debugPrint(
                  '            ✓ Accumulated accessory: $currentQty + $totalQty = ${currentQty + totalQty}');
            }
          } else {
            debugPrint(
                '            ⚠️ Accessory tool not found: $accessoryBaseName');
          }
        }
      }
    }

    // Process individual tools and their accessories
    debugPrint('   Processing individual tools...');
    for (final entry
        in _individualTools.entries.where((e) => e.value.quantity > 0)) {
      final baseName = entry.key;
      final toolEntry = entry.value;

      debugPrint('      Individual tool: $baseName × ${toolEntry.quantity}');
      if (!allToolsMap.containsKey(baseName)) {
        allToolsMap[baseName] = {
          'category': toolEntry.category,
          'quantity': 0,
          'type': 'individual',
        };
      }
      allToolsMap[baseName]!['quantity'] += toolEntry.quantity;

      // Find accessories for this tool using requiredAccessories
      final matchingTools = widget.availableTools
          .where((t) => getBaseName(t.name) == baseName)
          .toList();

      if (matchingTools.isNotEmpty) {
        final tool = matchingTools.first;
        debugPrint('         Checking accessories for: ${tool.name}');
        debugPrint(
            '         Required accessories: ${tool.requiredAccessories.length}');

        // Process requiredAccessories (base name + quantity per tool)
        for (final accessoryReq in tool.requiredAccessories) {
          final accessoryBaseName = accessoryReq.baseName;
          final qtyPerTool = accessoryReq.quantity;
          final totalQty = qtyPerTool * toolEntry.quantity;

          debugPrint(
              '            + Accessory: $accessoryBaseName ($qtyPerTool × ${toolEntry.quantity} = $totalQty)');

          // Find the actual accessory tool to get its category
          final accessoryTool = widget.availableTools
              .where((t) => getBaseName(t.name) == accessoryBaseName)
              .firstOrNull;

          if (accessoryTool != null) {
            // Add required accessories (accumulate across multiple parent tools)
            if (!allToolsMap.containsKey(accessoryBaseName)) {
              allToolsMap[accessoryBaseName] = {
                'category': accessoryTool.category,
                'quantity': totalQty,
                'type': 'accessories',
              };
              debugPrint(
                  '            ✓ Added accessory with quantity $totalQty');
            } else {
              // Accumulate - add to existing quantity
              final currentQty = allToolsMap[accessoryBaseName]!['quantity'];
              allToolsMap[accessoryBaseName]!['quantity'] =
                  currentQty + totalQty;
              debugPrint(
                  '            ✓ Accumulated accessory: $currentQty + $totalQty = ${currentQty + totalQty}');
            }
          } else {
            debugPrint(
                '            ⚠️ Accessory tool not found: $accessoryBaseName');
          }
        }
      }
    }

    // Process extras (no accessories typically)
    debugPrint('   Processing extras...');
    for (final entry
        in _extrasTools.entries.where((e) => e.value.quantity > 0)) {
      final baseName = entry.key;
      final toolEntry = entry.value;

      debugPrint('      Extra: $baseName × ${toolEntry.quantity}');
      if (!allToolsMap.containsKey(baseName)) {
        allToolsMap[baseName] = {
          'category': toolEntry.category,
          'quantity': 0,
          'type': 'extras',
        };
      }
      allToolsMap[baseName]!['quantity'] += toolEntry.quantity;
    }

    // Process manually selected accessories
    // Only add if they exceed auto-calculated requirements
    debugPrint('   Processing manually selected accessories...');
    for (final entry
        in _accessoriesTools.entries.where((e) => e.value.quantity > 0)) {
      final baseName = entry.key;
      final toolEntry = entry.value;
      final manualQty = toolEntry.quantity;

      debugPrint('      Manual accessory: $baseName × $manualQty');

      if (!allToolsMap.containsKey(baseName)) {
        // Not auto-added, so add it manually
        allToolsMap[baseName] = {
          'category': toolEntry.category,
          'quantity': manualQty,
          'type': 'accessories',
        };
        debugPrint('         ✓ Added manual selection');
      } else {
        // Check if manual selection is more than auto-calculated
        final autoQty = allToolsMap[baseName]!['quantity'];
        if (manualQty > autoQty) {
          allToolsMap[baseName]!['quantity'] = manualQty;
          debugPrint(
              '         ✓ Using manual quantity $manualQty (auto was $autoQty)');
        } else {
          debugPrint(
              '         ⊘ Keeping auto quantity $autoQty (manual was $manualQty)');
        }
      }
    }

    // Convert to GroupedToolItems by type
    final teamTools = allToolsMap.entries
        .where((e) => e.value['type'] == 'team')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: List.generate(e.value['quantity'], (_) => ''),
            ))
        .toList();

    final individualTools = allToolsMap.entries
        .where((e) => e.value['type'] == 'individual')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: List.generate(e.value['quantity'], (_) => ''),
            ))
        .toList();

    final extras = allToolsMap.entries
        .where((e) => e.value['type'] == 'extras')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: List.generate(e.value['quantity'], (_) => ''),
            ))
        .toList();

    final accessories = allToolsMap.entries
        .where((e) => e.value['type'] == 'accessories')
        .map((e) => GroupedToolItem(
              baseName: e.key,
              category: e.value['category'],
              totalQuantity: e.value['quantity'],
              toolIds: List.generate(e.value['quantity'], (_) => ''),
            ))
        .toList();

    debugPrint(
        '   ✅ Final: ${teamTools.length} team, ${individualTools.length} individual, ${extras.length} extras, ${accessories.length} accessories\n');

    return CategorizedTools(
      teamTools: teamTools,
      individualTools: individualTools,
      extras: extras,
      accessories: accessories,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
      insetPadding: isMobile ? EdgeInsets.zero : const EdgeInsets.all(40),
      child: SizedBox(
        width: isMobile
            ? MediaQuery.of(context).size.width
            : MediaQuery.of(context).size.width * 0.7,
        height: isMobile
            ? MediaQuery.of(context).size.height
            : MediaQuery.of(context).size.height * 0.8,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.orange.shade50,
                border: Border(
                  bottom: BorderSide(color: Colors.orange.shade200),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.build_circle, color: Colors.orange),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Tools Needed ',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        'Click +/- to adjust quantities',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  if (_hasChanges)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.orange,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: const Text(
                        'Unsaved changes',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Tabs
            TabBar(
              controller: _tabController,
              labelColor: Colors.orange,
              unselectedLabelColor: Colors.grey,
              indicatorColor: Colors.orange,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: [
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Team Tools'),
                      const SizedBox(width: 8),
                      _buildCountChip(
                          _teamTools.values
                              .fold(0, (sum, e) => sum + e.quantity),
                          Colors.blue),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Individual'),
                      const SizedBox(width: 8),
                      _buildCountChip(
                          _individualTools.values
                              .fold(0, (sum, e) => sum + e.quantity),
                          Colors.green),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Extras'),
                      const SizedBox(width: 8),
                      _buildCountChip(
                          _extrasTools.values
                              .fold(0, (sum, e) => sum + e.quantity),
                          Colors.purple),
                    ],
                  ),
                ),
                Tab(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('Accessories'),
                      const SizedBox(width: 8),
                      _buildCountChip(
                          _accessoriesTools.values
                              .fold(0, (sum, e) => sum + e.quantity),
                          Colors.orange),
                    ],
                  ),
                ),
              ],
            ),
            // Tool lists
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildToolsList(_teamTools, Colors.blue),
                  _buildToolsList(_individualTools, Colors.green),
                  _buildToolsList(_extrasTools, Colors.purple),
                  _buildToolsList(_accessoriesTools, Colors.orange),
                ],
              ),
            ),
            // Footer buttons
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.grey.shade50,
                border: Border(
                  top: BorderSide(color: Colors.grey.shade300),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'Total: ${_teamTools.values.fold(0, (sum, e) => sum + e.quantity) + _individualTools.values.fold(0, (sum, e) => sum + e.quantity) + _extrasTools.values.fold(0, (sum, e) => sum + e.quantity) + _accessoriesTools.values.fold(0, (sum, e) => sum + e.quantity)} tools',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Row(
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: (_hasChanges && !_isSaving)
                            ? () async {
                                setState(() => _isSaving = true);
                                final updatedTools = _buildCategorizedTools();
                                await widget.onSave(updatedTools);
                                // Wait a moment for Firestore stream to propagate the change
                                await Future.delayed(
                                    const Duration(milliseconds: 500));
                                if (mounted) {
                                  Navigator.pop(context);
                                }
                              }
                            : null,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.orange,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 24,
                            vertical: 12,
                          ),
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                      Colors.white),
                                ),
                              )
                            : const Text('Save Changes'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCountChip(int count, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        '$count',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
          color: color,
        ),
      ),
    );
  }

  Widget _buildToolsList(Map<String, _ToolEntry> toolsMap, Color accentColor) {
    if (toolsMap.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.inventory_2_outlined,
                size: 64, color: Colors.grey.shade300),
            const SizedBox(height: 16),
            Text(
              'No tools available in this category',
              style: TextStyle(color: Colors.grey.shade600),
            ),
          ],
        ),
      );
    }

    final sortedEntries = toolsMap.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: sortedEntries.length,
      itemBuilder: (context, index) {
        final entry = sortedEntries[index];
        final toolEntry = entry.value;
        final isAdded = toolEntry.quantity > 0;

        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          elevation: isAdded ? 2 : 0,
          color: isAdded ? null : const Color.fromARGB(255, 240, 240, 240),
          child: ListTile(
            leading: Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: accentColor.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _getCategoryIcon(toolEntry.category),
                color: accentColor,
                size: 24,
              ),
            ),
            title: Text(
              entry.key,
              style: TextStyle(
                fontWeight: isAdded ? FontWeight.bold : FontWeight.normal,
              ),
            ),
            subtitle: Text(
              '${toolEntry.category} • ${toolEntry.availableCount} available',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.remove_circle_outline),
                  color: toolEntry.quantity > 0
                      ? Colors.red
                      : Colors.grey.shade300,
                  onPressed: toolEntry.quantity > 0
                      ? () => _decrementTool(entry.key, toolsMap)
                      : null,
                ),
                Container(
                  width: 40,
                  alignment: Alignment.center,
                  child: Text(
                    '${toolEntry.quantity}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isAdded ? accentColor : Colors.grey,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  color: toolEntry.quantity < toolEntry.availableCount
                      ? Colors.green
                      : Colors.grey.shade300,
                  onPressed: toolEntry.quantity < toolEntry.availableCount
                      ? () => _incrementTool(entry.key, toolsMap)
                      : null,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  IconData _getCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'cleaning':
        return Icons.cleaning_services;
      case 'safety':
        return Icons.shield;
      case 'electrical':
        return Icons.electrical_services;
      case 'access':
        return Icons.stairs;
      default:
        return Icons.build;
    }
  }
}

// Helper class to track tool quantities
class _ToolEntry {
  final String baseName;
  final String category;
  int quantity;
  final int availableCount;

  _ToolEntry({
    required this.baseName,
    required this.category,
    required this.quantity,
    required this.availableCount,
  });
}
