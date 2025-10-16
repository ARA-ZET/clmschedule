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
import 'simple_date_filter.dart';

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

// Reusable frozen header cell widget
class FrozenHeaderCell extends StatelessWidget {
  final String text;
  final double width;
  final double horizontalPadding;

  const FrozenHeaderCell({
    super.key,
    required this.text,
    required this.width,
    this.horizontalPadding = 8,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: 56,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey[100],
        border: Border.all(
          color: Colors.grey[300]!,
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontWeight: FontWeight.bold,
          color: Colors.black,
          fontSize: 14,
        ),
      ),
    );
  }
}

class JobListGrid extends StatefulWidget {
  const JobListGrid({super.key});

  @override
  State<JobListGrid> createState() => _JobListGridState();
}

class _JobListGridState extends State<JobListGrid> {
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _frozenHeaderScrollController = ScrollController();
  final ScrollController _mainVerticalScrollController = ScrollController();
  final ScrollController _frozenVerticalScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  bool _isAddingJob = false;

  @override
  void initState() {
    super.initState();
    // Synchronize horizontal scrolling between main table and frozen header
    _horizontalScrollController.addListener(() {
      if (_frozenHeaderScrollController.hasClients &&
          _horizontalScrollController.offset !=
              _frozenHeaderScrollController.offset) {
        _frozenHeaderScrollController
            .jumpTo(_horizontalScrollController.offset);
      }
    });

    _frozenHeaderScrollController.addListener(() {
      if (_horizontalScrollController.hasClients &&
          _frozenHeaderScrollController.offset !=
              _horizontalScrollController.offset) {
        _horizontalScrollController
            .jumpTo(_frozenHeaderScrollController.offset);
      }
    });

    // Synchronize vertical scrolling between main table and frozen column
    _mainVerticalScrollController.addListener(() {
      if (_frozenVerticalScrollController.hasClients &&
          _mainVerticalScrollController.offset !=
              _frozenVerticalScrollController.offset) {
        _frozenVerticalScrollController
            .jumpTo(_mainVerticalScrollController.offset);
      }
    });

    _frozenVerticalScrollController.addListener(() {
      if (_mainVerticalScrollController.hasClients &&
          _frozenVerticalScrollController.offset !=
              _mainVerticalScrollController.offset) {
        _mainVerticalScrollController
            .jumpTo(_frozenVerticalScrollController.offset);
      }
    });
  }

