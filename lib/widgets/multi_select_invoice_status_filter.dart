import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/invoice_status_provider.dart';

class MultiSelectInvoiceStatusFilter extends StatelessWidget {
  final Set<String> selectedStatusIds;
  final Function(String) onToggle;
  final VoidCallback onClear;

  const MultiSelectInvoiceStatusFilter({
    super.key,
    required this.selectedStatusIds,
    required this.onToggle,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Consumer<InvoiceStatusProvider>(
      builder: (context, statusProvider, child) {
        return PopupMenuButton<void>(
          child: Container(
            height: 48,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.grey.shade400),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Text(
                    selectedStatusIds.isEmpty
                        ? 'Invoice Status'
                        : selectedStatusIds.length == 1
                            ? statusProvider
                                    .getStatusById(selectedStatusIds.first)
                                    ?.label ??
                                'Unknown'
                            : '${selectedStatusIds.length} selected',
                    style: TextStyle(
                      color: selectedStatusIds.isEmpty
                          ? Colors.grey[600]
                          : Colors.black,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Icon(Icons.arrow_drop_down, color: Colors.grey[700]),
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
