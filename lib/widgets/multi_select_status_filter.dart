import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/job_list_status_provider.dart';

class MultiSelectStatusFilter extends StatelessWidget {
  final Set<String>
      selectedStatusIds; // Changed from JobListStatus to String IDs
  final Function(String) onToggle; // Changed to work with String IDs
  final VoidCallback onClear;

  const MultiSelectStatusFilter({
    super.key,
    required this.selectedStatusIds,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<JobListStatusProvider>(
      builder: (context, statusProvider, child) {
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
                    selectedStatusIds.isEmpty
                        ? 'Filter by Status'
                        : selectedStatusIds.length == 1
                            ? statusProvider
                                    .getStatusById(selectedStatusIds.first)
                                    ?.label ??
                                'Unknown Status'
                            : '${selectedStatusIds.length} statuses selected',
                    style: TextStyle(
                      color: selectedStatusIds.isEmpty
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
                onTap: selectedStatusIds.isNotEmpty ? onClear : null,
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        selectedStatusIds.isEmpty
                            ? Icons.check_box_outline_blank
                            : Icons.clear,
                        size: 20,
                        color: selectedStatusIds.isEmpty
                            ? Colors.grey
                            : Colors.red,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Clear All',
                        style: TextStyle(
                          color: selectedStatusIds.isEmpty
                              ? Colors.grey
                              : Colors.red,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const PopupMenuDivider(),
              // Status options
              ...statusProvider.statuses.map((status) {
                final isSelected = selectedStatusIds.contains(status.id);
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
                                ? status.color.withOpacity(0.2)
                                : Colors.transparent,
                            border: Border.all(
                              color: isSelected ? status.color : Colors.grey,
                              width: 2,
                            ),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: isSelected
                              ? Icon(
                                  Icons.check,
                                  size: 14,
                                  color: status.color,
                                )
                              : null,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            status.label,
                            style: TextStyle(
                              color: isSelected ? status.color : Colors.black,
                              fontWeight: isSelected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                        if (isSelected)
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: status.color,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                  ),
                  onTap: () => onToggle(status.id),
                );
              }),
            ];
          },
        );
      },
    );
  }
}
