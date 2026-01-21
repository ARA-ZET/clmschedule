import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/happy_sun_job.dart';
import '../models/job_list_item.dart';
import '../providers/happy_sun_job_provider.dart';
import '../providers/job_list_provider.dart';
import '../providers/inventory_provider.dart';
import 'happy_sun_tools_needed_dialog.dart';

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
                          Tab(text: 'All Jobs (${allJobs.length})'),
                          Tab(text: 'Pending ($pendingCount)'),
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
                  _buildJobsList('pending'),
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

            if (statusFilter == 'pending') {
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
                      : statusFilter == 'pending'
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
        // Tools Needed button
        OutlinedButton.icon(
          onPressed: () => _showToolsNeededDialog(context, job),
          icon: const Icon(Icons.build_circle, size: 18),
          label: Text(
            job.toolsNeeded.isEmpty
                ? 'Tools Needed'
                : 'Tools Needed (${job.toolsNeeded.fold(0, (sum, tool) => sum + tool.quantity)})',
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
    final hasCheckout = job.toolsUsed.isNotEmpty || job.startTime != null;

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
          _buildDetailRow('Tools Taken', '${job.totalToolsUsed}'),
          if (job.toolsUsed.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text(
              'By Category:',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.grey,
              ),
            ),
            ...job.toolsUsed
                .fold<Map<String, int>>(
                  {},
                  (map, tool) {
                    map[tool.category] =
                        (map[tool.category] ?? 0) + tool.quantity;
                    return map;
                  },
                )
                .entries
                .map((entry) => Padding(
                      padding: const EdgeInsets.only(left: 8, top: 4),
                      child: Text(
                        '${entry.key}: ${entry.value}',
                        style: const TextStyle(fontSize: 12),
                      ),
                    )),
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
        ] else if (isComplete) ...[
          _buildDetailRow('Status', 'Completed'),
          if (job.notes != null) _buildDetailRow('Notes', job.notes!),
        ] else ...[
          const Text(
            'Job in progress',
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
        ] else if (job.startTime == null) ...[
          const Text(
            'Complete checkout first',
            style: TextStyle(color: Colors.grey),
          ),
        ] else ...[
          const Text(
            'Not checked in yet',
            style: TextStyle(color: Colors.grey),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: () => _handleCheckin(context, job),
            icon: const Icon(Icons.login, size: 18),
            label: const Text('Check In'),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.green,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildDetailRow(String label, String value) {
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
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  void _handleCheckout(BuildContext context, HappySunJob job) {
    // TODO: Show checkout dialog with tool selection
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Checkout Tools'),
        content: const Text(
          'Checkout functionality will allow team to:\n'
          '• Record checkout time\n'
          '• Select tools from inventory\n'
          '• Assign team members\n'
          '• Add notes',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              // Record start time
              context.read<HappySunJobProvider>().recordStartTime(
                    job.id,
                    job.date,
                    DateTime.now(),
                  );
              Navigator.pop(context);
            },
            child: const Text('Start Job'),
          ),
        ],
      ),
    );
  }

  void _handleChecklist(BuildContext context, HappySunJob job) {
    // TODO: Show checklist dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('On-Site Checklist'),
        content: const Text(
          'Checklist functionality will allow team to:\n'
          '• Verify all tools are packed\n'
          '• Check work quality\n'
          '• Add photos\n'
          '• Record weather conditions\n'
          '• Add completion notes',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _handleCheckin(BuildContext context, HappySunJob job) {
    // TODO: Show checkin dialog
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Check In'),
        content: const Text(
          'Check-in functionality will allow team to:\n'
          '• Record return time\n'
          '• Verify all tools returned\n'
          '• Submit final report\n'
          '• Mark job complete',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              // Record end time
              context.read<HappySunJobProvider>().recordEndTime(
                    job.id,
                    job.date,
                    DateTime.now(),
                  );
              Navigator.pop(context);
            },
            child: const Text('Complete Job'),
          ),
        ],
      ),
    );
  }

  void _showToolsNeededDialog(BuildContext context, HappySunJob job) {
    // Initialize inventory provider if needed
    final inventoryProvider = context.read<InventoryProvider>();
    if (inventoryProvider.tools.isEmpty && !inventoryProvider.isLoading) {
      inventoryProvider.initialize();
    }

    showDialog(
      context: context,
      builder: (context) => HappySunToolsNeededDialog(job: job),
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
}