  @override
  void dispose() {
    _horizontalScrollController.dispose();
    _frozenHeaderScrollController.dispose();
    _mainVerticalScrollController.dispose();
    _frozenVerticalScrollController.dispose();
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

            // Search and Filter Bar - Single compact row
            Container(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  // Search field
                  Expanded(
                    flex: 4,
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
                  const SizedBox(width: 12),

                  // Simple Date Filter
                  Expanded(
                    flex: 2,
                    child: SimpleDateFilter(
                      startDate: jobListProvider.startDate,
                      endDate: jobListProvider.endDate,
                      onSingleDateSelected: (date) {
                        jobListProvider.setSimpleDateFilter(date);
                      },
                      onDateRangeSelected: (startDate, endDate) {
                        jobListProvider.setSimpleDateRangeFilter(
                            startDate, endDate);
                      },
                      onClear: () {
                        jobListProvider.clearDateFilter();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Status Filter - Smaller
                  SizedBox(
                    width: 120,
                    child: MultiSelectStatusFilter(
                      selectedStatusIds: jobListProvider.statusFilters,
                      onToggle: jobListProvider.toggleStatusFilter,
                      onClear: () {
                        jobListProvider.clearFilters();
                      },
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Sort dropdown - Smaller
                  SizedBox(
                    width: 110,
                    child: DropdownButtonFormField<String>(
                      initialValue: jobListProvider.sortField,
                      decoration: const InputDecoration(
                        labelText: 'Sort',
                        border: OutlineInputBorder(),
                        contentPadding:
                            EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'date',
                          child: Text('Date', style: TextStyle(fontSize: 12)),
                        ),
                        DropdownMenuItem(
                          value: 'collectionDate',
                          child:
                              Text('Col. Date', style: TextStyle(fontSize: 12)),
                        ),
                        DropdownMenuItem(
                          value: 'client',
                          child: Text('Client', style: TextStyle(fontSize: 12)),
                        ),
                        DropdownMenuItem(
                          value: 'invoice',
                          child:
                              Text('Invoice', style: TextStyle(fontSize: 12)),
                        ),
                        DropdownMenuItem(
                          value: 'amount',
                          child: Text('Amount', style: TextStyle(fontSize: 12)),
                        ),
                        DropdownMenuItem(
                          value: 'area',
                          child: Text('Area', style: TextStyle(fontSize: 12)),
                        ),
                        DropdownMenuItem(
                          value: 'quantity',
                          child:
                              Text('Quantity', style: TextStyle(fontSize: 12)),
                        ),
                        DropdownMenuItem(
                          value: 'manDays',
                          child:
                              Text('Man-Days', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          jobListProvider.setSortField(value);
                        }
                      },
                    ),
                  ),
                  const SizedBox(width: 12),

                  // Sort order button
                  IconButton(
                    icon: Icon(
                      jobListProvider.sortAscending
                          ? Icons.arrow_upward
                          : Icons.arrow_downward,
                      size: scaleProvider.mediumIconSize,
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
                  const SizedBox(width: 12),

                  // Action buttons - Clear and Add Job
                  ElevatedButton.icon(
                    onPressed: () {
                      _searchController.clear();
                      jobListProvider.clearFilters();
                    },
                    icon: Icon(Icons.clear, size: scaleProvider.smallIconSize),
                    label: const Text('Clear', style: TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: const Size(0, 36),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed:
                        _isAddingJob ? null : () => _showAddJobDialog(context),
                    icon: _isAddingJob
                        ? SizedBox(
                            width: scaleProvider.smallIconSize,
                            height: scaleProvider.smallIconSize,
                            child:
                                const CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.add, size: scaleProvider.smallIconSize),
                    label: Text(_isAddingJob ? 'Adding...' : 'Add Job',
                        style: const TextStyle(fontSize: 12)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      minimumSize: const Size(0, 36),
                    ),
                  ),
                  if (jobListProvider.pendingUpdatesCount > 0) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade100,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.orange.shade300),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.sync,
                              size: scaleProvider.smallIconSize,
                              color: Colors.orange.shade700),
                          const SizedBox(width: 2),
                          Text(
                            '${jobListProvider.pendingUpdatesCount}',
                            style: TextStyle(
                              fontSize: scaleProvider.smallFontSize,
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
                      child: Stack(
                        children: [
                          // Main scrollable table
                          Scrollbar(
                            controller: _horizontalScrollController,
                            thumbVisibility: true,
                            trackVisibility: true,
                            thickness: 12,
                            radius: const Radius.circular(6),
                            child: SingleChildScrollView(
                              controller: _horizontalScrollController,
                              scrollDirection: Axis.horizontal,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  minWidth: 1300,
                                ),
                                child: SingleChildScrollView(
                                  controller: _mainVerticalScrollController,
                                  scrollDirection: Axis.vertical,
                                  child: DataTable(
                                    columnSpacing: 0,
                                    horizontalMargin: 8,
                                    headingRowColor: WidgetStateProperty.all(
                                      Colors.grey[100],
                                    ),
                                    columns: const [
                                      DataColumn(
                                          label: DataTableHeaderWidget(
                                        text: 'Date',
                                      )),
                                      DataColumn(
                                          label: DataTableHeaderWidget(
                                        text: 'Client',
                                        textColor: Colors.black,
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
                                        text: 'Invoice',
                                      )),
                                      DataColumn(
                                          label: DataTableHeaderWidget(
                                        text: 'Amount',
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
                                                            listen: true)
                                                        .getStatusById(
                                                            item.jobStatusId)
                                                        ?.color ??
                                                    Colors.grey)
                                                .withAlpha(240)),
                                        cells: [
                                          DataCell(
                                            EditableDateCell(
                                              value: item.date,
                                              width: 80,
                                              jobType: item.jobType,
                                              onSave: (date) => _updateJobField(
                                                  item, 'date', date),
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.client,
                                              onSave: (value) =>
                                                  _updateJobField(
                                                      item, 'client', value),
                                              width: 252,
                                              validator: (value) =>
                                                  value?.isEmpty == true
                                                      ? 'Client required'
                                                      : null,
                                            ),
                                          ),
                                          DataCell(
                                            Consumer<JobListStatusProvider>(
                                              builder: (context, statusProvider,
                                                  child) {
                                                final currentStatus =
                                                    statusProvider
                                                        .getStatusById(
                                                            item.jobStatusId);
                                                return Container(
                                                  width: 226,
                                                  padding: const EdgeInsets
                                                      .symmetric(
                                                    horizontal: 8,
                                                    vertical: 4,
                                                  ),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        (currentStatus?.color ??
                                                            Colors.grey),
                                                    border: Border.all(
                                                      color: (currentStatus
                                                              ?.color ??
                                                          Colors.grey),
                                                      width: 1,
                                                    ),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            4),
                                                  ),
                                                  child: DropdownButton<String>(
                                                    value: statusProvider
                                                            .statuses
                                                            .any((s) =>
                                                                s.id ==
                                                                item.jobStatusId)
                                                        ? item.jobStatusId
                                                        : null,
                                                    underline:
                                                        const SizedBox.shrink(),
                                                    isDense: true,
                                                    items: statusProvider
                                                        .statuses
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
                                                                color: status
                                                                    .color,
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                            ),
                                                            Text(
                                                              status.label,
                                                              style: TextStyle(
                                                                  fontSize:
                                                                      scaleProvider
                                                                          .mediumFontSize,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .bold),
                                                            ),
                                                          ],
                                                        ),
                                                      );
                                                    }).toList(),
                                                    onChanged: (newStatusId) {
                                                      if (newStatusId != null) {
                                                        final updatedItem =
                                                            item.copyWith(
                                                                jobStatusId:
                                                                    newStatusId);
                                                        jobListProvider
                                                            .updateJobListItemWithTracking(
                                                          item,
                                                          updatedItem,
                                                        );
                                                      }
                                                    },
                                                  ),
                                                );
                                              },
                                            ),
                                          ),
                                          DataCell(
                                            SizedBox(
                                              width: 200,
                                              child: DropdownButton<JobType>(
                                                value: item.jobType,
                                                underline:
                                                    const SizedBox.shrink(),
                                                isDense: true,
                                                items:
                                                    JobType.values.map((type) {
                                                  return DropdownMenuItem<
                                                      JobType>(
                                                    value: type,
                                                    child: Text(
                                                      type.displayName,
                                                      style: TextStyle(
                                                          fontSize: scaleProvider
                                                              .mediumFontSize,
                                                          fontWeight:
                                                              FontWeight.bold),
                                                    ),
                                                  );
                                                }).toList(),
                                                onChanged: (newType) {
                                                  if (newType != null) {
                                                    _updateJobField(item,
                                                        'jobType', newType);
                                                  }
                                                },
                                              ),
                                            ),
                                          ),
                                          DataCell(
                                            LinkCell(
                                              value: item.area,
                                              onSave: (value) =>
                                                  _updateJobField(
                                                      item, 'area', value),
                                              width: 120,
                                              maxLines: 2,
                                            ),
                                          ),
                                          DataCell(
                                            EditableVehicleComboCell(
                                              quantity: item.quantity,
                                              jobType: item.jobType,
                                              width: 150,
                                              onSave: (quantity) {
                                                _updateJobField(
                                                    item, 'quantity', quantity);
                                              },
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.manDays.toString(),
                                              width: 80,
                                              onSave: (value) {
                                                final manDays =
                                                    double.tryParse(value) ??
                                                        item.manDays;
                                                _updateJobField(
                                                    item, 'manDays', manDays);
                                              },
                                              keyboardType: const TextInputType
                                                  .numberWithOptions(
                                                  decimal: true),
                                              inputFormatters: [
                                                FilteringTextInputFormatter
                                                    .allow(
                                                  RegExp(r'^\d+\.?\d{0,2}'),
                                                )
                                              ],
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.collectionAddress,
                                              onSave: (value) =>
                                                  _updateJobField(
                                                      item,
                                                      'collectionAddress',
                                                      value),
                                              width: 200,
                                              maxLines: 2,
                                              showTooltip: true,
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.specialInstructions,
                                              onSave: (value) =>
                                                  _updateJobField(
                                                      item,
                                                      'specialInstructions',
                                                      value),
                                              width: 200,
                                              showTooltip: true,
                                              maxLines: 2,
                                            ),
                                          ),
                                          DataCell(
                                            EditableDateCell(
                                              value: item.collectionDate,
                                              width: 80,
                                              onSave: (date) => _updateJobField(
                                                  item, 'collectionDate', date),
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.invoice,
                                              width: 120,
                                              onSave: (value) =>
                                                  _updateJobField(
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
                                              width: 120,
                                              onSave: (value) {
                                                final cleanValue = value
                                                    .replaceAll('R', '')
                                                    .trim();
                                                final amount = double.tryParse(
                                                        cleanValue) ??
                                                    item.amount;
                                                _updateJobField(
                                                    item, 'amount', amount);
                                              },
                                              keyboardType: const TextInputType
                                                  .numberWithOptions(
                                                  decimal: true),
                                              inputFormatters: [
                                                FilteringTextInputFormatter
                                                    .allow(RegExp(r'[R0-9.]')),
                                              ],
                                              validator: (value) {
                                                final cleanValue = value
                                                    ?.replaceAll('R', '')
                                                    .trim();
                                                if (cleanValue?.isEmpty ==
                                                    true) {
                                                  return 'Amount required';
                                                }
                                                if (double.tryParse(
                                                        cleanValue!) ==
                                                    null) {
                                                  return 'Invalid amount';
                                                }
                                                return null;
                                              },
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.quantityDistributed
                                                  .toString(),
                                              width: 100,
                                              onSave: (value) {
                                                final quantity = int.tryParse(
                                                        value) ??
                                                    item.quantityDistributed;
                                                _updateJobField(
                                                    item,
                                                    'quantityDistributed',
                                                    quantity);
                                              },
                                              keyboardType:
                                                  TextInputType.number,
                                              inputFormatters: [
                                                FilteringTextInputFormatter
                                                    .digitsOnly
                                              ],
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.invoiceDetails,
                                              onSave: (value) =>
                                                  _updateJobField(item,
                                                      'invoiceDetails', value),
                                              width: 120,
                                              maxLines: 2,
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.reportAddresses,
                                              onSave: (value) =>
                                                  _updateJobField(item,
                                                      'reportAddresses', value),
                                              width: 150,
                                              maxLines: 2,
                                            ),
                                          ),
                                          DataCell(
                                            EditableTableCell(
                                              value: item.whoToInvoice,
                                              onSave: (value) =>
                                                  _updateJobField(item,
                                                      'whoToInvoice', value),
                                              width: 120,
                                            ),
                                          ),
                                          DataCell(
                                            SizedBox(
                                              width: 120,
                                              child: Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Consumer<JobListProvider>(
                                                    builder: (context, provider,
                                                        child) {
                                                      final hasRecentUpdates =
                                                          provider
                                                              .hasUpdatesAfterLastCheck(
                                                                  item);
                                                      final hasAnyUpdates = item
                                                          .updates.isNotEmpty;

                                                      return IconButton(
                                                        icon: Icon(Icons.info,
                                                            size: 18,
                                                            color: !hasAnyUpdates
                                                                ? Colors.grey
                                                                : hasRecentUpdates
                                                                    ? Colors.orange
                                                                    : Colors.grey),
                                                        onPressed: hasAnyUpdates
                                                            ? () =>
                                                                _showUpdateHistory(
                                                                    context,
                                                                    item)
                                                            : null,
                                                        tooltip: hasAnyUpdates
                                                            ? (hasRecentUpdates
                                                                ? 'New updates available!'
                                                                : 'View update history')
                                                            : 'No updates yet',
                                                      );
                                                    },
                                                  ),
                                                  IconButton(
                                                    icon: const Icon(Icons.edit,
                                                        size: 18),
                                                    onPressed: () =>
                                                        _showEditJobDialog(
                                                            context, item),
                                                    tooltip: 'Edit',
                                                  ),
                                                  IconButton(
                                                    icon: const Icon(
                                                      Icons.delete,
                                                      size: 18,
                                                      color: Colors.red,
                                                    ),
                                                    onPressed: () =>
                                                        _showDeleteConfirmation(
                                                            context, item),
                                                    tooltip: 'Delete',
                                                  ),
                                                ],
                                              ),
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

                          // Frozen header row overlay
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            height: 57,
                            child: Container(
                              color: Colors.white,
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                    minWidth:
                                        2416), // Dynamic width based on sum of all FrozenHeaderCell widths
                                child: SingleChildScrollView(
                                  controller: _frozenHeaderScrollController,
                                  scrollDirection: Axis.horizontal,
                                  child: Row(
                                    children: [
                                      FrozenHeaderCell(
                                        text: 'Date',
                                        width: 80,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Client',
                                        width: 260,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Job Status',
                                        width: 226,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Job Type',
                                        width: 200,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Area',
                                        width: 120,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Qty/Vehicle',
                                        width: 150,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Man-Days',
                                        width: 80,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Col. Address',
                                        width: 200,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Special Instructions',
                                        width: 200,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Col. Date',
                                        width: 80,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Invoice',
                                        width: 120,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Amount',
                                        width: 120,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Qty Distributed',
                                        width: 110,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Invoice Details',
                                        width: 120,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Report Addresses',
                                        width: 150,
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Who to Invoice',
                                        width: 120,
                                      ),
                                      Container(
                                        width: 60,
                                        height: 56,
                                        alignment: Alignment.centerLeft,
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          borderRadius:
                                              BorderRadius.circular(8),
                                          color: Colors.grey[100],
                                          border: Border.all(
                                            color: Colors.grey[300]!,
                                            width: 1,
                                          ),
                                        ),
                                        child: Consumer<JobListProvider>(
                                          builder: (context, provider, child) {
                                            return IconButton(
                                              onPressed: provider
                                                      .isRefreshingLastChecked
                                                  ? null
                                                  : () async {
                                                      final now =
                                                          DateTime.now();
                                                      await provider
                                                          .refreshLastCheckedTime();

                                                      if (context.mounted) {
                                                        ScaffoldMessenger.of(
                                                                context)
                                                            .showSnackBar(
                                                          SnackBar(
                                                            content: Text(
                                                                'Last checked time refreshed to ${now.toString().substring(0, 19)}'),
                                                            duration:
                                                                const Duration(
                                                                    seconds: 2),
                                                          ),
                                                        );
                                                      }
                                                    },
                                              tooltip:
                                                  'Refresh last checked time',
                                              icon: provider
                                                      .isRefreshingLastChecked
                                                  ? const SizedBox(
                                                      width: 20,
                                                      height: 20,
                                                      child:
                                                          CircularProgressIndicator(
                                                        strokeWidth: 2,
                                                        color: Colors.grey,
                                                      ),
                                                    )
                                                  : const Icon(Icons
                                                      .replay_circle_filled_sharp),
                                            );
                                          },
                                        ),
                                      ),
                                      FrozenHeaderCell(
                                        text: 'Actions',
                                        width: 80,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Frozen Client column overlay
                          Positioned(
                            top: 57, // Below the header
                            bottom: 0,
                            left: 0,
                            width: 330,
                            child: Consumer<JobListProvider>(
                              builder: (context, jobProvider, child) {
                                return Consumer<JobListStatusProvider>(
                                  builder: (context, statusProvider, child) {
                                    return ListView.builder(
                                      controller:
                                          _frozenVerticalScrollController,
                                      itemCount:
                                          jobProvider.jobListItems.length,
                                      itemBuilder: (context, index) {
                                        final item =
                                            jobProvider.jobListItems[index];
                                        final statusColor = statusProvider
                                                .getStatusById(item.jobStatusId)
                                                ?.color ??
                                            Colors.grey;

                                        return Container(
                                          height:
                                              48, // Match DataTable default row height
                                          decoration: BoxDecoration(
                                            color: statusColor,
                                            border: Border(
                                              bottom: BorderSide(
                                                color: Colors.grey[300]!,
                                                width: 1,
                                              ),
                                            ),
                                          ),
                                          child: Row(
                                            children: [
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 4),
                                                alignment: Alignment.centerLeft,
                                                child: EditableDateCell(
                                                  value: item.date,
                                                  width: 80,
                                                  jobType: item.jobType,
                                                  onSave: (date) =>
                                                      _updateJobField(
                                                          item, 'date', date),
                                                ),
                                              ),
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                        vertical: 4),
                                                alignment: Alignment.centerLeft,
                                                child: EditableTableCell(
                                                  value: item.client,
                                                  onSave: (value) =>
                                                      _updateJobField(item,
                                                          'client', value),
                                                  width: 250,
                                                  maxLines: 2,
                                                  validator: (value) =>
                                                      value?.isEmpty == true
                                                          ? 'Client required'
                                                          : null,
                                                ),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                    );
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ), // Close Stack
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

      // Use debounced update system with change tracking
      context
          .read<JobListProvider>()
          .updateJobListItemWithTracking(item, updatedItem);
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
                      'Collection job added successfully without schedule allocation!'),
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
        await context
            .read<JobListProvider>()
            .updateJobListItemWithTracking(item, result);
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

  void _showUpdateHistory(BuildContext context, JobListItem item) {
    final provider = context.read<JobListProvider>();
    final allUpdates = item.updates;
    final recentUpdates = provider.getUpdatesAfterLastCheck(item);

    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              const Icon(Icons.history, color: Colors.blue),
              const SizedBox(width: 8),
              Expanded(
                child: Text('Update History - ${item.client}'),
              ),
              if (provider.lastCheckedTime != null)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: recentUpdates.isNotEmpty
                        ? Colors.orange.shade100
                        : Colors.grey.shade100,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: recentUpdates.isNotEmpty
                          ? Colors.orange.shade300
                          : Colors.grey.shade300,
                    ),
                  ),
                  child: Text(
                    recentUpdates.isNotEmpty
                        ? '${recentUpdates.length} new'
                        : 'Up to date',
                    style: TextStyle(
                      fontSize: 12,
                      color: recentUpdates.isNotEmpty
                          ? Colors.orange.shade700
                          : Colors.grey.shade700,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
            ],
          ),
          content: SizedBox(
            width: 500,
            height: 400,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (provider.lastCheckedTime != null) ...[
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.blue.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.access_time,
                            size: 16, color: Colors.blue.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'Last checked: ${_formatDateTime(provider.lastCheckedTime!)}',
                          style: TextStyle(
                              fontSize: 12, color: Colors.blue.shade700),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                Text(
                  'All Updates (${allUpdates.length})',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16),
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: allUpdates.isEmpty
                      ? const Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.history_toggle_off,
                                  size: 48, color: Colors.grey),
                              SizedBox(height: 16),
                              Text('No updates recorded yet',
                                  style: TextStyle(color: Colors.grey)),
                            ],
                          ),
                        )
                      : ListView.builder(
                          itemCount: allUpdates.length,
                          itemBuilder: (context, index) {
                            final update = allUpdates[allUpdates.length -
                                1 -
                                index]; // Show newest first
                            final isRecent = provider.lastCheckedTime != null &&
                                update.timestamp
                                    .isAfter(provider.lastCheckedTime!);

                            return Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: isRecent
                                    ? Colors.orange.shade50
                                    : Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: isRecent
                                      ? Colors.orange.shade200
                                      : Colors.grey.shade200,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: isRecent
                                              ? Colors.orange.shade100
                                              : Colors.grey.shade100,
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          update.userDisplayName.isNotEmpty
                                              ? update.userDisplayName
                                              : 'Unknown User',
                                          style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: isRecent
                                                ? Colors.orange.shade700
                                                : Colors.grey.shade700,
                                          ),
                                        ),
                                      ),
                                      const Spacer(),
                                      if (isRecent)
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                              horizontal: 6, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: Colors.orange.shade600,
                                            borderRadius:
                                                BorderRadius.circular(4),
                                          ),
                                          child: const Text(
                                            'NEW',
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.bold,
                                              color: Colors.white,
                                            ),
                                          ),
                                        ),
                                      const SizedBox(width: 8),
                                      Text(
                                        _formatDateTime(update.timestamp),
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    update.getChangeDescription(),
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  String _formatDateTime(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago (${dateTime.day}/${dateTime.month} ${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')})';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago (${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')})';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }
}
