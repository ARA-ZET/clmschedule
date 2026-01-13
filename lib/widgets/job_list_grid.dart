import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../models/job_list_item.dart';
import '../models/job_reminder.dart';
import '../providers/job_list_provider.dart';
import '../providers/job_list_preferences_provider.dart';
import '../providers/job_list_status_provider.dart';
import '../providers/invoice_status_provider.dart';
import '../providers/scale_provider.dart';
import 'add_edit_job_dialog.dart';
import 'editable_table_cell.dart';
import 'multi_select_status_filter.dart';
import 'multi_select_invoice_status_filter.dart';
import 'month_navigation_widget.dart';
import 'simple_date_filter.dart';
import 'job_list_columns_dialog.dart';
import 'job_list_column_config.dart';
import 'reminder_dialog.dart';

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

// Helper class to get column labels
class JobListColumnLabels {
  static const Map<String, String> labels = {
    'date': 'Date',
    'client': 'Client',
    'jobStatus': 'Job Status',
    'reminder': 'Reminders',
    'invoiceStatus': 'Invoice Status',
    'jobType': 'Job Type',
    'area': 'Area',
    'quantity': 'Qty / Vehicle',
    'manDays': 'Man-Days',
    'collectionAddress': 'Col. Address',
    'specialInstructions': 'Special Instructions',
    'collectionDate': 'Col. Date',
    'invoice': 'Invoice',
    'amount': 'Amount',
    'quantityDistributed': 'Qty Distributed',
    'invoiceDetails': 'Invoice Details',
    'reportAddresses': 'Report Addresses',
    'whoToInvoice': 'Who to Invoice',
    'actions': 'Actions',
  };

  static String get(String columnKey) => labels[columnKey] ?? columnKey;
}

// Stateless widget for building DataTable columns
class JobListDataColumns extends StatelessWidget {
  final JobListPreferencesProvider prefsProvider;

  const JobListDataColumns({
    super.key,
    required this.prefsProvider,
  });

  static const columnOrder = [
    'date',
    'client',
    'jobStatus',
    'reminder',
    'invoiceStatus',
    'jobType',
    'area',
    'quantity',
    'manDays',
    'collectionAddress',
    'specialInstructions',
    'collectionDate',
    'invoice',
    'amount',
    'quantityDistributed',
    'invoiceDetails',
    'reportAddresses',
    'whoToInvoice',
    'actions'
  ];

  List<DataColumn> buildColumns() {
    return columnOrder
        .where((col) => prefsProvider.isColumnVisible(col))
        .map((col) => DataColumn(
              label: DataTableHeaderWidget(
                text: JobListColumnLabels.get(col),
                textColor: col == 'client' ? Colors.black : null,
              ),
            ))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    throw UnimplementedError('Use buildColumns() method instead');
  }
}

// Stateless widget for building frozen headers
class JobListFrozenHeaders extends StatelessWidget {
  final JobListPreferencesProvider prefsProvider;
  final JobListProvider jobListProvider;

  const JobListFrozenHeaders({
    super.key,
    required this.prefsProvider,
    required this.jobListProvider,
  });

  static const columnOrder = [
    'date',
    'client',
    'jobStatus',
    'reminder',
    'invoiceStatus',
    'jobType',
    'area',
    'quantity',
    'manDays',
    'collectionAddress',
    'specialInstructions',
    'collectionDate',
    'invoice',
    'amount',
    'quantityDistributed',
    'invoiceDetails',
    'reportAddresses',
    'whoToInvoice',
  ];

  List<Widget> buildHeaders(BuildContext context) {
    final headers = <Widget>[];

    // Add headers for visible columns in order
    for (final columnKey in columnOrder) {
      if (prefsProvider.isColumnVisible(columnKey)) {
        // Special handling for reminder column - show clock icon
        if (columnKey == 'reminder') {
          headers.add(Container(
            width: JobListColumnConfig.getWidth('reminder'),
            height: 56,
            alignment: Alignment.center,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: Colors.grey[100],
              border: Border.all(
                color: Colors.grey[300]!,
                width: 1,
              ),
            ),
            child: const Icon(Icons.alarm, size: 20),
          ));
        } else {
          headers.add(FrozenHeaderCell(
            text: JobListColumnLabels.get(columnKey),
            width: JobListColumnConfig.getWidth(columnKey),
          ));
        }
      }
    }

