import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/job_list_item.dart';
import '../providers/job_list_provider.dart';
import 'add_edit_job_dialog.dart';
import 'editable_table_cell.dart';
import 'multi_select_status_filter.dart';

class JobListGrid extends StatefulWidget {
  const JobListGrid({super.key});

  @override
  State<JobListGrid> createState() => _JobListGridState();
}

class _JobListGridState extends State<JobListGrid> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<JobListProvider>(
      builder: (context, jobListProvider, child) {
        if (jobListProvider.isLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        if (jobListProvider.error != null) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, size: 64, color: Colors.red[300]),
                const SizedBox(height: 16),
                Text(
                  'Error loading job list',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  jobListProvider.error!,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    jobListProvider.clearError();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          );
        }

        final jobListItems = jobListProvider.jobListItems;

        return Column(
          children: [
            // Search and Filter Bar
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _searchController,
                      decoration: const InputDecoration(
                        hintText: 'Search by client, invoice, or area...',
                        prefixIcon: Icon(Icons.search),
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 8, horizontal: 12),
                      ),
                      onChanged: (value) {
                        jobListProvider.setSearchQuery(value);
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: MultiSelectStatusFilter(
                      selectedStatuses: jobListProvider.statusFilters,
                      onToggle: (status) {
                        jobListProvider.toggleStatusFilter(status);
                      },
                      onClear: () {
                        jobListProvider.clearFilters();
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      _searchController.clear();
                      jobListProvider.clearFilters();
                    },
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => _showAddJobDialog(context),
                    icon: const Icon(Icons.add),
                    label: const Text('Add Job'),
                  ),
                  if (jobListProvider.pendingUpdatesCount > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.sync,
                              size: 16, color: Colors.orange.shade700),
                          const SizedBox(width: 4),
                          Text(
                            '${jobListProvider.pendingUpdatesCount}',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                              color: Colors.orange.shade700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            // Table scroll hint
            // if (jobListItems.isNotEmpty)
            //   Container(
            //     padding:
            //         const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            //     child: Row(
            //       children: [
            //         Icon(Icons.swipe_left, size: 16, color: Colors.grey[600]),
            //         const SizedBox(width: 4),
            //         Text(
            //           'Scroll horizontally to view all columns',
            //           style: TextStyle(
            //             fontSize: 12,
            //             color: Colors.grey[600],
            //             fontStyle: FontStyle.italic,
            //           ),
            //         ),
            //         const Spacer(),
            //         Icon(Icons.swipe_right, size: 16, color: Colors.grey[600]),
            //       ],
            //     ),
            //   ),
            // Job List Table
            Expanded(
              child: jobListItems.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.list_alt, size: 64, color: Colors.grey),
                          SizedBox(height: 16),
                          Text(
                            'No jobs found',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey,
                            ),
                          ),
                          SizedBox(height: 8),
                          Text(
                            'Add a job to get started',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true, // Always show the scrollbar
                      trackVisibility: true, // Show the scroll track
                      thickness: 12, // Make scrollbar thicker
                      radius: const Radius.circular(6),
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        scrollDirection: Axis.horizontal,
                        child: Container(
                          margin: const EdgeInsets.all(16),
                          decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey[300]!),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth:
                                  1200, // Ensure table is wide enough to scroll
                            ),
                            child: DataTable(
                              columnSpacing: 20,
                              horizontalMargin: 16,
                              headingRowColor: WidgetStateProperty.all(
                                Colors.grey[100],
                              ),
                              columns: const [
                                DataColumn(label: Text('Invoice')),
                                DataColumn(label: Text('Amount')),
                                DataColumn(label: Text('Client')),
                                DataColumn(label: Text('Job Status')),
                                DataColumn(label: Text('Job Type')),
                                DataColumn(label: Text('Area')),
                                DataColumn(label: Text('Quantity')),
                                DataColumn(label: Text('Date')),
                                DataColumn(label: Text('Collection Address')),
                                DataColumn(label: Text('Collection Date')),
                                DataColumn(label: Text('Special Instructions')),
                                DataColumn(label: Text('Quantity Distributed')),
                                DataColumn(label: Text('Invoice Details')),
                                DataColumn(label: Text('Report Addresses')),
                                DataColumn(label: Text('Who to Invoice')),
                                DataColumn(label: Text('Actions')),
                              ],
                              rows: jobListItems.map((item) {
                                return DataRow(
                                  color: WidgetStateProperty.all(
                                    item.getStatusColor().withOpacity(0.1),
                                  ),
                                  cells: [
                                    DataCell(
                                      EditableTableCell(
                                        value: item.invoice,
                                        onSave: (value) => _updateJobField(
                                            item, 'invoice', value),
                                        validator: (value) =>
                                            value?.isEmpty == true
                                                ? 'Invoice required'
                                                : null,
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value:
                                            'R${item.amount.toStringAsFixed(2)}',
                                        onSave: (value) {
                                          final cleanValue =
                                              value.replaceAll('R', '').trim();
                                          final amount =
                                              double.tryParse(cleanValue) ??
                                                  item.amount;
                                          _updateJobField(
                                              item, 'amount', amount);
                                        },
                                        keyboardType: const TextInputType
                                            .numberWithOptions(decimal: true),
                                        inputFormatters: [
                                          FilteringTextInputFormatter.allow(
                                              RegExp(r'[R0-9.]')),
                                        ],
                                        validator: (value) {
                                          final cleanValue =
                                              value?.replaceAll('R', '').trim();
                                          if (cleanValue?.isEmpty == true) {
                                            return 'Amount required';
                                          }
                                          if (double.tryParse(cleanValue!) ==
                                              null) {
                                            return 'Invalid amount';
                                          }
                                          return null;
                                        },
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.client,
                                        onSave: (value) => _updateJobField(
                                            item, 'client', value),
                                        width: 150,
                                        validator: (value) =>
                                            value?.isEmpty == true
                                                ? 'Client required'
                                                : null,
                                      ),
                                    ),
                                    DataCell(
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: item
                                              .getStatusColor()
                                              .withOpacity(0.2),
                                          border: Border.all(
                                            color: item
                                                .getStatusColor()
                                                .withOpacity(0.5),
                                            width: 1,
                                          ),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: DropdownButton<JobListStatus>(
                                          value: item.jobStatus,
                                          underline: const SizedBox.shrink(),
                                          isDense: true,
                                          items: JobListStatus.values
                                              .map((status) {
                                            return DropdownMenuItem<
                                                JobListStatus>(
                                              value: status,
                                              child: Text(
                                                status.displayName,
                                                style: const TextStyle(
                                                    fontSize: 12),
                                              ),
                                            );
                                          }).toList(),
                                          onChanged: (newStatus) {
                                            if (newStatus != null) {
                                              jobListProvider.updateJobStatus(
                                                item.id,
                                                newStatus,
                                              );
                                            }
                                          },
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      DropdownButton<JobType>(
                                        value: item.jobType,
                                        underline: const SizedBox.shrink(),
                                        isDense: true,
                                        items: JobType.values.map((type) {
                                          return DropdownMenuItem<JobType>(
                                            value: type,
                                            child: Text(
                                              type.displayName,
                                              style:
                                                  const TextStyle(fontSize: 12),
                                            ),
                                          );
                                        }).toList(),
                                        onChanged: (newType) {
                                          if (newType != null) {
                                            _updateJobField(
                                                item, 'jobType', newType);
                                          }
                                        },
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.area,
                                        onSave: (value) => _updateJobField(
                                            item, 'area', value),
                                        width: 120,
                                        maxLines: 2,
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.quantity.toString(),
                                        onSave: (value) {
                                          final quantity =
                                              int.tryParse(value) ??
                                                  item.quantity;
                                          _updateJobField(
                                              item, 'quantity', quantity);
                                        },
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter.digitsOnly
                                        ],
                                      ),
                                    ),
                                    DataCell(
                                      EditableDateCell(
                                        value: item.date,
                                        onSave: (date) =>
                                            _updateJobField(item, 'date', date),
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.collectionAddress,
                                        onSave: (value) => _updateJobField(
                                            item, 'collectionAddress', value),
                                        width: 200,
                                        maxLines: 2,
                                      ),
                                    ),
                                    DataCell(
                                      EditableDateCell(
                                        value: item.collectionDate,
                                        onSave: (date) => _updateJobField(
                                            item, 'collectionDate', date),
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.specialInstructions,
                                        onSave: (value) => _updateJobField(
                                            item, 'specialInstructions', value),
                                        width: 150,
                                        maxLines: 2,
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value:
                                            item.quantityDistributed.toString(),
                                        onSave: (value) {
                                          final quantity =
                                              int.tryParse(value) ??
                                                  item.quantityDistributed;
                                          _updateJobField(item,
                                              'quantityDistributed', quantity);
                                        },
                                        keyboardType: TextInputType.number,
                                        inputFormatters: [
                                          FilteringTextInputFormatter.digitsOnly
                                        ],
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.invoiceDetails,
                                        onSave: (value) => _updateJobField(
                                            item, 'invoiceDetails', value),
                                        width: 150,
                                        maxLines: 2,
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.reportAddresses,
                                        onSave: (value) => _updateJobField(
                                            item, 'reportAddresses', value),
                                        width: 150,
                                        maxLines: 2,
                                      ),
                                    ),
                                    DataCell(
                                      EditableTableCell(
                                        value: item.whoToInvoice,
                                        onSave: (value) => _updateJobField(
                                            item, 'whoToInvoice', value),
                                        width: 120,
                                      ),
                                    ),
                                    DataCell(
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          IconButton(
                                            icon: const Icon(Icons.edit,
                                                size: 18),
                                            onPressed: () => _showEditJobDialog(
                                                context, item),
                                            tooltip: 'Edit',
                                          ),
                                          IconButton(
                                            icon: const Icon(Icons.delete,
                                                size: 18),
                                            onPressed: () =>
                                                _showDeleteConfirmation(
                                                    context, item),
                                            tooltip: 'Delete',
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }

  // Helper method to update individual job fields
  void _updateJobField(JobListItem item, String field, dynamic value) {
    try {
      JobListItem updatedItem;

      switch (field) {
        case 'invoice':
          updatedItem = item.copyWith(invoice: value as String);
          break;
        case 'amount':
          updatedItem = item.copyWith(amount: value as double);
          break;
        case 'client':
          updatedItem = item.copyWith(client: value as String);
          break;
        case 'jobType':
          updatedItem = item.copyWith(jobType: value as JobType);
          break;
        case 'area':
          updatedItem = item.copyWith(area: value as String);
          break;
        case 'quantity':
          updatedItem = item.copyWith(quantity: value as int);
          break;
        case 'date':
          updatedItem = item.copyWith(date: value as DateTime);
          break;
        case 'collectionAddress':
          updatedItem = item.copyWith(collectionAddress: value as String);
          break;
        case 'collectionDate':
          updatedItem = item.copyWith(collectionDate: value as DateTime);
          break;
        case 'specialInstructions':
          updatedItem = item.copyWith(specialInstructions: value as String);
          break;
        case 'quantityDistributed':
          updatedItem = item.copyWith(quantityDistributed: value as int);
          break;
        case 'invoiceDetails':
          updatedItem = item.copyWith(invoiceDetails: value as String);
          break;
        case 'reportAddresses':
          updatedItem = item.copyWith(reportAddresses: value as String);
          break;
        case 'whoToInvoice':
          updatedItem = item.copyWith(whoToInvoice: value as String);
          break;
        default:
          return;
      }

      // Use debounced update system - no await needed as it updates locally first
      context.read<JobListProvider>().updateJobListItem(updatedItem);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error updating job: $e')),
        );
      }
    }
  }

  void _showAddJobDialog(BuildContext context) async {
    final result = await showDialog<JobListItem>(
      context: context,
      builder: (context) => const AddEditJobDialog(),
    );

    if (result != null && context.mounted) {
      try {
        await context.read<JobListProvider>().addJobListItem(result);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Job added successfully!')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error adding job: $e')),
          );
        }
      }
    }
  }

  void _showEditJobDialog(BuildContext context, JobListItem item) async {
    final result = await showDialog<JobListItem>(
      context: context,
      builder: (context) => AddEditJobDialog(jobToEdit: item),
    );

    if (result != null && context.mounted) {
      try {
        await context.read<JobListProvider>().updateJobListItem(result);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Job updated successfully!')),
          );
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error updating job: $e')),
          );
        }
      }
    }
  }

  void _showDeleteConfirmation(BuildContext context, JobListItem item) {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Delete Job'),
          content: Text(
              'Are you sure you want to delete the job for ${item.client}?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(context).pop();
                try {
                  await context
                      .read<JobListProvider>()
                      .deleteJobListItem(item.id);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Job deleted successfully')),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error deleting job: $e')),
                    );
                  }
                }
              },
              child: const Text('Delete', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
  }
}
