import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/inventory_tool.dart';
import '../providers/inventory_provider.dart';
import 'qr_code_display_dialog.dart';
import 'add_tool_dialog.dart';
import 'manage_accessories_dialog.dart';

class ToolDetailsDialog extends StatelessWidget {
  final InventoryTool tool;

  const ToolDetailsDialog({super.key, required this.tool});

  @override
  Widget build(BuildContext context) {
    final isMobile = MediaQuery.of(context).size.width < 600;

    return Dialog(
      insetPadding: isMobile
          ? EdgeInsets.zero
          : const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: isMobile ? double.infinity : 600,
        height: isMobile ? double.infinity : null,
        constraints: isMobile ? null : const BoxConstraints(maxHeight: 700),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Header
            Container(
              padding: EdgeInsets.all(isMobile ? 12 : 16),
              decoration: BoxDecoration(
                color: Theme.of(context).primaryColor,
                borderRadius: isMobile
                    ? null
                    : const BorderRadius.vertical(top: Radius.circular(4)),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      tool.name,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: isMobile ? 16 : 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close,
                        color: Colors.white, size: isMobile ? 20 : 24),
                    onPressed: () => Navigator.of(context).pop(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
            ),
            // Content
            Expanded(
              child: SingleChildScrollView(
                padding: EdgeInsets.all(isMobile ? 16 : 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Image
                    Center(
                      child: Container(
                        width: isMobile ? 150 : 200,
                        height: isMobile ? 150 : 200,
                        decoration: BoxDecoration(
                          color: Colors.grey[200],
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: tool.imageUrl != null
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.network(
                                  tool.imageUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (context, error, stackTrace) {
                                    return const Icon(Icons.construction,
                                        size: 80, color: Colors.grey);
                                  },
                                ),
                              )
                            : const Icon(Icons.construction,
                                size: 80, color: Colors.grey),
                      ),
                    ),
                    const SizedBox(height: 24),
                    // Details
                    _buildDetailRow('Tool ID', tool.toolId),
                    _buildDetailRow('Category', tool.category),
                    _buildDetailRow(
                        'Status', tool.isAvailable ? 'Available' : 'In Use'),
                    if (!tool.isAvailable && tool.currentProject != null)
                      _buildDetailRow('Current Project', tool.currentProject!),
                    if (tool.description.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      const Text(
                        'Description',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16),
                      ),
                      const SizedBox(height: 8),
                      Text(tool.description),
                    ],
                    if (tool.lastUsed != null) ...[
                      const SizedBox(height: 16),
                      _buildDetailRow('Last Used', _formatDate(tool.lastUsed!)),
                    ],

                    // Accessories section
                    const SizedBox(height: 24),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text(
                              'Required Accessories',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 16,
                              ),
                            ),
                            OutlinedButton.icon(
                              onPressed: () async {
                                await showDialog(
                                  context: context,
                                  builder: (context) =>
                                      ManageAccessoriesDialog(tool: tool),
                                );
                                // Dialog will trigger rebuild through provider
                              },
                              icon: const Icon(Icons.edit, size: 16),
                              label: const Text('Manage'),
                              style: OutlinedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 8,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (tool.requiredAccessories.isEmpty)
                          Container(
                            padding: const EdgeInsets.all(16),
                            decoration: BoxDecoration(
                              color: Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: Colors.grey.shade300),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.info_outline,
                                    color: Colors.grey.shade600),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Text(
                                    'No accessories configured. Click "Manage" to add accessories that must be checked out with this tool.',
                                    style: TextStyle(
                                      fontSize: 13,
                                      color: Colors.grey.shade600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        else
                          ...tool.requiredAccessories.map((accessory) => Card(
                                margin: const EdgeInsets.only(bottom: 8),
                                child: ListTile(
                                  dense: true,
                                  leading: CircleAvatar(
                                    backgroundColor: Colors.blue.shade100,
                                    radius: 16,
                                    child: Icon(
                                      Icons.extension,
                                      size: 16,
                                      color: Colors.blue.shade700,
                                    ),
                                  ),
                                  title: Text(
                                    accessory.baseName,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                  subtitle: Text(
                                    'Quantity: ${accessory.quantity}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                  trailing: Chip(
                                    label: Text(
                                      'Other',
                                      style: const TextStyle(fontSize: 10),
                                    ),
                                    backgroundColor: Colors.blue.shade50,
                                    padding: EdgeInsets.zero,
                                  ),
                                ),
                              )),
                      ],
                    ),

                    const SizedBox(height: 24),
                    // QR Code
                    Center(
                      child: Column(
                        children: [
                          const Text(
                            'QR Code',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 16),
                          ),
                          const SizedBox(height: 8),
                          ElevatedButton.icon(
                            onPressed: () {
                              showDialog(
                                context: context,
                                builder: (context) =>
                                    QrCodeDisplayDialog(tool: tool),
                              );
                            },
                            icon: const Icon(Icons.qr_code),
                            label: const Text('View & Print QR Code'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Actions
            Container(
              padding: EdgeInsets.all(isMobile ? 10 : 16),
              decoration: BoxDecoration(
                color: Colors.grey[100],
                borderRadius: isMobile
                    ? null
                    : const BorderRadius.vertical(bottom: Radius.circular(4)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text('Close',
                        style: TextStyle(fontSize: isMobile ? 13 : 14)),
                  ),
                  SizedBox(width: isMobile ? 6 : 8),
                  ElevatedButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      // Open edit dialog
                      showDialog(
                        context: context,
                        builder: (context) => AddToolDialog(tool: tool),
                      );
                    },
                    child: Text('Edit',
                        style: TextStyle(fontSize: isMobile ? 13 : 14)),
                  ),
                  SizedBox(width: isMobile ? 6 : 8),
                  ElevatedButton(
                    onPressed: () async {
                      final confirmed = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Delete Tool'),
                          content: Text(
                              'Are you sure you want to delete ${tool.name}?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.of(context).pop(true),
                              style: TextButton.styleFrom(
                                  foregroundColor: Colors.red),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );

                      if (confirmed == true && context.mounted) {
                        try {
                          await context
                              .read<InventoryProvider>()
                              .deleteTool(tool.id);
                          if (context.mounted) {
                            Navigator.of(context).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                  content: Text('Tool deleted successfully')),
                            );
                          }
                        } catch (e) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text('Error deleting tool: $e')),
                            );
                          }
                        }
                      }
                    },
                    style:
                        ElevatedButton.styleFrom(backgroundColor: Colors.red),
                    child: Text('Delete',
                        style: TextStyle(fontSize: isMobile ? 13 : 14)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.day}/${date.month}/${date.year}';
  }
}
