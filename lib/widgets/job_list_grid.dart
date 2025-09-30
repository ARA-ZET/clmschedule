import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/job_list_item.dart';
import '../providers/job_list_provider.dart';
import '../providers/job_list_status_provider.dart';
import '../providers/scale_provider.dart';
import 'add_edit_job_dialog.dart';
import 'editable_table_cell.dart';
import 'multi_select_status_filter.dart';
import 'month_navigation_widget.dart';

// Reusable DataTable column header widget
class DataTableHeaderWidget extends StatelessWidget {
  final String text;
  final Color? textColor;
  final double? width;

  const DataTableHeaderWidget({
    super.key,
    required this.text,
    this.textColor = Colors.black,
    this.width,
  });

  @override
  Widget build(BuildContext context) {
    Widget headerWidget = Container(
      width: width,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: Colors.grey[400]!,
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontWeight: FontWeight.bold,
          color: textColor,
        ),
      ),
    );

    return width != null ? headerWidget : Expanded(child: headerWidget);
  }
}

class JobListGrid extends StatefulWidget {
  const JobListGrid({super.key});

  @override
  State<JobListGrid> createState() => _JobListGridState();
}

class _JobListGridState extends State<JobListGrid> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  bool _isAddingJob = false;

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<JobListProvider, ScaleProvider>(
      builder: (context, jobListProvider, scaleProvider, child) {
        final jobListItems = jobListProvider.jobListItems;
        final hasError = jobListProvider.error != null;
        final isLoading = jobListProvider.isLoading;

        // Error state
        if (hasError && jobListItems.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error,
                    size: scaleProvider.xlargeIconSize, color: Colors.red[300]),
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

        // Empty state for first load
        if (isLoading && jobListItems.isEmpty) {
          return const Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading Job List Data...'),
              ],
            ),
          );
        }

        // Main content
        return Column(
          children: [
            // Month navigation
            MonthNavigationWidget(
              currentMonthDisplay: jobListProvider.currentMonthDisplay,
              onPreviousMonth: jobListProvider.goToPreviousMonth,
              onNextMonth: jobListProvider.goToNextMonth,
              onCurrentMonth: jobListProvider.goToCurrentMonth,
              onMonthSelected: jobListProvider.goToMonth,
              availableMonths: jobListProvider.getAvailableMonths(),
            ),

            // Search and Filter Bar
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: 'Search by client, invoice, or area...',
                        prefixIcon: Icon(Icons.search,
                            size: scaleProvider.mediumIconSize),
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                      ),
                      onChanged: (value) {
                        jobListProvider.setSearchQuery(value);
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: MultiSelectStatusFilter(
                      selectedStatusIds: jobListProvider.statusFilters,
                      onToggle: jobListProvider.toggleStatusFilter,
                      onClear: () {
                        jobListProvider.clearFilters();
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: jobListProvider.sortField,
                      decoration: InputDecoration(
                        labelText: 'Sort by',
                        border: const OutlineInputBorder(),
                        contentPadding: const EdgeInsets.symmetric(
                            vertical: 8, horizontal: 12),
                        suffixIcon: IconButton(
                          icon: Icon(
                            jobListProvider.sortAscending
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            size: scaleProvider.largeFontSize,
                          ),
                          onPressed: () {
                            jobListProvider.setSorting(
                              jobListProvider.sortField,
                              !jobListProvider.sortAscending,
                            );
                          },
                          tooltip: jobListProvider.sortAscending
                              ? 'Ascending'
                              : 'Descending',
                        ),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'date',
                          child: Text('Date'),
                        ),
                        DropdownMenuItem(
                          value: 'collectionDate',
                          child: Text('Collection Date'),
                        ),
                        DropdownMenuItem(
                          value: 'client',
                          child: Text('Client'),
                        ),
                        DropdownMenuItem(
                          value: 'invoice',
                          child: Text('Invoice'),
                        ),
                        DropdownMenuItem(
                          value: 'amount',
                          child: Text('Amount'),
                        ),
                        DropdownMenuItem(
                          value: 'area',
                          child: Text('Area'),
                        ),
                        DropdownMenuItem(
                          value: 'quantity',
                          child: Text('Quantity'),
                        ),
                        DropdownMenuItem(
                          value: 'manDays',
                          child: Text('Man-Days'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          jobListProvider.setSortField(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      _searchController.clear();
                      jobListProvider.clearFilters();
                    },
                    icon: Icon(Icons.clear, size: scaleProvider.mediumIconSize),
                    label: const Text('Clear'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed:
                        _isAddingJob ? null : () => _showAddJobDialog(context),
                    icon: _isAddingJob
                        ? SizedBox(
                            width: scaleProvider.mediumIconSize,
                            height: scaleProvider.mediumIconSize,
                            child:
                                const CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.add, size: scaleProvider.mediumIconSize),
                    label: Text(_isAddingJob ? 'Adding...' : 'Add Job'),
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
                              size: scaleProvider.smallIconSize,
                              color: Colors.orange.shade700),
                          const SizedBox(width: 4),
                          Text(
                            '${jobListProvider.pendingUpdatesCount}',
                            style: TextStyle(
                              fontSize: scaleProvider.mediumFontSize,
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
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.list_alt,
                              size: scaleProvider.xlargeIconSize,
                              color: Colors.grey),
                          const SizedBox(height: 16),
                          Text(
                            'No jobs found',
                            style: TextStyle(
                              fontSize: scaleProvider.xlargeFontSize,
                              fontWeight: FontWeight.bold,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            'Add a job to get started',
                            style: TextStyle(color: Colors.grey),
                          ),
                        ],
                      ),
                    )
                  : Container(
                      margin: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        border: Border.all(color: Colors.grey[300]!),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Scrollbar(
                        controller: _scrollController,
                        thumbVisibility: true,
                        trackVisibility: true,
                        thickness: 12,
                        radius: const Radius.circular(6),
                        child: SingleChildScrollView(
                          controller: _scrollController,
                          scrollDirection: Axis.horizontal,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              minWidth:
                                  1200, // Ensure table is wide enough to scroll
                            ),
                            child: SingleChildScrollView(
                              scrollDirection: Axis.vertical,
                              child: DataTable(
                                columnSpacing: 8,
                                horizontalMargin: 16,
                                headingRowColor: WidgetStateProperty.all(
                                  Colors.grey[100],
                                ),
                                columns: const [
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Invoice',
                                    textColor: Colors.black,
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Amount',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Client',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Job Status',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Job Type',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Area',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Qty / Vihicle',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Man-Days',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Date',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Col. Address',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Special Instructions',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Col. Date',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Qty Distributed',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Invoice Details',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Report Addresses',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Who to Invoice',
                                  )),
                                  DataColumn(
                                      label: DataTableHeaderWidget(
                                    text: 'Actions',
                                  )),
                                ],
                                rows: jobListItems.map((item) {
                                  return DataRow(
                                    color: WidgetStateProperty.all(
                                      (Provider.of<JobListStatusProvider>(
                                                      context,
                                                      listen: false)
                                                  .getStatusById(
                                                      item.jobStatusId)
                                                  ?.color ??
                                              Colors.grey)
                                          .withOpacity(0.6),
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
                                            final cleanValue = value
                                                .replaceAll('R', '')
                                                .trim();
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
                                            final cleanValue = value
                                                ?.replaceAll('R', '')
                                                .trim();
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
                                          width: 250,
                                          validator: (value) =>
                                              value?.isEmpty == true
                                                  ? 'Client required'
                                                  : null,
                                        ),
                                      ),
                                      DataCell(
                                        Consumer<JobListStatusProvider>(
                                          builder:
                                              (context, statusProvider, child) {
                                            final currentStatus =
                                                statusProvider.getStatusById(
                                                    item.jobStatusId);
                                            return Container(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                horizontal: 8,
                                                vertical: 4,
                                              ),
                                              decoration: BoxDecoration(
                                                color: (currentStatus?.color ??
                                                        Colors.grey)
                                                    .withOpacity(0.9),
                                                border: Border.all(
                                                  color:
                                                      (currentStatus?.color ??
                                                          Colors.grey),
                                                  width: 1,
                                                ),
                                                borderRadius:
                                                    BorderRadius.circular(4),
                                              ),
                                              child: DropdownButton<String>(
                                                value: statusProvider.statuses
                                                        .any((s) =>
                                                            s.id ==
                                                            item.jobStatusId)
                                                    ? item.jobStatusId
                                                    : null,
                                                underline:
                                                    const SizedBox.shrink(),
                                                isDense: true,
                                                items: statusProvider.statuses
                                                    .map((status) {
                                                  return DropdownMenuItem<
                                                      String>(
                                                    value: status.id,
                                                    child: Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Container(
                                                          width: 12,
                                                          height: 12,
                                                          margin:
                                                              const EdgeInsets
                                                                  .only(
                                                                  right: 8),
                                                          decoration:
                                                              BoxDecoration(
                                                            color: status.color,
                                                            shape:
                                                                BoxShape.circle,
                                                          ),
                                                        ),
                                                        Text(
                                                          status.label,
                                                          style: TextStyle(
                                                            fontSize: scaleProvider
                                                                .mediumFontSize,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  );
                                                }).toList(),
                                                onChanged: (newStatusId) {
                                                  if (newStatusId != null) {
                                                    jobListProvider
                                                        .updateJobListItemLocal(
                                                      item.copyWith(
                                                          jobStatusId:
                                                              newStatusId),
                                                    );
                                                  }
                                                },
                                              ),
                                            );
                                          },
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
                                                style: TextStyle(
                                                    fontSize: scaleProvider
                                                        .mediumFontSize),
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
                                        LinkCell(
                                          value: item.area,
                                          onSave: (value) => _updateJobField(
                                              item, 'area', value),
                                          width: 120,
                                          maxLines: 2,
                                        ),
                                      ),
                                      DataCell(
                                        EditableVehicleComboCell(
                                          quantity: item.quantity,
                                          jobType: item.jobType,
                                          width: 180,
                                          onSave: (quantity) {
                                            _updateJobField(
                                                item, 'quantity', quantity);
                                          },
                                        ),
                                      ),
                                      DataCell(
                                        EditableTableCell(
                                          value: item.manDays.toString(),
                                          onSave: (value) {
                                            final manDays =
                                                double.tryParse(value) ??
                                                    item.manDays;
                                            _updateJobField(
                                                item, 'manDays', manDays);
                                          },
                                          keyboardType: const TextInputType
                                              .numberWithOptions(decimal: true),
                                          inputFormatters: [
                                            FilteringTextInputFormatter.allow(
                                              RegExp(r'^\d+\.?\d{0,2}'),
                                            )
                                          ],
                                        ),
                                      ),
                                      DataCell(
                                        EditableDateCell(
                                          value: item.date,
                                          jobType: item.jobType,
                                          onSave: (date) => _updateJobField(
                                              item, 'date', date),
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
                                        EditableTableCell(
                                          value: item.specialInstructions,
                                          onSave: (value) => _updateJobField(
                                              item,
                                              'specialInstructions',
                                              value),
                                          width: 150,
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
                                          value: item.quantityDistributed
                                              .toString(),
                                          onSave: (value) {
                                            final quantity =
                                                int.tryParse(value) ??
                                                    item.quantityDistributed;
                                            _updateJobField(
                                                item,
                                                'quantityDistributed',
                                                quantity);
                                          },
                                          keyboardType: TextInputType.number,
                                          inputFormatters: [
                                            FilteringTextInputFormatter
                                                .digitsOnly
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
                                              onPressed: () =>
                                                  _showEditJobDialog(
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
                              ), // Close DataTable
                            ), // Close inner SingleChildScrollView (vertical)
                          ), // Close ConstrainedBox
                        ), // Close outer SingleChildScrollView (horizontal)
                      ), // Close Scrollbar
                    ), // Close Container
            ),
          ], // Close Column children
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
          final newQuantity = value as int;
          // Validate quantity for vehicle combo job types
          if ((item.jobType == JobType.junkCollection ||
                  item.jobType == JobType.furnitureMove) &&
              (newQuantity < 1 || newQuantity > 9)) {
            // Invalid quantity for vehicle combo, don't update
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Invalid vehicle combination selected'),
                backgroundColor: Colors.red,
              ),
            );
            return;
          }
          updatedItem = item.copyWith(quantity: newQuantity);
          break;
        case 'manDays':
          updatedItem = item.copyWith(manDays: value as double);
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
    setState(() {
      _isAddingJob = true;
    });

    try {
      final result = await showDialog<dynamic>(
        context: context,
        builder: (context) => const AddEditJobDialog(),
      );

      if (result != null && context.mounted) {
        JobListItem job;
        bool skipAllocation = false;

        // Handle different return types from dialog
        if (result is Map<String, dynamic>) {
          job = result['job'] as JobListItem;
          skipAllocation = result['skipAllocation'] == true;
        } else if (result is JobListItem) {
          job = result;
          skipAllocation = false;
        } else {
          return; // Invalid result
        }

        try {
          // Use appropriate method based on whether allocation is skipped
          if (skipAllocation) {
            // Job is already saved in database, just show success message
            // No database operation needed as job was saved in the dialog already
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text(
                      'Collection job added successfully with schedule allocation!'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          } else {
            await context.read<JobListProvider>().addJobListItem(job);
            if (context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content:
                      Text('Job added successfully with schedule allocation!'),
                  backgroundColor: Colors.green,
                ),
              );
            }
          }
        } catch (e) {
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error adding job: $e'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isAddingJob = false;
        });
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