    // Add refresh button if visible
    if (prefsProvider.isColumnVisible('refresh')) {
      headers.add(Container(
        width: JobListColumnConfig.getWidth('refresh'),
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
        child: Consumer<JobListProvider>(
          builder: (context, provider, child) {
            return IconButton(
              onPressed: provider.isRefreshingLastChecked
                  ? null
                  : () async {
                      final now = DateTime.now();
                      await provider.refreshLastCheckedTime();

                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                                'Last checked time refreshed to ${now.toString().substring(0, 19)}'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    },
              tooltip: 'Refresh last checked time',
              icon: provider.isRefreshingLastChecked
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.grey,
                      ),
                    )
                  : const Icon(Icons.replay_circle_filled_sharp),
            );
          },
        ),
      ));
    }

    // Add actions header if visible
    if (prefsProvider.isColumnVisible('actions')) {
      headers.add(FrozenHeaderCell(
        text: 'Actions',
        width: JobListColumnConfig.getWidth('actions'),
      ));
    }

    return headers;
  }

  static double calculateWidth(JobListPreferencesProvider prefsProvider) {
    double totalWidth = 0;

    const columnOrderWithButtons = [
      'date',
      'client',
      'jobStatus',
      'reminder',
      'invoiceStatus',
      'jobType',
      'area',
      'quantity',
      'manDays',
      'collectionAddress',
      'specialInstructions',
      'collectionDate',
      'invoice',
      'amount',
      'quantityDistributed',
      'invoiceDetails',
      'reportAddresses',
      'whoToInvoice',
      'refresh',
      'actions',
    ];

    for (final columnKey in columnOrderWithButtons) {
      if (prefsProvider.isColumnVisible(columnKey)) {
        totalWidth += JobListColumnConfig.getWidth(columnKey);
      }
    }

    return totalWidth > 800 ? totalWidth : 800;
  }

  @override
  Widget build(BuildContext context) {
    throw UnimplementedError('Use buildHeaders() method instead');
  }
}

// Stateless widget for building data cells
class JobListDataCellsBuilder extends StatelessWidget {
  final JobListItem item;
  final JobListProvider jobListProvider;
  final ScaleProvider scaleProvider;
  final JobListPreferencesProvider prefsProvider;
  final Function(JobListItem, String, dynamic) onUpdateField;
  final Function(BuildContext, JobListItem) onShowUpdateHistory;
  final Function(BuildContext, JobListItem) onShowEditDialog;
  final Function(BuildContext, JobListItem) onShowCopyDialog;
  final Function(BuildContext, JobListItem) onShowDeleteConfirmation;
  final String? Function(int) getVehicleTypeStringFromQuantity;
  final String? Function(int, JobType) getVehicleTrailerComboFromQuantity;

  const JobListDataCellsBuilder({
    super.key,
    required this.item,
    required this.jobListProvider,
    required this.scaleProvider,
    required this.prefsProvider,
    required this.onUpdateField,
    required this.onShowUpdateHistory,
    required this.onShowEditDialog,
    required this.onShowCopyDialog,
    required this.onShowDeleteConfirmation,
    required this.getVehicleTypeStringFromQuantity,
    required this.getVehicleTrailerComboFromQuantity,
  });

