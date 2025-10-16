import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/distributor.dart';
import '../providers/schedule_provider.dart';
import '../services/schedule_tracking_service.dart';

class ScheduleTrackingView extends StatefulWidget {
  const ScheduleTrackingView({super.key});

  @override
  State<ScheduleTrackingView> createState() => _ScheduleTrackingViewState();
}

class _ScheduleTrackingViewState extends State<ScheduleTrackingView> {
  DateTime _selectedDate = DateTime.now();
  late ScheduleTrackingService _trackingService;

  @override
  void initState() {
    super.initState();
    final scheduleProvider =
        Provider.of<ScheduleProvider>(context, listen: false);
    _trackingService = ScheduleTrackingService(scheduleProvider);
  }

  Future<void> _selectDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      builder: (context, child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
                  primary: Colors.blue,
                ),
          ),
          child: child!,
        );
      },
    );

    if (picked != null && picked != _selectedDate) {
      setState(() {
        _selectedDate = picked;
      });
    }
  }

  void _changeDate(int days) {
    setState(() {
      _selectedDate = _selectedDate.add(Duration(days: days));
    });
  }

  void _goToToday() {
    setState(() {
      _selectedDate = DateTime.now();
    });
  }

  Future<void> _callPhone(String? phoneNumber) async {
    if (phoneNumber == null || phoneNumber.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No phone number available')),
      );
      return;
    }

    final Uri phoneUri = Uri(scheme: 'tel', path: phoneNumber);
    try {
      if (await canLaunchUrl(phoneUri)) {
        await launchUrl(phoneUri);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
                content: Text('Cannot make phone calls on this device')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }

  Widget _buildDateSelector() {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Previous day
            IconButton(
              onPressed: () => _changeDate(-1),
              icon: const Icon(Icons.chevron_left),
              tooltip: 'Previous day',
            ),

            // Date display and picker
            Expanded(
              child: InkWell(
                onTap: _selectDate,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.calendar_today, size: 20),
                      const SizedBox(width: 8),
                      Text(
                        DateFormat('EEEE, MMMM d, yyyy').format(_selectedDate),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // Next day
            IconButton(
              onPressed: () => _changeDate(1),
              icon: const Icon(Icons.chevron_right),
              tooltip: 'Next day',
            ),

            const SizedBox(width: 16),

            // Today button
            ElevatedButton.icon(
              onPressed: _goToToday,
              icon: const Icon(Icons.today, size: 18),
              label: const Text('Today'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blue,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCards(TrackingSheetSummary summary) {
    return Row(
      children: [
        Expanded(
          child: _buildSummaryCard(
            'Total Distributors',
            summary.totalDistributors.toString(),
            Icons.people,
            Colors.blue,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildSummaryCard(
            'Assigned',
            summary.assignedDistributors.toString(),
            Icons.assignment_turned_in,
            Colors.green,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildSummaryCard(
            'Available',
            summary.availableDistributors.toString(),
            Icons.check_circle,
            Colors.orange,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: _buildSummaryCard(
            'Total Jobs',
            summary.totalJobs.toString(),
            Icons.work,
            Colors.purple,
          ),
        ),
      ],
    );
  }

  Widget _buildSummaryCard(
      String title, String value, IconData icon, Color color) {
    return Card(
      elevation: 2,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, size: 32, color: color),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTrackingTable(List<TrackingSheetEntry> entries) {
    if (entries.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            children: [
              Icon(Icons.inbox, size: 64, color: Colors.grey.shade400),
              const SizedBox(height: 16),
              Text(
                'No active distributors found',
                style: TextStyle(
                  fontSize: 18,
                  color: Colors.grey.shade600,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Add distributors or change their status to Active',
                style: TextStyle(
                  color: Colors.grey.shade500,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      elevation: 2,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          columns: const [
            DataColumn(
                label: Text('Distributor',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(
                label: Text('Phone 1',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(
                label: Text('Phone 2',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(
                label: Text('Status',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(
                label: Text('Jobs',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(
                label: Text('Clients',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(
                label: Text('Working Areas',
                    style: TextStyle(fontWeight: FontWeight.bold))),
            DataColumn(
                label: Text('Actions',
                    style: TextStyle(fontWeight: FontWeight.bold))),
          ],
          rows: entries.map((entry) => _buildDataRow(entry)).toList(),
        ),
      ),
    );
  }

  DataRow _buildDataRow(TrackingSheetEntry entry) {
    return DataRow(
      cells: [
        // Distributor name
        DataCell(
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: _getStatusColor(entry.status).withOpacity(0.2),
                child: Text(
                  entry.distributorName.isNotEmpty
                      ? entry.distributorName[0].toUpperCase()
                      : '?',
                  style: TextStyle(
                    color: _getStatusColor(entry.status),
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(entry.distributorName),
            ],
          ),
        ),

        // Phone 1
        DataCell(
          entry.phone1 != null
              ? InkWell(
                  onTap: () => _callPhone(entry.phone1),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.phone, size: 16, color: Colors.green.shade700),
                      const SizedBox(width: 4),
                      Text(
                        entry.phone1!,
                        style: TextStyle(
                          color: Colors.green.shade700,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                )
              : const Text('-', style: TextStyle(color: Colors.grey)),
        ),

        // Phone 2
        DataCell(
          entry.phone2 != null && entry.phone2!.isNotEmpty
              ? InkWell(
                  onTap: () => _callPhone(entry.phone2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.phone_android,
                          size: 16, color: Colors.blue.shade700),
                      const SizedBox(width: 4),
                      Text(
                        entry.phone2!,
                        style: TextStyle(
                          color: Colors.blue.shade700,
                          decoration: TextDecoration.underline,
                        ),
                      ),
                    ],
                  ),
                )
              : const Text('-', style: TextStyle(color: Colors.grey)),
        ),

        // Status
        DataCell(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: _getStatusColor(entry.status).withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: _getStatusColor(entry.status).withOpacity(0.3)),
            ),
            child: Text(
              entry.status.displayName,
              style: TextStyle(
                color: _getStatusColor(entry.status),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),

        // Jobs count
        DataCell(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: entry.jobs.isEmpty
                  ? Colors.grey.shade100
                  : Colors.blue.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              entry.jobs.length.toString(),
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: entry.jobs.isEmpty ? Colors.grey : Colors.blue.shade700,
              ),
            ),
          ),
        ),

        // Clients
        DataCell(
          SizedBox(
            width: 200,
            child: Text(
              entry.clientsText,
              style: TextStyle(
                fontSize: 12,
                color: entry.jobs.isEmpty ? Colors.grey : null,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ),

        // Working Areas
        DataCell(
          SizedBox(
            width: 200,
            child: Text(
              entry.workingAreasText,
              style: TextStyle(
                fontSize: 12,
                color: entry.jobs.isEmpty ? Colors.grey : null,
              ),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
            ),
          ),
        ),

        // Actions
        DataCell(
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (entry.phone1 != null)
                IconButton(
                  icon: const Icon(Icons.call, size: 18),
                  onPressed: () => _callPhone(entry.phone1),
                  tooltip: 'Call ${entry.phone1}',
                  color: Colors.green,
                ),
              if (entry.phone2 != null && entry.phone2!.isNotEmpty)
                IconButton(
                  icon: const Icon(Icons.phone_android, size: 18),
                  onPressed: () => _callPhone(entry.phone2),
                  tooltip: 'Call ${entry.phone2}',
                  color: Colors.blue,
                ),
            ],
          ),
        ),
      ],
    );
  }

  Color _getStatusColor(DistributorStatus status) {
    switch (status) {
      case DistributorStatus.active:
        return Colors.green;
      case DistributorStatus.inactive:
        return Colors.grey;
      case DistributorStatus.suspended:
        return Colors.red;
      case DistributorStatus.onLeave:
        return Colors.orange;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Schedule Tracking'),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () => setState(() {}),
            tooltip: 'Refresh data',
          ),
        ],
      ),
      body: Consumer<ScheduleProvider>(
        builder: (context, scheduleProvider, child) {
          final trackingEntries =
              _trackingService.generateTrackingSheet(_selectedDate);
          final summary = _trackingService.getTrackingSummary(trackingEntries);

          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Date selector
                _buildDateSelector(),

                const SizedBox(height: 16),

                // Summary cards
                _buildSummaryCards(summary),

                const SizedBox(height: 16),

                // Tracking table
                Expanded(
                  child: _buildTrackingTable(trackingEntries),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
