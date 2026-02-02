import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_job.dart';
import '../models/inventory_tool.dart';
import '../models/job_list_item.dart';
import '../providers/happy_sun_job_provider.dart';
import '../providers/happy_sun_project_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/inventory_provider.dart';
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

  @override
  Widget build(BuildContext context) {
    return Consumer<HappySunJobProvider>(
      builder: (context, happySunProvider, child) {
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);

        final allJobs = happySunProvider.jobs;
        final pendingCount = allJobs.where((job) {
          final jobDate = DateTime(job.date.year, job.date.month, job.date.day);
          return jobDate.isAfter(today);
        }).length;
        final inProgressCount = allJobs.where((job) {
          final jobDate = DateTime(job.date.year, job.date.month, job.date.day);
          return jobDate.isAtSameMomentAs(today);
        }).length;
        final completedCount = allJobs.where((job) {
          final jobDate = DateTime(job.date.year, job.date.month, job.date.day);
          return jobDate.isBefore(today);
        }).length;

        return Column(
          children: [
            // Top bar with tabs and month filters
            Material(
              elevation: 2,
              child: Container(
                color: Theme.of(context).colorScheme.surface,
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  children: [
                    // Tabs on the left
                    Expanded(
                      child: TabBar(
                        controller: _tabController,
                        isScrollable: true,
                        tabs: [
                          Tab(text: 'All Projects (${allJobs.length})'),
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
                  ],
                ),
              ),
            ),
            Expanded(
              child: TabBarView(
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

  Widget _buildJobsList(String statusFilter) {
    return Consumer2<HappySunJobProvider, JobListProvider>(
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

        var jobs = happySunProvider.jobs;

        // Apply date-based status filter
        final now = DateTime.now();
        final today = DateTime(now.year, now.month, now.day);

        if (statusFilter != 'all') {
          jobs = jobs.where((job) {
            final jobDate =
                DateTime(job.date.year, job.date.month, job.date.day);

            if (statusFilter == 'confirmed') {
              return jobDate.isAfter(today);
            } else if (statusFilter == 'in-progress') {
              return jobDate.isAtSameMomentAs(today);
            } else if (statusFilter == 'completed') {
              return jobDate.isBefore(today);
            }
            return true;
          }).toList();
        }

        // Sort jobs by date (ascending)
        jobs.sort((a, b) => a.date.compareTo(b.date));

        if (jobs.isEmpty) {
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
          itemCount: jobs.length,
          itemBuilder: (context, index) {
            final job = jobs[index];
            // Get corresponding JobListItem for client details
            final jobListItem = jobListProvider.jobListItems.firstWhere(
              (item) => item.id == job.jobListItemId,
              orElse: () => JobListItem(
                id: job.id,
                invoice: '',
                amount: 0,
                client: 'Unknown Client',
                jobStatusId: job.statusId,
                invoiceStatusId: 'pending',
                jobType: job.isWindowCleaning
                    ? JobType.windowCleaning
                    : JobType.solarPanelCleaning,
                area: '',
                quantity: 0,
                manDays: 0,
                date: job.date,
                collectionAddress: '',
                collectionDate: job.date,
                specialInstructions: '',
                quantityDistributed: 0,
                invoiceDetails: '',
                reportAddresses: '',
                whoToInvoice: '',
              ),
            );

            return _buildJobCard(context, job, jobListItem);
          },
        );
      },
    );
  }

  Widget _buildJobCard(
      BuildContext context, HappySunJob job, JobListItem jobListItem) {
    // Determine border color based on date
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final jobDate = DateTime(job.date.year, job.date.month, job.date.day);

    Color borderColor;
    if (jobDate.isBefore(today)) {
      borderColor = Colors.green;
    } else if (jobDate.isAfter(today)) {
      borderColor = Colors.blue;
    } else {
      borderColor = Colors.orange;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 16),
      child: Container(
        padding:
            const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 16),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: borderColor,
              width: 10,
            ),
          ),
          borderRadius: const BorderRadius.only(
            topLeft: Radius.circular(4),
            bottomLeft: Radius.circular(4),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Section 1: Project Details
            Expanded(
              flex: 1,
              child: _buildProjectDetailsSection(job, jobListItem),
            ),
            const VerticalDivider(width: 32),
            // Section 2: Checkout
            Expanded(
              flex: 1,
              child: _buildCheckoutSection(context, job),
            ),
            const VerticalDivider(width: 32),
            // Section 3: Checklist
            Expanded(
              flex: 1,
              child: _buildChecklistSection(context, job),
            ),
            const VerticalDivider(width: 32),
            // Section 4: Checkin
            Expanded(
              flex: 1,
              child: _buildCheckinSection(context, job),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectDetailsSection(HappySunJob job, JobListItem jobListItem) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              job.isWindowCleaning
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
          jobListItem.jobType.displayName,
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => _showToolsDialog(context, job),
          icon: Icon(
              job.toolsNeededCategorized != null ? Icons.build : Icons.edit,
              size: 18),
          label: Text(
            job.toolsNeededCategorized != null
                ? 'Tools Needed (${job.toolsNeededCategorized!.totalCount})'
                : 'Add Tools',
          ),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.orange,
            side: const BorderSide(color: Colors.orange),
          ),
        ),
      ],
    );
  }

  Widget _buildCheckoutSection(BuildContext context, HappySunJob job) {
    final hasCheckout = job.startTime != null;
    final toolsUsed = job.toolsUsedCategorized;
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
          if (job.startTime != null)
            _buildDetailRow(
              'Time',
              '${job.startTime!.hour.toString().padLeft(2, '0')}:${job.startTime!.minute.toString().padLeft(2, '0')}',
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
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _showToolsTakenDialog(context, job),
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
            onPressed: () => _handleCheckout(context, job),
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

  Widget _buildChecklistSection(BuildContext context, HappySunJob job) {
    final hasChecklist = job.endTime == null && job.startTime != null;
    final isComplete = job.endTime != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              isComplete
                  ? Icons.check_circle
                  : hasChecklist
                      ? Icons.pending
                      : Icons.radio_button_unchecked,
              color: isComplete
                  ? Colors.green
                  : hasChecklist
                      ? Colors.orange
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
        if (job.startTime == null) ...[
          const Text(
            'Complete checkout first',
            style: TextStyle(color: Colors.grey),
          ),
        ] else if (job.checklistData != null)
          ..._buildChecklistDetails(context, job, job.checklistData!)
        else if (isComplete) ...[
          _buildDetailRow('Status', 'Completed (No Checklist)'),
          if (job.notes != null) _buildDetailRow('Notes', job.notes!),
        ] else ...[
          // Job in progress - checklist not done yet
          const Text(
            'Checklist not completed',
            style: TextStyle(color: Colors.orange),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _handleChecklist(context, job),
            icon: const Icon(Icons.checklist, size: 18),
            label: const Text('Do Checklist'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildCheckinSection(BuildContext context, HappySunJob job) {
    final hasCheckin = job.endTime != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              hasCheckin ? Icons.check_circle : Icons.radio_button_unchecked,
              color: hasCheckin ? Colors.green : Colors.grey,
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
        if (hasCheckin) ...[
          _buildDetailRow(
            'Time',
            '${job.endTime!.hour.toString().padLeft(2, '0')}:${job.endTime!.minute.toString().padLeft(2, '0')}',
          ),
          if (job.workDuration != null)
            _buildDetailRow(
              'Duration',
              '${job.workDuration!.inHours}h ${job.workDuration!.inMinutes.remainder(60)}m',
            ),
          _buildDetailRow('Status', 'Complete'),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => _showCheckinDetailsDialog(context, job),
            icon: const Icon(Icons.visibility, size: 18),
            label: const Text('View Check-in Details'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.green,
            ),
          ),
        ] else if (job.startTime == null) ...[
          const Text(
            'Complete checkout first',
            style: TextStyle(color: Colors.grey),
          ),
        ] else if (job.checklistData == null) ...[
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
            onPressed: () => _handleCheckin(context, job),
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

  List<Widget> _buildChecklistDetails(
      BuildContext context, HappySunJob job, ChecklistData checklistData) {
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
        onPressed: () => _handleChecklist(context, job),
        icon: const Icon(Icons.checklist, size: 16),
        label: const Text('View Checklist'),
        style: OutlinedButton.styleFrom(
          foregroundColor: Colors.blue,
          side: const BorderSide(color: Colors.blue),
        ),
      ),
    ];
  }

  void _handleCheckout(BuildContext context, HappySunJob job) {
    // Navigate to the checkout screen
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HappySunCheckoutScreen(job: job),
      ),
    );
  }

  void _showToolsTakenDialog(BuildContext context, HappySunJob job) {
    final toolsUsed = job.toolsUsedCategorized;
    if (toolsUsed == null) return;

    showDialog(
      context: context,
      builder: (context) => Consumer<InventoryProvider>(
        builder: (context, inventoryProvider, child) => Dialog(
          child: Container(
            width: 700,
            constraints: const BoxConstraints(maxHeight: 800),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(16),
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
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.2),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.inventory_2,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Checkout Details',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            if (job.startTime != null)
                              Text(
                                'Checked out at ${job.startTime!.hour.toString().padLeft(2, '0')}:${job.startTime!.minute.toString().padLeft(2, '0')} on ${job.date.day}/${job.date.month}/${job.date.year}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                // Info banner
                Container(
                  padding: const EdgeInsets.all(12),
                  color: Colors.green.shade50,
                  child: Row(
                    children: [
                      Icon(Icons.info_outline,
                          color: Colors.green.shade700, size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'All tools below were checked out and are saved in the database',
                          style: TextStyle(
                            fontSize: 12,
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
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (toolsUsed.teamTools.isNotEmpty) ...[
                        _buildToolCategorySection(
                          'Team Tools',
                          toolsUsed.teamTools,
                          Colors.blue,
                          job,
                          inventoryProvider.tools,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (toolsUsed.individualTools.isNotEmpty) ...[
                        _buildToolCategorySection(
                          'Individual Tools',
                          toolsUsed.individualTools,
                          Colors.green,
                          job,
                          inventoryProvider.tools,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (toolsUsed.extras.isNotEmpty) ...[
                        _buildToolCategorySection(
                          'Extras',
                          toolsUsed.extras,
                          Colors.purple,
                          job,
                          inventoryProvider.tools,
                        ),
                      ],
                    ],
                  ),
                ),
                // Footer with summary
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    border: Border(
                      top: BorderSide(color: Colors.grey.shade300),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                                'Extras: ${toolsUsed.extras.fold<int>(0, (sum, t) => sum + t.totalQuantity)}',
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

  void _showCheckinDetailsDialog(BuildContext context, HappySunJob job) {
    final toolsUsed = job.toolsUsedCategorized;
    if (toolsUsed == null) return;

    showDialog(
      context: context,
      builder: (context) => Consumer<InventoryProvider>(
        builder: (context, inventoryProvider, child) => Dialog(
          child: Container(
            width: 600,
            constraints: const BoxConstraints(maxHeight: 700),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Header
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.green.shade700, Colors.green.shade500],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.check_circle,
                        color: Colors.white,
                        size: 32,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Check-in Completed',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 4),
                            if (job.endTime != null)
                              Text(
                                'Completed at ${job.endTime!.hour.toString().padLeft(2, '0')}:${job.endTime!.minute.toString().padLeft(2, '0')} on ${job.date.day}/${job.date.month}/${job.date.year}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.white70,
                                ),
                              ),
                          ],
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, color: Colors.white),
                        onPressed: () => Navigator.pop(context),
                      ),
                    ],
                  ),
                ),
                // Summary banner
                Container(
                  padding: const EdgeInsets.all(16),
                  color: Colors.green.shade50,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceAround,
                    children: [
                      _buildSummaryColumn(
                        'Total Tools',
                        '${toolsUsed.totalCount}',
                        Icons.build_circle,
                        Colors.green,
                      ),
                      if (job.workDuration != null)
                        _buildSummaryColumn(
                          'Duration',
                          '${job.workDuration!.inHours}h ${job.workDuration!.inMinutes.remainder(60)}m',
                          Icons.timer,
                          Colors.green,
                        ),
                      if (job.checklistData != null)
                        _buildSummaryColumn(
                          'Status',
                          'All tools checked',
                          Icons.verified,
                          Colors.green,
                        ),
                    ],
                  ),
                ),
                // Tools list
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (toolsUsed.teamTools.isNotEmpty) ...[
                        _buildCheckinToolCategory(
                          'Team Tools',
                          toolsUsed.teamTools,
                          Colors.blue,
                          job,
                          inventoryProvider.tools,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (toolsUsed.individualTools.isNotEmpty) ...[
                        _buildCheckinToolCategory(
                          'Individual Tools',
                          toolsUsed.individualTools,
                          Colors.green,
                          job,
                          inventoryProvider.tools,
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (toolsUsed.extras.isNotEmpty) ...[
                        _buildCheckinToolCategory(
                          'Extras',
                          toolsUsed.extras,
                          Colors.purple,
                          job,
                          inventoryProvider.tools,
                        ),
                      ],
                    ],
                  ),
                ),
                // Footer
                Container(
                  padding: const EdgeInsets.all(16),
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
                        icon: const Icon(Icons.check),
                        label: const Text('Close'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
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
      String label, String value, IconData icon, Color color) {
    return Column(
      children: [
        Icon(icon, color: color, size: 24),
        const SizedBox(height: 8),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: color,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
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
    HappySunJob job,
    List<InventoryTool> inventoryTools,
  ) {
    // Check if checklist exists to show condition status
    final hasChecklist = job.checklistData != null;
    final checklistItems = hasChecklist
        ? {for (var item in job.checklistData!.items) item.toolId: item}
        : <String, ToolChecklistItem>{};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.check_circle, color: color, size: 20),
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
              elevation: 0,
              color: Colors.grey.shade50,
              margin: const EdgeInsets.only(bottom: 8),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    Icon(
                      _getCategoryIcon(tool.category),
                      size: 20,
                      color: color,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tool.baseName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: tool.toolIds.map((id) {
                              final readableId =
                                  _getReadableToolId(id, inventoryTools);
                              final checklistItem = checklistItems[id];
                              final hasNote =
                                  checklistItem?.notes.isNotEmpty ?? false;

                              return Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.green.withOpacity(0.1),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: Colors.green.withOpacity(0.3),
                                  ),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.check,
                                      size: 12,
                                      color: Colors.green.shade700,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      readableId,
                                      style: TextStyle(
                                        fontSize: 11,
                                        fontWeight: FontWeight.w500,
                                        color: Colors.green.shade700,
                                      ),
                                    ),
                                    if (hasNote) ...[
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
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.green.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '×${tool.totalQuantity}',
                        style: TextStyle(
                          fontSize: 14,
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
    HappySunJob job,
    List<InventoryTool> inventoryTools,
  ) {
    // Check if checklist exists to show condition status
    final hasChecklist = job.checklistData != null;
    final checklistItems = hasChecklist
        ? {for (var item in job.checklistData!.items) item.toolId: item}
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

  void _handleChecklist(BuildContext context, HappySunJob job) async {
    // Navigate to the checklist screen and wait for result
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HappySunChecklistScreen(job: job),
      ),
    );
    // UI will auto-refresh via provider stream subscription
  }

  void _handleCheckin(BuildContext context, HappySunJob job) async {
    // Navigate to the checkin screen
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => HappySunCheckinScreen(job: job),
      ),
    );
    // UI will auto-refresh via provider stream subscription
  }

  void _showToolsDialog(BuildContext context, HappySunJob job) async {
    final inventoryProvider = context.read<InventoryProvider>();
    final projectProvider = context.read<HappySunProjectProvider>();
    final jobProvider = context.read<HappySunJobProvider>();

    // Initialize inventory if needed
    if (inventoryProvider.tools.isEmpty && !inventoryProvider.isLoading) {
      inventoryProvider.initialize();
    }

    // Fetch the project using job's ID
    final project = projectProvider.getProjectById(job.id);

    if (!context.mounted) return;

    // Show streamlined inline tools dialog
    await showDialog(
      context: context,
      builder: (context) => _InlineToolsDialog(
        job: job,
        currentTools: job.toolsNeededCategorized ?? CategorizedTools(),
        availableTools: inventoryProvider.tools,
        onSave: (updatedTools) async {
          // Update the job with new categorized tools
          await jobProvider.updateToolsNeededFromManDays(
            job.id,
            job.date,
            0, // numberOfCleaners not used in this context
            updatedTools,
          );

          // If project exists, update it too
          if (project != null) {
            final updatedProject = project.copyWith(
              toolsNeeded: updatedTools,
            );
            await projectProvider.updateProject(updatedProject);
          }

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
    HappySunJobProvider provider,
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
    HappySunJobProvider provider,
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
}

// Inline Tools Dialog - Shows all tools with quick add/remove buttons
class _InlineToolsDialog extends StatefulWidget {
  final HappySunJob job;
  final CategorizedTools currentTools;
  final List<dynamic> availableTools;
  final Function(CategorizedTools) onSave;

  const _InlineToolsDialog({
    required this.job,
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

  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
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
      
      // Find accessories for this tool
      for (var i = 0; i < toolEntry.quantity; i++) {
        final matchingTools = widget.availableTools
            .where((t) => getBaseName(t.name) == baseName)
            .toList();
        
        if (matchingTools.isNotEmpty) {
          final tool = i < matchingTools.length ? matchingTools[i] : matchingTools.first;
          debugPrint('         Checking accessories for: ${tool.name}');
          debugPrint('         Accessory IDs: ${tool.accessoryIds}');
          
          for (final accessoryId in tool.accessoryIds) {
            try {
              final accessory = widget.availableTools.firstWhere(
                (t) => t.id == accessoryId,
              );
              
              final accessoryBaseName = getBaseName(accessory.name);
              debugPrint('            + Accessory: $accessoryBaseName');
              
              if (!allToolsMap.containsKey(accessoryBaseName)) {
                allToolsMap[accessoryBaseName] = {
                  'category': accessory.category,
                  'quantity': 0,
                  'type': 'individual', // Accessories go to individual
                };
              }
              allToolsMap[accessoryBaseName]!['quantity']++;
            } catch (e) {
              debugPrint('            ⚠️ Accessory not found: $accessoryId');
            }
          }
        }
      }
    }
    
    // Process individual tools and their accessories
    debugPrint('   Processing individual tools...');
    for (final entry in _individualTools.entries.where((e) => e.value.quantity > 0)) {
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
      
      // Find accessories for this tool
      for (var i = 0; i < toolEntry.quantity; i++) {
        final matchingTools = widget.availableTools
            .where((t) => getBaseName(t.name) == baseName)
            .toList();
        
        if (matchingTools.isNotEmpty) {
          final tool = i < matchingTools.length ? matchingTools[i] : matchingTools.first;
          debugPrint('         Checking accessories for: ${tool.name}');
          debugPrint('         Accessory IDs: ${tool.accessoryIds}');
          
          for (final accessoryId in tool.accessoryIds) {
            try {
              final accessory = widget.availableTools.firstWhere(
                (t) => t.id == accessoryId,
              );
              
              final accessoryBaseName = getBaseName(accessory.name);
              debugPrint('            + Accessory: $accessoryBaseName');
              
              if (!allToolsMap.containsKey(accessoryBaseName)) {
                allToolsMap[accessoryBaseName] = {
                  'category': accessory.category,
                  'quantity': 0,
                  'type': 'individual',
                };
              }
              allToolsMap[accessoryBaseName]!['quantity']++;
            } catch (e) {
              debugPrint('            ⚠️ Accessory not found: $accessoryId');
            }
          }
        }
      }
    }
    
    // Process extras (no accessories typically)
    debugPrint('   Processing extras...');
    for (final entry in _extrasTools.entries.where((e) => e.value.quantity > 0)) {
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

    debugPrint('   ✅ Final: ${teamTools.length} team, ${individualTools.length} individual, ${extras.length} extras\n');

    return CategorizedTools(
      teamTools: teamTools,
      individualTools: individualTools,
      extras: extras,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: SizedBox(
        width: MediaQuery.of(context).size.width * 0.7,
        height: MediaQuery.of(context).size.height * 0.8,
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
                        'Tools Needed',
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
                    'Total: ${_teamTools.values.fold(0, (sum, e) => sum + e.quantity) + _individualTools.values.fold(0, (sum, e) => sum + e.quantity) + _extrasTools.values.fold(0, (sum, e) => sum + e.quantity)} tools',
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
                        onPressed: _hasChanges
                            ? () {
                                final updatedTools = _buildCategorizedTools();
                                widget.onSave(updatedTools);
                                Navigator.pop(context);
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
                        child: const Text('Save Changes'),
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