  List<DataCell> buildCells(BuildContext context) {
    final cells = <DataCell>[];

    // Date
    if (prefsProvider.isColumnVisible('date')) {
      cells.add(DataCell(
        EditableDateCell(
          value: item.date,
          width: JobListColumnConfig.getWidth('date'),
          jobType: item.jobType,
          jobData: {
            'id': item.id,
            'quantity': item.quantity,
            'vehicleType': getVehicleTypeStringFromQuantity(item.quantity),
          },
          onSave: (date) => onUpdateField(item, 'date', date),
        ),
      ));
    }

    // Client
    if (prefsProvider.isColumnVisible('client')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.client,
          onSave: (value) => onUpdateField(item, 'client', value),
          width: JobListColumnConfig.getWidth('client'),
          validator: (value) =>
              value?.isEmpty == true ? 'Client required' : null,
        ),
      ));
    }

    // Job Status
    if (prefsProvider.isColumnVisible('jobStatus')) {
      cells.add(DataCell(
        Consumer<JobListStatusProvider>(
          builder: (context, statusProvider, child) {
            final currentStatus =
                statusProvider.getStatusById(item.jobStatusId);
            return Container(
              width: JobListColumnConfig.getWidth('jobStatus'),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              decoration: BoxDecoration(
                color: (currentStatus?.color ?? Colors.grey),
                border: Border.all(
                  color: (currentStatus?.color ?? Colors.grey),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: DropdownButton<String>(
                value:
                    statusProvider.statuses.any((s) => s.id == item.jobStatusId)
                        ? item.jobStatusId
                        : null,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: statusProvider.statuses.map((status) {
                  return DropdownMenuItem<String>(
                    value: status.id,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: status.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Text(
                          status.label,
                          style: TextStyle(
                            fontSize: scaleProvider.mediumFontSize,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (newStatusId) {
                  if (newStatusId != null) {
                    final updatedItem = item.copyWith(jobStatusId: newStatusId);
                    final jobListStatusProvider =
                        context.read<JobListStatusProvider>();
                    final invoiceStatusProvider =
                        context.read<InvoiceStatusProvider>();
                    Future.microtask(
                        () => jobListProvider.updateJobListItemWithTracking(
                              item,
                              updatedItem,
                              resolveJobStatusLabel: (statusId) =>
                                  jobListStatusProvider
                                      .getStatusById(statusId)
                                      ?.label,
                              resolveInvoiceStatusLabel: (statusId) =>
                                  invoiceStatusProvider
                                      .getStatusById(statusId)
                                      ?.label,
                              resolveQuantityLabel:
                                  getVehicleTrailerComboFromQuantity,
                            ));
                  }
                },
              ),
            );
          },
        ),
      ));
    }

    // Reminder
    if (prefsProvider.isColumnVisible('reminder')) {
      final activeReminders = item.reminders.where((r) => r.isActive).toList();
      final hasActiveReminder = activeReminders.isNotEmpty;
      final isOverdue = activeReminders.any((r) => r.isOverdue);

      cells.add(DataCell(
        Center(
          child: IconButton(
            icon: Icon(
              hasActiveReminder ? Icons.alarm_on : Icons.alarm_add,
              size: 20,
              color: isOverdue
                  ? Colors.orange
                  : (hasActiveReminder ? Colors.blue : Colors.grey),
            ),
            onPressed: () async {
              final result = await showDialog<Map<String, dynamic>>(
                context: context,
                builder: (context) => ReminderDialog(
                  existingReminders: item.reminders,
                  invoiceStatus: item.invoiceStatusId,
                ),
              );

              if (result != null && result['action'] != null) {
                List<JobReminder> updatedReminders = List.from(item.reminders);

                switch (result['action']) {
                  case 'add':
                    // Add new reminder
                    updatedReminders.add(result['reminder'] as JobReminder);
                    break;
                  case 'complete':
                    // Mark reminder as completed
                    final reminderToComplete =
                        result['reminder'] as JobReminder;
                    final index = updatedReminders.indexWhere(
                      (r) => r.createdAt == reminderToComplete.createdAt,
                    );
                    if (index != -1) {
                      updatedReminders[index] = reminderToComplete.copyWith(
                        status: ReminderStatus.completed,
                        completedAt: DateTime.now(),
                      );
                    }
                    break;
                  case 'cancel':
                    // Mark reminder as cancelled
                    final reminderToCancel = result['reminder'] as JobReminder;
                    final index = updatedReminders.indexWhere(
                      (r) => r.createdAt == reminderToCancel.createdAt,
                    );
                    if (index != -1) {
                      updatedReminders[index] = reminderToCancel.copyWith(
                        status: ReminderStatus.cancelled,
                        completedAt: DateTime.now(),
                      );
                    }
                    break;
                }

                final updatedItem = item.copyWith(reminders: updatedReminders);
                jobListProvider.updateJobListItemWithTracking(
                  item,
                  updatedItem,
                  resolveJobStatusLabel: (_) => null,
                  resolveInvoiceStatusLabel: (_) => null,
                  resolveQuantityLabel: getVehicleTrailerComboFromQuantity,
                );
              }
            },
            tooltip: hasActiveReminder
                ? 'Active reminders: ${activeReminders.length}'
                : 'Add reminder',
          ),
        ),
      ));
    }

    // Invoice Status
    if (prefsProvider.isColumnVisible('invoiceStatus')) {
      cells.add(DataCell(
        Consumer<InvoiceStatusProvider>(
          builder: (context, statusProvider, child) {
            final currentStatus =
                statusProvider.getStatusById(item.invoiceStatusId);
            return Container(
              width: JobListColumnConfig.getWidth('invoiceStatus'),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                color: (currentStatus?.color ?? Colors.grey),
                border: Border.all(
                  color: (currentStatus?.color ?? Colors.grey),
                  width: 1,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: DropdownButton<String>(
                value: statusProvider.statuses
                        .any((s) => s.id == item.invoiceStatusId)
                    ? item.invoiceStatusId
                    : null,
                underline: const SizedBox.shrink(),
                isDense: true,
                items: statusProvider.statuses.map((status) {
                  return DropdownMenuItem<String>(
                    value: status.id,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          margin: const EdgeInsets.only(right: 8),
                          decoration: BoxDecoration(
                            color: status.color,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Text(
                          status.label,
                          style: TextStyle(
                            fontSize: scaleProvider.mediumFontSize,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (newStatusId) {
                  if (newStatusId != null) {
                    // Check if the new status is "paid" - auto-complete active reminders
                    List<JobReminder> updatedReminders = item.reminders;
                    final invoiceStatusProvider =
                        context.read<InvoiceStatusProvider>();
                    final newStatus =
                        invoiceStatusProvider.getStatusById(newStatusId);

                    // Check if status label indicates payment received
                    if (newStatus != null &&
                        (newStatus.label.toLowerCase().contains('paid') ||
                            newStatus.label
                                .toLowerCase()
                                .contains('payment'))) {
                      updatedReminders = item.reminders.map((reminder) {
                        if (reminder.isActive) {
                          return reminder.copyWith(
                            status: ReminderStatus.completed,
                            completedAt: DateTime.now(),
                          );
                        }
                        return reminder;
                      }).toList();
                    }

                    final updatedItem = item.copyWith(
                      invoiceStatusId: newStatusId,
                      reminders: updatedReminders,
                    );
                    final jobListStatusProvider =
                        context.read<JobListStatusProvider>();
                    Future.microtask(
                        () => jobListProvider.updateJobListItemWithTracking(
                              item,
                              updatedItem,
                              resolveJobStatusLabel: (statusId) =>
                                  jobListStatusProvider
                                      .getStatusById(statusId)
                                      ?.label,
                              resolveInvoiceStatusLabel: (statusId) =>
                                  invoiceStatusProvider
                                      .getStatusById(statusId)
                                      ?.label,
                              resolveQuantityLabel:
                                  getVehicleTrailerComboFromQuantity,
                            ));
                  }
                },
              ),
            );
          },
        ),
      ));
    }

    // Job Type
    if (prefsProvider.isColumnVisible('jobType')) {
      cells.add(DataCell(
        SizedBox(
          width: JobListColumnConfig.getWidth('jobType'),
          child: DropdownButton<JobType>(
            value: item.jobType,
            underline: const SizedBox.shrink(),
            isDense: true,
            items: JobType.values.map((type) {
              return DropdownMenuItem<JobType>(
                value: type,
                child: Text(
                  type.displayName,
                  style: TextStyle(
                    fontSize: scaleProvider.mediumFontSize,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              );
            }).toList(),
            onChanged: (newType) {
              if (newType != null) {
                onUpdateField(item, 'jobType', newType);
              }
            },
          ),
        ),
      ));
    }

    // Area
    if (prefsProvider.isColumnVisible('area')) {
      cells.add(DataCell(
        LinkCell(
          value: item.area,
          onSave: (value) => onUpdateField(item, 'area', value),
          width: JobListColumnConfig.getWidth('area'),
          maxLines: 2,
        ),
      ));
    }

    // Quantity / Vehicle
    if (prefsProvider.isColumnVisible('quantity')) {
      cells.add(DataCell(
        EditableVehicleComboCell(
          quantity: item.quantity,
          jobType: item.jobType,
          width: JobListColumnConfig.getWidth('quantity'),
          onSave: (quantity) {
            onUpdateField(item, 'quantity', quantity);
          },
        ),
      ));
    }

    // Man-Days
    if (prefsProvider.isColumnVisible('manDays')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.manDays.toString(),
          width: JobListColumnConfig.getWidth('manDays'),
          onSave: (value) {
            final manDays = double.tryParse(value) ?? item.manDays;
            onUpdateField(item, 'manDays', manDays);
          },
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(
              RegExp(r'^\d+\.?\d{0,2}'),
            )
          ],
        ),
      ));
    }

    // Collection Address
    if (prefsProvider.isColumnVisible('collectionAddress')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.collectionAddress,
          onSave: (value) => onUpdateField(item, 'collectionAddress', value),
          width: JobListColumnConfig.getWidth('collectionAddress'),
          maxLines: 2,
          showTooltip: true,
        ),
      ));
    }

    // Special Instructions
    if (prefsProvider.isColumnVisible('specialInstructions')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.specialInstructions,
          onSave: (value) => onUpdateField(item, 'specialInstructions', value),
          width: JobListColumnConfig.getWidth('specialInstructions'),
          maxLines: 3,
          showTooltip: true,
        ),
      ));
    }

    // Collection Date
    if (prefsProvider.isColumnVisible('collectionDate')) {
      cells.add(DataCell(
        EditableDateCell(
          value: item.collectionDate,
          width: JobListColumnConfig.getWidth('collectionDate'),
          jobType: item.jobType,
          jobData: {},
          onSave: (date) => onUpdateField(item, 'collectionDate', date),
        ),
      ));
    }

    // Invoice
    if (prefsProvider.isColumnVisible('invoice')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.invoice,
          onSave: (value) => onUpdateField(item, 'invoice', value),
          width: JobListColumnConfig.getWidth('invoice'),
        ),
      ));
    }

    // Amount
    if (prefsProvider.isColumnVisible('amount')) {
      cells.add(DataCell(
        EditableTableCell(
          value: 'R ${item.amount.toStringAsFixed(2)}',
          onSave: (value) {
            final cleanValue = value.replaceAll(RegExp(r'[^0-9.]'), '');
            final amount = double.tryParse(cleanValue) ?? item.amount;
            onUpdateField(item, 'amount', amount);
          },
          width: JobListColumnConfig.getWidth('amount'),
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          inputFormatters: [
            FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
          ],
        ),
      ));
    }

    // Quantity Distributed
    if (prefsProvider.isColumnVisible('quantityDistributed')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.quantityDistributed.toString(),
          onSave: (value) {
            final qty = int.tryParse(value) ?? item.quantityDistributed;
            onUpdateField(item, 'quantityDistributed', qty);
          },
          width: JobListColumnConfig.getWidth('quantityDistributed'),
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
      ));
    }

    // Invoice Details
    if (prefsProvider.isColumnVisible('invoiceDetails')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.invoiceDetails,
          onSave: (value) => onUpdateField(item, 'invoiceDetails', value),
          width: JobListColumnConfig.getWidth('invoiceDetails'),
          maxLines: 2,
          showTooltip: true,
        ),
      ));
    }

    // Report Addresses
    if (prefsProvider.isColumnVisible('reportAddresses')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.reportAddresses,
          onSave: (value) => onUpdateField(item, 'reportAddresses', value),
          width: JobListColumnConfig.getWidth('reportAddresses'),
          maxLines: 2,
          showTooltip: true,
        ),
      ));
    }

    // Who to Invoice
    if (prefsProvider.isColumnVisible('whoToInvoice')) {
      cells.add(DataCell(
        EditableTableCell(
          value: item.whoToInvoice,
          onSave: (value) => onUpdateField(item, 'whoToInvoice', value),
          width: JobListColumnConfig.getWidth('whoToInvoice'),
        ),
      ));
    }

    // Actions
    if (prefsProvider.isColumnVisible('actions')) {
      cells.add(DataCell(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (item.updates.isNotEmpty)
              Stack(
                clipBehavior: Clip.none,
                children: [
                  IconButton(
                    icon:
                        Icon(Icons.history, size: scaleProvider.mediumIconSize),
                    onPressed: () => onShowUpdateHistory(context, item),
                    tooltip: 'View Update History',
                  ),
                  if (jobListProvider.getUpdatesAfterLastCheck(item).isNotEmpty)
                    Positioned(
                      right: 8,
                      top: 8,
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: const BoxDecoration(
                          color: Colors.orange,
                          shape: BoxShape.circle,
                        ),
                        child: Text(
                          jobListProvider
                              .getUpdatesAfterLastCheck(item)
                              .length
                              .toString(),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            IconButton(
              icon: Icon(Icons.edit, size: scaleProvider.smallIconSize),
              onPressed: () => onShowEditDialog(context, item),
              tooltip: 'Edit',
            ),
            IconButton(
              icon: Icon(Icons.copy, size: scaleProvider.smallIconSize),
              onPressed: () => onShowCopyDialog(context, item),
              tooltip: 'Copy',
            ),
            IconButton(
              icon: Icon(Icons.delete,
                  size: scaleProvider.smallIconSize, color: Colors.red),
              onPressed: () => onShowDeleteConfirmation(context, item),
              tooltip: 'Delete',
            ),
          ],
        ),
      ));
    }

    return cells;
  }

  @override
  Widget build(BuildContext context) {
    throw UnimplementedError('Use buildCells() method instead');
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
    return Consumer3<JobListProvider, ScaleProvider,
        JobListPreferencesProvider>(
      builder: (context, jobListProvider, scaleProvider, prefsProvider, child) {
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

        // Show loading only if truly empty (no cached data)
        // This allows cached data to display immediately while fresh data loads
        if (isLoading &&
            jobListItems.isEmpty &&
            !jobListProvider.isInitialized) {
          return Center(
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

        // Main content with loading overlay
        return Stack(
          children: [
            Column(
              children: [
                // Month navigation with loading indicator
                Row(
                  children: [
                    Expanded(
                      child: MonthNavigationWidget(
                        currentMonthDisplay:
                            jobListProvider.currentMonthDisplay,
                        onPreviousMonth: jobListProvider.goToPreviousMonth,
                        onNextMonth: jobListProvider.goToNextMonth,
                        onCurrentMonth: jobListProvider.goToCurrentMonth,
                        onMonthSelected: jobListProvider.goToMonth,
                        availableMonths: jobListProvider.getAvailableMonths(),
                      ),
                    ),
                    // Subtle loading indicator when data is loading but items exist (refreshing)
                    if (isLoading && jobListItems.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 16.0),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  Theme.of(context)
                                      .primaryColor
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Refreshing...',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: Theme.of(context)
                                        .textTheme
                                        .bodySmall
                                        ?.color
                                        ?.withValues(alpha: 0.6),
                                  ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),

                // Search and Filter Bar - Single compact row
                Container(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      // Search field
                      Expanded(
                        flex: 3,
                        child: SizedBox(
                          height: 48,
                          child: ValueListenableBuilder<bool>(
                            valueListenable:
                                jobListProvider.isSearchingNotifier,
                            builder: (context, isSearching, child) {
                              return TextField(
                                controller: _searchController,
                                decoration: InputDecoration(
                                  hintText:
                                      'Search by client, invoice, or area...',
                                  prefixIcon: Icon(Icons.search,
                                      size: scaleProvider.mediumIconSize),
                                  suffixIcon: isSearching
                                      ? Padding(
                                          padding: const EdgeInsets.all(12.0),
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                Theme.of(context).primaryColor,
                                              ),
                                            ),
                                          ),
                                        )
                                      : null,
                                  border: const OutlineInputBorder(),
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 8, horizontal: 12),
                                ),
                                onChanged: (value) {
                                  jobListProvider.setSearchQuery(value);
                                },
                              );
                            },
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Invoice Status Filter
                      SizedBox(
                        width: 160,
                        height: 48,
                        child: MultiSelectInvoiceStatusFilter(
                          selectedStatusIds:
                              jobListProvider.invoiceStatusFilters,
                          onToggle: jobListProvider.toggleInvoiceStatusFilter,
                          onClear: () {
                            jobListProvider.clearFilters();
                          },
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Simple Date Filter
                      SizedBox(
                        width: 220,
                        height: 48,
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

                      // Job Status Filter
                      SizedBox(
                        width: 160,
                        height: 48,
                        child: MultiSelectStatusFilter(
                          selectedStatusIds: jobListProvider.statusFilters,
                          onToggle: jobListProvider.toggleStatusFilter,
                          onClear: () {
                            jobListProvider.clearFilters();
                          },
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Sort by date button
                      InkWell(
                        onTap: () {
                          print(
                              'Sort button tapped - current: ${jobListProvider.sortAscending}');
                          jobListProvider.setSorting(
                            'date',
                            !jobListProvider.sortAscending,
                          );
                          print(
                              'Sort after toggle: ${jobListProvider.sortAscending}');
                        },
                        child: Container(
                          width: 140,
                          height: 48,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: Colors.grey.shade400),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text(
                                'Sort by Date',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                              Icon(
                                jobListProvider.sortAscending
                                    ? Icons.arrow_upward
                                    : Icons.arrow_downward,
                                size: 18,
                                color: Colors.grey[700],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),

                      // Action buttons - Clear and Add Job
                      ElevatedButton.icon(
                        onPressed: () {
                          _searchController.clear();
                          jobListProvider.clearFilters();
                        },
                        icon: Icon(Icons.clear,
                            size: scaleProvider.smallIconSize),
                        label: const Text('Clear',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          minimumSize: const Size(0, 36),
                        ),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton.icon(
                        onPressed: _isAddingJob
                            ? null
                            : () => _showAddJobDialog(context),
                        icon: _isAddingJob
                            ? SizedBox(
                                width: scaleProvider.smallIconSize,
                                height: scaleProvider.smallIconSize,
                                child: const CircularProgressIndicator(
                                    strokeWidth: 2),
                              )
                            : Icon(Icons.add,
                                size: scaleProvider.smallIconSize),
                        label: Text(_isAddingJob ? 'Adding...' : 'Add Job',
                            style: const TextStyle(
                                fontSize: 12, fontWeight: FontWeight.bold)),
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          minimumSize: const Size(0, 36),
                        ),
                      ),
                      const SizedBox(width: 8),
                      // Column preferences button
                      IconButton(
                        icon: Icon(Icons.view_column,
                            size: scaleProvider.mediumIconSize),
                        onPressed: () {
                          showDialog(
                            context: context,
                            builder: (context) => const JobListColumnsDialog(),
                          );
                        },
                        tooltip: 'Customize Columns',
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.grey.shade200,
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
                                    constraints: BoxConstraints(
                                      minWidth: JobListColumnConfig
                                          .calculateTotalWidth(
                                              prefsProvider.visibleColumns),
                                    ),
                                    child: SingleChildScrollView(
                                      controller: _mainVerticalScrollController,
                                      scrollDirection: Axis.vertical,
                                      child: DataTable(
                                        columnSpacing: 0,
                                        horizontalMargin: 8,
                                        headingRowColor:
                                            WidgetStateProperty.all(
                                          Colors.grey[100],
                                        ),
                                        columns: JobListDataColumns(
                                                prefsProvider: prefsProvider)
                                            .buildColumns(),
                                        rows: jobListItems.map((item) {
                                          return DataRow(
                                            color: WidgetStateProperty.all(
                                                (Provider.of<JobListStatusProvider>(
                                                                context,
                                                                listen: true)
                                                            .getStatusById(item
                                                                .jobStatusId)
                                                            ?.color ??
                                                        Colors.grey)
                                                    .withAlpha(240)),
                                            cells: JobListDataCellsBuilder(
                                              item: item,
                                              jobListProvider: jobListProvider,
                                              scaleProvider: scaleProvider,
                                              prefsProvider: prefsProvider,
                                              onUpdateField: _updateJobField,
                                              onShowUpdateHistory:
                                                  _showUpdateHistory,
                                              onShowEditDialog:
                                                  _showEditJobDialog,
                                              onShowCopyDialog:
                                                  _showCopyJobDialog,
                                              onShowDeleteConfirmation:
                                                  _showDeleteConfirmation,
                                              getVehicleTypeStringFromQuantity:
                                                  _getVehicleTypeStringFromQuantity,
                                              getVehicleTrailerComboFromQuantity:
                                                  _getVehicleTrailerComboFromQuantity,
                                            ).buildCells(context),
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
                                    constraints: BoxConstraints(
                                      minWidth:
                                          JobListFrozenHeaders.calculateWidth(
                                              prefsProvider),
                                    ),
                                    child: SingleChildScrollView(
                                      controller: _frozenHeaderScrollController,
                                      scrollDirection: Axis.horizontal,
                                      child: Row(
                                        children: JobListFrozenHeaders(
                                          prefsProvider: prefsProvider,
                                          jobListProvider: jobListProvider,
                                        ).buildHeaders(context),
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
                                      builder:
                                          (context, statusProvider, child) {
                                        return ListView.builder(
                                          controller:
                                              _frozenVerticalScrollController,
                                          itemCount:
                                              jobProvider.jobListItems.length,
                                          itemBuilder: (context, index) {
                                            final item =
                                                jobProvider.jobListItems[index];
                                            final statusColor = statusProvider
                                                    .getStatusById(
                                                        item.jobStatusId)
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
                                                    padding: const EdgeInsets
                                                        .symmetric(vertical: 4),
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    child: EditableDateCell(
                                                      value: item.date,
                                                      width: 80,
                                                      jobType: item.jobType,
                                                      jobData: {
                                                        'id': item.id,
                                                        'quantity':
                                                            item.quantity,
                                                        'vehicleType':
                                                            _getVehicleTypeStringFromQuantity(
                                                                item.quantity),
                                                      },
                                                      onSave: (date) =>
                                                          _updateJobField(item,
                                                              'date', date),
                                                    ),
                                                  ),
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(vertical: 4),
                                                    alignment:
                                                        Alignment.centerLeft,
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
            ), // Close Column widget

            // Non-blocking data loading overlay
            if (isLoading && jobListProvider.isInitialized)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).primaryColor.withValues(alpha: 0.9),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.1),
                        blurRadius: 4,
                        offset: const Offset(0, 2),
                      ),
                    ],
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor:
                              AlwaysStoppedAnimation<Color>(Colors.white),
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Loading data...',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ], // Close Stack children
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

      // Get label resolvers from providers
      final jobListStatusProvider = context.read<JobListStatusProvider>();
      final invoiceStatusProvider = context.read<InvoiceStatusProvider>();

      // Use debounced update system with change tracking
      context.read<JobListProvider>().updateJobListItemWithTracking(
            item,
            updatedItem,
            resolveJobStatusLabel: (statusId) =>
                jobListStatusProvider.getStatusById(statusId)?.label,
            resolveInvoiceStatusLabel: (statusId) =>
                invoiceStatusProvider.getStatusById(statusId)?.label,
            resolveQuantityLabel: _getVehicleTrailerComboFromQuantity,
          );
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
        final jobListStatusProvider = context.read<JobListStatusProvider>();
        final invoiceStatusProvider = context.read<InvoiceStatusProvider>();
        await context.read<JobListProvider>().updateJobListItemWithTracking(
              item,
              result,
              resolveJobStatusLabel: (statusId) =>
                  jobListStatusProvider.getStatusById(statusId)?.label,
              resolveInvoiceStatusLabel: (statusId) =>
                  invoiceStatusProvider.getStatusById(statusId)?.label,
              resolveQuantityLabel: _getVehicleTrailerComboFromQuantity,
            );
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

  void _showCopyJobDialog(BuildContext context, JobListItem item) async {
    // Create a new job with all fields copied but empty ID (so dialog treats it as new)
    final copiedJob = JobListItem(
      id: '', // Empty ID so dialog treats it as a new job
      invoice: item.invoice,
      amount: item.amount,
      client: item.client,
      jobStatusId: item.jobStatusId,
      invoiceStatusId: item.invoiceStatusId,
      jobType: item.jobType,
      area: item.area,
      quantity: item.quantity,
      manDays: item.manDays,
      date: item.date,
      collectionAddress: item.collectionAddress,
      collectionDate: item.collectionDate,
      specialInstructions: item.specialInstructions,
      quantityDistributed: item.quantityDistributed,
      invoiceDetails: item.invoiceDetails,
      reportAddresses: item.reportAddresses,
      whoToInvoice: item.whoToInvoice,
      collectionJobId: '', // Don't copy the collection job link
      updates: const [], // Start with empty update history
      customPolygons: item.customPolygons,
    );

    final result = await showDialog<dynamic>(
      context: context,
      builder: (context) => AddEditJobDialog(jobToEdit: copiedJob),
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
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                    'Job copied and added successfully without schedule allocation!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        } else {
          // Add job to database
          await context.read<JobListProvider>().addJobListItem(job);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Job copied and added successfully!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error copying job: $e'),
              backgroundColor: Colors.red,
            ),
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
                                    update.getChangeDescription(
                                        jobType: item.jobType),
                                    style: const TextStyle(
                                        fontSize: 13,
                                        fontWeight: FontWeight.bold),
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

  // Helper method to convert quantity to vehicle type string for time slot conflict detection
  String? _getVehicleTypeStringFromQuantity(int quantity) {
    // Mapping based on the vehicle/trailer combinations
    // 1-3: Hyundai, 4-6: Mahindra, 7-9: Nissan
    if (quantity >= 1 && quantity <= 3) {
      return 'hyundai';
    } else if (quantity >= 4 && quantity <= 6) {
      return 'mahindra';
    } else if (quantity >= 7 && quantity <= 9) {
      return 'nissan';
    }
    return null;
  }

  // Helper method to get vehicle/trailer combination label from quantity
  String? _getVehicleTrailerComboFromQuantity(int quantity, JobType jobType) {
    // Only convert to vehicle combo for applicable job types
    if (jobType != JobType.junkCollection &&
        jobType != JobType.furnitureMove &&
        jobType != JobType.trailerTowing) {
      return quantity
          .toString(); // Just return quantity as string for other types
    }

    final combinations = jobType == JobType.trailerTowing
        ? [
            'Hyundai - No Trailer',
            'Mahindra - No Trailer',
            'Nissan - No Trailer',
          ]
        : [
            'Hyundai - No Trailer',
            'Hyundai - Big Trailer',
            'Hyundai - Small Trailer',
            'Mahindra - No Trailer',
            'Mahindra - Big Trailer',
            'Mahindra - Small Trailer',
            'Nissan - No Trailer',
            'Nissan - Big Trailer',
            'Nissan - Small Trailer',
          ];

    if (quantity >= 1 && quantity <= combinations.length) {
      return combinations[quantity - 1];
    }
    return null;
  }
}
