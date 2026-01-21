import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/happy_sun_project.dart';

class HappySunProjectCard extends StatelessWidget {
  final HappySunProject project;
  final VoidCallback? onTap;
  final VoidCallback? onCheckout;
  final VoidCallback? onChecklist;
  final VoidCallback? onCheckin;

  const HappySunProjectCard({
    super.key,
    required this.project,
    this.onTap,
    this.onCheckout,
    this.onChecklist,
    this.onCheckin,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 2,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Status badge
              _buildStatusBadge(),
              const SizedBox(height: 12),
              // 4-section layout
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Section 1: Project Details
                  Expanded(
                    child: _buildProjectDetailsSection(),
                  ),
                  const VerticalDivider(width: 1),
                  // Section 2: Checkout
                  Expanded(
                    child: _buildCheckoutSection(context),
                  ),
                  const VerticalDivider(width: 1),
                  // Section 3: Checklist
                  Expanded(
                    child: _buildChecklistSection(context),
                  ),
                  const VerticalDivider(width: 1),
                  // Section 4: Checkin
                  Expanded(
                    child: _buildCheckinSection(context),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBadge() {
    Color statusColor;
    String statusText;

    switch (project.status) {
      case 'pending':
        statusColor = Colors.orange;
        statusText = 'Pending';
        break;
      case 'in-progress':
        statusColor = Colors.blue;
        statusText = 'In Progress';
        break;
      case 'completed':
        statusColor = Colors.green;
        statusText = 'Completed';
        break;
      default:
        statusColor = Colors.grey;
        statusText = project.status;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: statusColor.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor),
      ),
      child: Text(
        statusText,
        style: TextStyle(
          color: statusColor,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildProjectDetailsSection() {
    final dateFormat = DateFormat('MMM dd, yyyy');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '📋 Project Details',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        _buildDetailRow('Client', project.clientName),
        _buildDetailRow('Address', project.address, maxLines: 2),
        _buildDetailRow('Date', dateFormat.format(project.scheduledDate)),
        if (project.scheduledTime != null)
          _buildDetailRow('Time', project.scheduledTime!),
        _buildDetailRow('Team Members', '${project.numberOfTeamMembers}'),
      ],
    );
  }

  Widget _buildCheckoutSection(BuildContext context) {
    final checkout = project.checkout;
    final hasCheckout = checkout?.checkoutTime != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '📦 Checkout',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        if (hasCheckout) ...[
          _buildDetailRow(
            'Time',
            DateFormat('HH:mm').format(checkout!.checkoutTime!),
          ),
          _buildDetailRow('Total Tools', '${checkout.totalToolsCount}'),
          const SizedBox(height: 4),
          const Text(
            'By Category:',
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500),
          ),
          ...checkout.toolsByCategory.entries.map((entry) => Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Text(
                  '${entry.key}: ${entry.value}',
                  style: const TextStyle(fontSize: 11),
                ),
              )),
          if (checkout.notes != null) ...[
            const SizedBox(height: 4),
            Text(
              'Notes: ${checkout.notes}',
              style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ] else ...[
          const Text(
            'Not checked out',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (onCheckout != null)
            ElevatedButton.icon(
              onPressed: onCheckout,
              icon: const Icon(Icons.logout, size: 16),
              label: const Text('Check Out', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildChecklistSection(BuildContext context) {
    final checklist = project.checklist;
    final hasChecklist = checklist?.checklistTime != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '✅ Checklist',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        if (hasChecklist) ...[
          _buildDetailRow(
            'Time',
            DateFormat('HH:mm').format(checklist!.checklistTime!),
          ),
          _buildDetailRow(
            'Items',
            '${checklist.checkedItemsCount}/${checklist.totalItemsCount}',
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                checklist.allItemsChecked ? Icons.check_circle : Icons.warning,
                size: 16,
                color: checklist.allItemsChecked ? Colors.green : Colors.orange,
              ),
              const SizedBox(width: 4),
              Text(
                checklist.allItemsChecked ? 'All checked' : 'Incomplete',
                style: TextStyle(
                  fontSize: 11,
                  color:
                      checklist.allItemsChecked ? Colors.green : Colors.orange,
                ),
              ),
            ],
          ),
          if (checklist.notes != null) ...[
            const SizedBox(height: 4),
            Text(
              'Notes: ${checklist.notes}',
              style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ] else ...[
          const Text(
            'Not completed',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (onChecklist != null && project.hasCheckout)
            ElevatedButton.icon(
              onPressed: onChecklist,
              icon: const Icon(Icons.checklist, size: 16),
              label:
                  const Text('Start Checklist', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildCheckinSection(BuildContext context) {
    final checkin = project.checkin;
    final hasCheckin = checkin?.checkinTime != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '🏢 Check-in',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            fontSize: 14,
          ),
        ),
        const SizedBox(height: 8),
        if (hasCheckin) ...[
          _buildDetailRow(
            'Time',
            DateFormat('HH:mm').format(checkin!.checkinTime!),
          ),
          _buildDetailRow('Returned', '${checkin.totalReturnedCount}'),
          if (checkin.missingTools.isNotEmpty)
            _buildDetailRow(
              'Missing',
              '${checkin.missingTools.length}',
              valueColor: Colors.red,
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                checkin.hasAllToolsReturned
                    ? Icons.check_circle
                    : Icons.warning,
                size: 16,
                color: checkin.hasAllToolsReturned ? Colors.green : Colors.red,
              ),
              const SizedBox(width: 4),
              Text(
                checkin.hasAllToolsReturned ? 'Complete' : 'Missing items',
                style: TextStyle(
                  fontSize: 11,
                  color:
                      checkin.hasAllToolsReturned ? Colors.green : Colors.red,
                ),
              ),
            ],
          ),
          if (checkin.notes != null) ...[
            const SizedBox(height: 4),
            Text(
              'Notes: ${checkin.notes}',
              style: const TextStyle(fontSize: 11, fontStyle: FontStyle.italic),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ] else ...[
          const Text(
            'Not checked in',
            style: TextStyle(color: Colors.grey, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (onCheckin != null && project.hasChecklist)
            ElevatedButton.icon(
              onPressed: onCheckin,
              icon: const Icon(Icons.login, size: 16),
              label: const Text('Check In', style: TextStyle(fontSize: 12)),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
            ),
        ],
      ],
    );
  }

  Widget _buildDetailRow(String label, String value,
      {int maxLines = 1, Color? valueColor}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontWeight: FontWeight.w500,
              fontSize: 12,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: valueColor,
              ),
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
