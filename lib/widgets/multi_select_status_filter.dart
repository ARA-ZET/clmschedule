import 'package:flutter/material.dart';
import '../models/job_list_item.dart';

class MultiSelectStatusFilter extends StatelessWidget {
  final Set<JobListStatus> selectedStatuses;
  final Function(JobListStatus) onToggle;
  final VoidCallback onClear;

  const MultiSelectStatusFilter({
    super.key,
    required this.selectedStatuses,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<void>(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
        decoration: BoxDecoration(
          border: Border.all(color: Colors.grey),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                selectedStatuses.isEmpty
                    ? 'Filter by Status'
                    : selectedStatuses.length == 1
                        ? selectedStatuses.first.displayName
                        : '${selectedStatuses.length} statuses selected',
                style: TextStyle(
                  color: selectedStatuses.isEmpty
                      ? Colors.grey[600]
                      : Colors.black,
                  fontSize: 14,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      ),
      itemBuilder: (context) {
        return [
          // Clear all option
          PopupMenuItem<void>(
            onTap: selectedStatuses.isNotEmpty ? onClear : null,
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                children: [
                  Icon(
                    selectedStatuses.isEmpty
                        ? Icons.check_box_outline_blank
                        : Icons.clear,
                    size: 20,
                    color: selectedStatuses.isEmpty ? Colors.grey : Colors.red,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Clear All',
                    style: TextStyle(
                      color:
                          selectedStatuses.isEmpty ? Colors.grey : Colors.red,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const PopupMenuDivider(),
          // Status options
          ...JobListStatus.values.map((status) {
            final isSelected = selectedStatuses.contains(status);
            return PopupMenuItem<void>(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Container(
                      width: 20,
                      height: 20,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? status.getColor().withOpacity(0.2)
                            : Colors.transparent,
                        border: Border.all(
                          color: isSelected ? status.getColor() : Colors.grey,
                          width: 2,
                        ),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: isSelected
                          ? Icon(
                              Icons.check,
                              size: 14,
                              color: status.getColor(),
                            )
                          : null,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        status.displayName,
                        style: TextStyle(
                          color: isSelected ? status.getColor() : Colors.black,
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                    ),
                    if (isSelected)
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: status.getColor(),
                          shape: BoxShape.circle,
                        ),
                      ),
                  ],
                ),
              ),
              onTap: () => onToggle(status),
            );
          }).toList(),
        ];
      },
    );
  }
}

// Extension to get color from JobListStatus
extension JobListStatusColor on JobListStatus {
  Color getColor() {
    switch (this) {
      case JobListStatus.orderConfirmedNotPaid:
      case JobListStatus.orderConfirmedPaid:
        return Colors.blue;
      case JobListStatus.jobUnderWay:
      case JobListStatus.printingUnderWay:
        return Colors.orange;
      case JobListStatus.jobDone:
      case JobListStatus.reportCompliled:
      case JobListStatus.paid:
        return Colors.green;
      case JobListStatus.outstanding:
      case JobListStatus.query:
        return Colors.red;
      case JobListStatus.standby:
        return Colors.grey;
      case JobListStatus.invoiceSent:
      case JobListStatus.reportSent:
        return Colors.purple;
      case JobListStatus.printingOrderConfirmed:
      case JobListStatus.printingArtworkSubmitted:
      case JobListStatus.printingArtworkApproved:
      case JobListStatus.printingAwaitingPayment:
      case JobListStatus.printingReadyForCollection:
        return Colors.teal;
    }
  }
}
