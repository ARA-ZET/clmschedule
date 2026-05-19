import 'dart:async';

import 'package:clmschedule/providers/toggler_provider.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' as riverpod;
import '../models/job_list_item.dart';
import '../models/job_reminder.dart';
import '../models/collection_job.dart';
import '../providers/job_list_provider.dart';
import '../providers/job_list_preferences_provider.dart';
import '../providers/job_list_status_provider.dart';
import '../providers/invoice_status_provider.dart';
import '../providers/scale_provider.dart';
import '../providers/job_type_provider.dart';
import 'add_edit_job_dialog.dart';
import 'editable_table_cell.dart';
import 'multi_select_status_filter.dart';
import 'multi_select_invoice_status_filter.dart';
import 'month_navigation_widget.dart';
import 'simple_date_filter.dart';
import 'job_list_columns_dialog.dart';
import 'job_list_column_config.dart';
import 'reminder_dialog.dart' as reminder;
import 'map_picker_dialog.dart';

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
    'invoiceStatus',
    'reminder',
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
    'invoiceStatus',
    'reminder',
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
        child: Builder(
          builder: (context) {
            final provider = riverpod.ProviderScope.containerOf(context)
                .read(jobListRiverpod);
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
class JobListDataCellsBuilder extends riverpod.ConsumerWidget {
  final JobListItem item;
  final JobListProvider jobListProvider;
  final ScaleProvider scaleProvider;
  final JobListPreferencesProvider prefsProvider;
  final Function(JobListItem, String, dynamic) onUpdateField;
  final Function(BuildContext, JobListItem) onShowUpdateHistory;
  final Function(BuildContext, JobListItem) onShowEditDialog;
  final Function(BuildContext, JobListItem) onShowCopyDialog;
  final Function(BuildContext, JobListItem) onShowDeleteConfirmation;
  final String? Function(int, String) getVehicleTrailerComboFromQuantity;

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
    required this.getVehicleTrailerComboFromQuantity,
  });

  List<DataCell> buildCells(BuildContext context, riverpod.WidgetRef ref) {
    final cells = <DataCell>[];

    // Date — skip building (hidden behind frozen column overlay)
    if (prefsProvider.isColumnVisible('date')) {
      cells.add(const DataCell(SizedBox.shrink()));
    }

    // Client — skip building (hidden behind frozen column overlay)
    if (prefsProvider.isColumnVisible('client')) {
      cells.add(const DataCell(SizedBox.shrink()));
    }

    // Job Status
    if (prefsProvider.isColumnVisible('jobStatus')) {
      cells.add(DataCell(
        Builder(
          builder: (context) {
            final statusProvider = ref.watch(jobListStatusRiverpod);
            final currentStatus =
                statusProvider.getStatusById(item.jobStatusId);
            final filteredStatuses =
                statusProvider.getStatusesForJobType(item.jobTypeId);
            // Ensure current status is always in the list
            final statuses =
                filteredStatuses.any((s) => s.id == item.jobStatusId)
                    ? filteredStatuses
                    : [
                        if (currentStatus != null) currentStatus,
                        ...filteredStatuses,
                      ];
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
                value: statuses.any((s) => s.id == item.jobStatusId)
                    ? item.jobStatusId
                    : null,
                underline: const SizedBox.shrink(),
                isDense: true,
                isExpanded: true,
                items: statuses.map((status) {
                  return DropdownMenuItem<String>(
                    value: status.id,
                    child: Row(
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
                        Expanded(
                          child: Text(
                            status.label,
                            style: TextStyle(
                              fontSize: scaleProvider.mediumFontSize,
                              fontWeight: FontWeight.bold,
                            ),
                            overflow: TextOverflow.ellipsis,
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
                        ref.read(jobListStatusRiverpod);
                    final invoiceStatusProvider =
                        ref.read(invoiceStatusRiverpod);
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

    // Invoice Status
    if (prefsProvider.isColumnVisible('invoiceStatus')) {
      cells.add(DataCell(
        Builder(
          builder: (context) {
            final statusProvider = ref.watch(invoiceStatusRiverpod);
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
                        ref.read(invoiceStatusRiverpod);
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
                        ref.read(jobListStatusRiverpod);
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
                builder: (context) => reminder.ReminderDialog(
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

    // Job Type
    if (prefsProvider.isColumnVisible('jobType')) {
      cells.add(DataCell(
        Builder(
          builder: (context) {
            final jobTypeProvider = ref.watch(jobTypeRiverpod);
            final jobTypes = jobTypeProvider.jobTypes;
            final currentLabel =
                jobTypeProvider.getJobTypeLabel(item.jobTypeId);
            // Ensure current value is in the list
            final hasCurrentValue =
                jobTypes.any((jt) => jt.id == item.jobTypeId);
            return SizedBox(
              width: JobListColumnConfig.getWidth('jobType'),
              child: DropdownButton<String>(
                value: hasCurrentValue ? item.jobTypeId : null,
                hint: Text(currentLabel,
                    style: TextStyle(fontSize: scaleProvider.mediumFontSize)),
                underline: const SizedBox.shrink(),
                isDense: true,
                items: jobTypes.map((jt) {
                  return DropdownMenuItem<String>(
                    value: jt.id,
                    child: Text(
                      jt.label,
                      style: TextStyle(
                        fontSize: scaleProvider.mediumFontSize,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  );
                }).toList(),
                onChanged: (newTypeId) {
                  if (newTypeId != null) {
                    onUpdateField(item, 'jobType', newTypeId);
                  }
                },
              ),
            );
          },
        ),
      ));
    }

    // Area
    if (prefsProvider.isColumnVisible('area')) {
      cells.add(DataCell(
        SizedBox(
          width: JobListColumnConfig.getWidth('area'),
          child: Row(
            children: [
              Expanded(
                child: LinkCell(
                  value: item.area,
                  onSave: (value) => onUpdateField(item, 'area', value),
                  width: JobListColumnConfig.getWidth('area') - 28,
                  maxLines: 2,
                ),
              ),
              SizedBox(
                width: 24,
                child: IconButton(
                  icon: Icon(
                    Icons.link,
                    size: 16,
                    color: item.shareableMapId.isNotEmpty
                        ? Colors.green
                        : Colors.grey,
                  ),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  tooltip: item.shareableMapId.isNotEmpty
                      ? 'Map linked'
                      : 'Link existing map',
                  onPressed: () => _showMapLinkOptions(context, item, ref),
                ),
              ),
            ],
          ),
        ),
      ));
    }

    // Quantity / Vehicle
    if (prefsProvider.isColumnVisible('quantity')) {
      cells.add(DataCell(
        EditableVehicleComboCell(
          quantity: item.quantity,
          vehicleTrailerCombo: item.vehicleTrailerCombo,
          jobTypeId: item.jobTypeId,
          width: JobListColumnConfig.getWidth('quantity'),
          onSave: (quantity, vehicleTrailerCombo) {
            onUpdateField(item, 'vehicleTrailerCombo', {
              'quantity': quantity,
              'vehicleTrailerCombo': vehicleTrailerCombo,
            });
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
          jobTypeId: item.jobTypeId,
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

    // Refresh / View Update History
    if (prefsProvider.isColumnVisible('refresh')) {
      cells.add(DataCell(
        Center(
          child: item.updates.isNotEmpty
              ? Stack(
                  clipBehavior: Clip.none,
                  children: [
                    IconButton(
                      icon: Icon(Icons.history,
                          size: scaleProvider.mediumIconSize),
                      onPressed: () => onShowUpdateHistory(context, item),
                      tooltip: 'View Update History',
                    ),
                    if (jobListProvider
                        .getUpdatesAfterLastCheck(item)
                        .isNotEmpty)
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
                )
              : const SizedBox.shrink(),
        ),
      ));
    }

    // Actions
    if (prefsProvider.isColumnVisible('actions')) {
      cells.add(DataCell(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
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

  void _showMapLinkOptions(
      BuildContext context, JobListItem item, riverpod.WidgetRef ref) async {
    if (item.id.isEmpty) return;

    final result = await showDialog<MapPickerResult>(
      context: context,
      builder: (context) => const MapPickerDialog(),
    );

    if (result == null || !context.mounted) return;

    final jobListProvider = ref.read(jobListRiverpod);
    await jobListProvider.linkExistingMapToJob(
      jobId: item.id,
      mapId: result.mapId,
      monthKey: result.monthKey,
      mapName: result.mapName,
      storageFolderPath: result.storageFolderPath,
    );

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Map "${result.mapName}" linked to job'),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context, riverpod.WidgetRef ref) {
    throw UnimplementedError('Use buildCells() method instead');
  }
}

class JobListGrid extends riverpod.ConsumerStatefulWidget {
  const JobListGrid({super.key});

  @override
  riverpod.ConsumerState<JobListGrid> createState() => _JobListGridState();
}

class _JobListGridState extends riverpod.ConsumerState<JobListGrid> {
  final ScrollController _horizontalScrollController = ScrollController();
  final ScrollController _frozenHeaderScrollController = ScrollController();
  final ScrollController _mainVerticalScrollController = ScrollController();
  final ScrollController _frozenVerticalScrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  bool _isAddingJob = false;

  // Map update field names to column keys for highlighting changed cells
  static const Map<String, String> _updateFieldToColumnKey = {
    'date': 'date',
    'client': 'client',
    'jobStatusId': 'jobStatus',
    'invoiceStatusId': 'invoiceStatus',
    'jobType': 'jobType',
    'area': 'area',
    'quantity': 'quantity',
    'manDays': 'manDays',
    'collectionAddress': 'collectionAddress',
    'specialInstructions': 'specialInstructions',
    'collectionDate': 'collectionDate',
    'invoice': 'invoice',
    'amount': 'amount',
    'quantityDistributed': 'quantityDistributed',
    'invoiceDetails': 'invoiceDetails',
    'reportAddresses': 'reportAddresses',
    'whoToInvoice': 'whoToInvoice',
    'reminders': 'reminder',
  };

  Set<String> _getUpdatedColumnKeys(
      JobListProvider jobListProvider, JobListItem item) {
    final updates = jobListProvider.getUpdatesAfterLastCheck(item);
    return updates
        .map((u) => _updateFieldToColumnKey[u.fieldName] ?? u.fieldName)
        .toSet();
  }

  // Cached per-build map of item id -> updated column keys
  Map<String, Set<String>>? _updatedColumnsCache;
  int _updatedColumnsCacheVersion = -1;

  Set<String> _getCachedUpdatedColumnKeys(
      JobListProvider jobListProvider, JobListItem item) {
    // Invalidate cache when provider version changes (notifyListeners)
    final version =
        jobListProvider.hashCode ^ jobListProvider.lastCheckedTime.hashCode;
    if (_updatedColumnsCache == null ||
        _updatedColumnsCacheVersion != version) {
      _updatedColumnsCache = {};
      _updatedColumnsCacheVersion = version;
    }
    return _updatedColumnsCache!.putIfAbsent(
      item.id,
      () => _getUpdatedColumnKeys(jobListProvider, item),
    );
  }

  @override
  void initState() {
    super.initState();
    // Synchronize horizontal scrolling between main table and frozen header
    _horizontalScrollController.addListener(_syncHorizontalScroll);
    _frozenHeaderScrollController.addListener(_syncFrozenHeaderScroll);

    // Synchronize vertical scrolling between main table and frozen column
    _mainVerticalScrollController.addListener(_syncMainVerticalScroll);
    _frozenVerticalScrollController.addListener(_syncFrozenVerticalScroll);
  }

  bool _isSyncingHorizontal = false;
  bool _isSyncingVertical = false;

  void _syncHorizontalScroll() {
    if (_isSyncingHorizontal) return;
    _isSyncingHorizontal = true;
    if (_frozenHeaderScrollController.hasClients) {
      _frozenHeaderScrollController.jumpTo(_horizontalScrollController.offset);
    }
    _isSyncingHorizontal = false;
  }

  void _syncFrozenHeaderScroll() {
    if (_isSyncingHorizontal) return;
    _isSyncingHorizontal = true;
    if (_horizontalScrollController.hasClients) {
      _horizontalScrollController.jumpTo(_frozenHeaderScrollController.offset);
    }
    _isSyncingHorizontal = false;
  }

  void _syncMainVerticalScroll() {
    if (_isSyncingVertical) return;
    _isSyncingVertical = true;
    if (_frozenVerticalScrollController.hasClients) {
      _frozenVerticalScrollController
          .jumpTo(_mainVerticalScrollController.offset);
    }
    _isSyncingVertical = false;
  }

  void _syncFrozenVerticalScroll() {
    if (_isSyncingVertical) return;
    _isSyncingVertical = true;
    if (_mainVerticalScrollController.hasClients) {
      _mainVerticalScrollController
          .jumpTo(_frozenVerticalScrollController.offset);
    }
    _isSyncingVertical = false;
  }

  @override
  void dispose() {
    _horizontalScrollController.removeListener(_syncHorizontalScroll);
    _frozenHeaderScrollController.removeListener(_syncFrozenHeaderScroll);
    _mainVerticalScrollController.removeListener(_syncMainVerticalScroll);
    _frozenVerticalScrollController.removeListener(_syncFrozenVerticalScroll);
    _horizontalScrollController.dispose();
    _frozenHeaderScrollController.dispose();
    _mainVerticalScrollController.dispose();
    _frozenVerticalScrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final jobListProvider = ref.watch(jobListRiverpod);
    final prefsProvider = ref.watch(jobListPreferencesRiverpod);
    return Builder(
      builder: (context) {
        final scaleProvider = ref.watch(scaleRiverpod);
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
                        mode: Mode.joblist,
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
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                  ),
                  child: SizedBox(
                    height: 44, // Fixed height for uniformity
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Search field
                        Expanded(
                          flex: 3,
                          child: ValueListenableBuilder<bool>(
                            valueListenable:
                                jobListProvider.isSearchingNotifier,
                            builder: (context, isSearching, child) {
                              return TextField(
                                controller: _searchController,
                                style: const TextStyle(fontSize: 14),
                                decoration: InputDecoration(
                                  isDense: true,
                                  hintText:
                                      'Search by client, invoice, or area...',
                                  prefixIcon: Icon(Icons.search, size: 20),
                                  suffixIcon: isSearching
                                      ? Padding(
                                          padding: const EdgeInsets.all(12.0),
                                          child: SizedBox(
                                            width: 16,
                                            height: 16,
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
                                  border: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  contentPadding: const EdgeInsets.symmetric(
                                      vertical: 0, horizontal: 12),
                                ),
                                onChanged: jobListProvider.setSearchQuery,
                              );
                            },
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Invoice Status Filter
                        SizedBox(
                          width: 160,
                          child: MultiSelectInvoiceStatusFilter(
                            selectedStatusIds:
                                jobListProvider.invoiceStatusFilters,
                            onToggle: jobListProvider.toggleInvoiceStatusFilter,
                            onClear: jobListProvider.clearFilters,
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Simple Date Filter
                        SizedBox(
                          width: 220,
                          child: SimpleDateFilter(
                            startDate: jobListProvider.startDate,
                            endDate: jobListProvider.endDate,
                            onSingleDateSelected:
                                jobListProvider.setSimpleDateFilter,
                            onDateRangeSelected:
                                jobListProvider.setSimpleDateRangeFilter,
                            onClear: jobListProvider.clearDateFilter,
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Job Status Filter
                        SizedBox(
                          width: 160,
                          child: MultiSelectStatusFilter(
                            selectedStatusIds: jobListProvider.statusFilters,
                            onToggle: jobListProvider.toggleStatusFilter,
                            onClear: jobListProvider.clearFilters,
                          ),
                        ),
                        const SizedBox(width: 8),

                        // Sort by date button
                        OutlinedButton.icon(
                          onPressed: () {
                            jobListProvider.setSorting(
                              'date',
                              !jobListProvider.sortAscending,
                            );
                          },
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          icon: Icon(
                            jobListProvider.sortAscending
                                ? Icons.arrow_upward
                                : Icons.arrow_downward,
                            size: 16,
                          ),
                          label: const Text('Sort by Date',
                              style: TextStyle(fontSize: 13)),
                        ),
                        const SizedBox(width: 8),

                        // Clear Button
                        OutlinedButton.icon(
                          onPressed: () {
                            _searchController.clear();
                            jobListProvider.clearFilters();
                          },
                          style: OutlinedButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                          ),
                          icon: const Icon(Icons.clear, size: 16),
                          label: const Text('Clear',
                              style: TextStyle(fontSize: 13)),
                        ),
                        const SizedBox(width: 8),

                        // Add Job Button
                        FilledButton.icon(
                          onPressed: _isAddingJob
                              ? null
                              : () => _showAddJobDialog(context),
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                          ),
                          icon: _isAddingJob
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white),
                                )
                              : const Icon(Icons.add, size: 18),
                          label: Text(_isAddingJob ? 'Adding...' : 'Add Job',
                              style: const TextStyle(
                                  fontSize: 13, fontWeight: FontWeight.bold)),
                        ),
                        const SizedBox(width: 8),

                        // Column preferences button
                        IconButton.filledTonal(
                          onPressed: () {
                            showDialog(
                              context: context,
                              builder: (context) =>
                                  const JobListColumnsDialog(),
                            );
                          },
                          icon: const Icon(Icons.view_column, size: 20),
                          tooltip: 'Customize Columns',
                          style: IconButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(6)),
                          ),
                        ),
                        if (jobListProvider.pendingUpdatesCount > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            decoration: BoxDecoration(
                              color: Colors.orange.shade100,
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.orange.shade300),
                            ),
                            alignment: Alignment.center,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.sync,
                                    size: 16, color: Colors.orange.shade700),
                                const SizedBox(width: 4),
                                Text(
                                  '${jobListProvider.pendingUpdatesCount}',
                                  style: TextStyle(
                                    fontSize: 13,
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
                  child: jobListProvider.isApplyingFilter
                      ? Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 16),
                              Text(
                                'Updating results...',
                                style: TextStyle(
                                  fontSize: scaleProvider.largeFontSize,
                                  color: Colors.grey[600],
                                ),
                              ),
                            ],
                          ),
                        )
                      : jobListItems.isEmpty
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
                                  // Main scrollable table with virtualized rows
                                  Padding(
                                    padding: const EdgeInsets.only(
                                        top: 57), // Below frozen header
                                    child: Scrollbar(
                                      controller: _horizontalScrollController,
                                      thumbVisibility: true,
                                      trackVisibility: true,
                                      thickness: 12,
                                      radius: const Radius.circular(6),
                                      child: SingleChildScrollView(
                                        controller: _horizontalScrollController,
                                        scrollDirection: Axis.horizontal,
                                        child: SizedBox(
                                          width: JobListColumnConfig
                                              .calculateTotalWidth(
                                                  prefsProvider.visibleColumns),
                                          child: _buildVirtualizedRows(
                                            jobListItems: jobListItems,
                                            jobListProvider: jobListProvider,
                                            scaleProvider: scaleProvider,
                                            prefsProvider: prefsProvider,
                                            statusProvider:
                                                ref.read(jobListStatusRiverpod),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),

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
                                          minWidth: JobListFrozenHeaders
                                              .calculateWidth(prefsProvider),
                                        ),
                                        child: SingleChildScrollView(
                                          controller:
                                              _frozenHeaderScrollController,
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
                                    child: Builder(
                                      builder: (context) {
                                        // Use already-available data from outer Consumer3
                                        final frozenItems = jobListItems;
                                        final frozenStatusProvider =
                                            ref.read(jobListStatusRiverpod);
                                        return ListView.builder(
                                          controller:
                                              _frozenVerticalScrollController,
                                          itemCount: frozenItems.length,
                                          itemExtent: 48,
                                          addAutomaticKeepAlives: false,
                                          itemBuilder: (context, index) {
                                            final item = frozenItems[index];
                                            final statusColor =
                                                frozenStatusProvider
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
                                              child: Builder(
                                                builder: (context) {
                                                  final frozenUpdatedCols =
                                                      _getCachedUpdatedColumnKeys(
                                                          jobListProvider,
                                                          item);
                                                  return Row(
                                                    children: [
                                                      Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                vertical: 4),
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        decoration:
                                                            frozenUpdatedCols
                                                                    .contains(
                                                                        'date')
                                                                ? BoxDecoration(
                                                                    border:
                                                                        Border
                                                                            .all(
                                                                      color: Colors
                                                                          .orange,
                                                                      width: 1,
                                                                    ),
                                                                  )
                                                                : null,
                                                        child: EditableDateCell(
                                                          value: item.date,
                                                          width: 80,
                                                          jobTypeId:
                                                              item.jobTypeId,
                                                          jobData: {
                                                            'id': item.id,
                                                            'quantity':
                                                                item.quantity,
                                                            'vehicleType':
                                                                VehicleTrailerCombo
                                                                        .tryParse(
                                                                            item.vehicleTrailerCombo)
                                                                    ?.vehicleType
                                                                    .name,
                                                          },
                                                          onSave: (date) =>
                                                              _updateJobField(
                                                                  item,
                                                                  'date',
                                                                  date),
                                                        ),
                                                      ),
                                                      Container(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                vertical: 4),
                                                        alignment: Alignment
                                                            .centerLeft,
                                                        decoration:
                                                            frozenUpdatedCols
                                                                    .contains(
                                                                        'client')
                                                                ? BoxDecoration(
                                                                    border:
                                                                        Border
                                                                            .all(
                                                                      color: Colors
                                                                          .orange,
                                                                      width: 1,
                                                                    ),
                                                                  )
                                                                : null,
                                                        child:
                                                            EditableTableCell(
                                                          value: item.client,
                                                          onSave: (value) =>
                                                              _updateJobField(
                                                                  item,
                                                                  'client',
                                                                  value),
                                                          width: 250,
                                                          maxLines: 2,
                                                          validator: (value) =>
                                                              value?.isEmpty ==
                                                                      true
                                                                  ? 'Client required'
                                                                  : null,
                                                        ),
                                                      ),
                                                    ],
                                                  );
                                                },
                                              ),
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

  // Build virtualized rows using ListView.builder instead of DataTable
  // Only visible rows are built, dramatically reducing widget count
  Widget _buildVirtualizedRows({
    required List<JobListItem> jobListItems,
    required JobListProvider jobListProvider,
    required ScaleProvider scaleProvider,
    required JobListPreferencesProvider prefsProvider,
    required JobListStatusProvider statusProvider,
  }) {
    const double rowHeight = 48;

    // Build visible column keys in header order so widths match exactly
    final visibleColumns = <String>[];
    for (final col in JobListFrozenHeaders.columnOrder) {
      if (prefsProvider.isColumnVisible(col)) {
        visibleColumns.add(col);
      }
    }
    if (prefsProvider.isColumnVisible('refresh')) {
      visibleColumns.add('refresh');
    }
    if (prefsProvider.isColumnVisible('actions')) {
      visibleColumns.add('actions');
    }

    // No header-only columns remain — refresh now has a data cell
    const headerOnlyColumns = <String>{};

    return ListView.builder(
      controller: _mainVerticalScrollController,
      itemCount: jobListItems.length,
      itemExtent: rowHeight, // Fixed height enables efficient scrolling
      addAutomaticKeepAlives: false, // Don't keep scrolled-past rows alive
      itemBuilder: (context, index) {
        final item = jobListItems[index];
        final statusColor =
            (statusProvider.getStatusById(item.jobStatusId)?.color ??
                    Colors.grey)
                .withAlpha(240);

        // Build cells using existing builder
        final cellWidgets = JobListDataCellsBuilder(
          item: item,
          jobListProvider: jobListProvider,
          scaleProvider: scaleProvider,
          prefsProvider: prefsProvider,
          onUpdateField: _updateJobField,
          onShowUpdateHistory: _showUpdateHistory,
          onShowEditDialog: _showEditJobDialog,
          onShowCopyDialog: _showCopyJobDialog,
          onShowDeleteConfirmation: _showDeleteConfirmation,
          getVehicleTrailerComboFromQuantity:
              _getVehicleTrailerComboFromQuantity,
        ).buildCells(context, ref);

        // Map cells to columns, enforcing exact header widths and
        // inserting empty placeholders for header-only columns (refresh)
        final updatedCols = _getCachedUpdatedColumnKeys(jobListProvider, item);
        int cellIndex = 0;
        final rowChildren = <Widget>[];
        for (final col in visibleColumns) {
          final width = JobListColumnConfig.getWidth(col);
          if (headerOnlyColumns.contains(col)) {
            // Header-only column — add empty placeholder to maintain alignment
            rowChildren.add(SizedBox(width: width));
          } else if (cellIndex < cellWidgets.length) {
            final hasUpdate = updatedCols.contains(col);
            rowChildren.add(Container(
              width: width,
              decoration: hasUpdate
                  ? BoxDecoration(
                      border: Border.all(
                        color: Colors.orange,
                        width: 1,
                      ),
                    )
                  : null,
              child: cellWidgets[cellIndex].child,
            ));
            cellIndex++;
          }
        }

        return RepaintBoundary(
          child: Container(
            height: rowHeight,
            decoration: BoxDecoration(
              color: statusColor,
              border: Border(
                bottom: BorderSide(
                  color: Colors.grey[300]!,
                  width: 1,
                ),
              ),
            ),
            child: Row(children: rowChildren),
          ),
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
          updatedItem = item.copyWith(jobTypeId: value as String);
          break;
        case 'area':
          updatedItem = item.copyWith(area: value as String);
          break;
        case 'quantity':
          final newQuantity = (value as num).toInt();
          // Validate quantity for vehicle combo job types
          if (VehicleTrailerCombo.isVehicleJobType(item.jobTypeId) &&
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
        case 'vehicleTrailerCombo':
          final data = Map<String, dynamic>.from(value as Map);
          updatedItem = item.copyWith(
            quantity: (data['quantity'] as num).toInt(),
            vehicleTrailerCombo: data['vehicleTrailerCombo'] as String,
          );
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
          updatedItem =
              item.copyWith(quantityDistributed: (value as num).toInt());
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
      final jobListStatusProvider = ref.read(jobListStatusRiverpod);
      final invoiceStatusProvider = ref.read(invoiceStatusRiverpod);

      // Use debounced update system with change tracking
      ref.read(jobListRiverpod).updateJobListItemWithTracking(
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
            await ref.read(jobListRiverpod).addJobListItem(job);
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
        final jobListStatusProvider = ref.read(jobListStatusRiverpod);
        final invoiceStatusProvider = ref.read(invoiceStatusRiverpod);
        await ref.read(jobListRiverpod).updateJobListItemWithTracking(
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
    // Capture the source job's coordinates *before* opening the dialog so
    // that we can clone its linked map after the duplicate has been saved.
    // Both the source job's month-id (jobLists key, "MMM YYYY") and its
    // shareableMapId are needed by the `duplicateMapForJobCopy` callable.
    final sourceShareableMapId = item.shareableMapId;
    final sourceJobMonthId = _jobListMonthId(item.date);
    final sourceJobItemId = item.id;
    debugPrint(
        '📋 [CopyJob] source item id=$sourceJobItemId month=$sourceJobMonthId '
        'client="${item.client}" shareableMapId="$sourceShareableMapId"');

    // Create a new job with all fields copied but empty ID (so dialog treats it as new)
    // NOTE: `area` is cleared to suppress the auto-link logic from latching
    // onto the SOURCE map's share URL. The new map's URL is written back by
    // `_duplicateMapForCopiedJob` once the cloud function returns.
    final copiedJob = JobListItem(
      id: '', // Empty ID so dialog treats it as a new job
      invoice: '',
      amount: item.amount,
      client: item.client,
      jobStatusId: item.jobStatusId,
      invoiceStatusId: 'INV_NOT CREATED',
      jobTypeId: item.jobTypeId,
      area: sourceShareableMapId.isNotEmpty ? '' : item.area,
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
      builder: (context) => AddEditJobDialog(
        jobToEdit: copiedJob,
        mapWillBeCopied: sourceShareableMapId.isNotEmpty,
      ),
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
        // Persist the duplicate and capture the saved job (with its
        // freshly-generated Firestore id) so the map-clone callable can
        // bi-link the new job to its new map.
        JobListItem savedJob;
        if (skipAllocation) {
          // Dialog already saved via `addJobListItemAndReturn`, so `job`
          // already carries the new id.
          savedJob = job;
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
          savedJob =
              await ref.read(jobListRiverpod).addJobListItemAndReturn(job);
          if (context.mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Job copied and added successfully!'),
                backgroundColor: Colors.green,
              ),
            );
          }
        }

        // If the source job had a linked map, fire-and-forget a Cloud
        // Function call that clones the map's geometry into a new map and
        // bi-links it to the freshly-saved duplicate. The
        // `onJobListItemWritten` trigger then takes care of creating the
        // Cloud Storage folder for the new job and mirroring its path
        // onto the new map.
        debugPrint('📋 [CopyJob] saved duplicate id="${savedJob.id}"; '
            'sourceShareableMapId="$sourceShareableMapId" → '
            '${sourceShareableMapId.isNotEmpty && savedJob.id.isNotEmpty ? "WILL clone map" : "SKIP map clone"}');
        if (sourceShareableMapId.isNotEmpty && savedJob.id.isNotEmpty) {
          unawaited(_duplicateMapForCopiedJob(
            sourceJobMonthId: sourceJobMonthId,
            sourceJobItemId: sourceJobItemId,
            newJobMonthId: _jobListMonthId(savedJob.date),
            newJobItemId: savedJob.id,
            newJob: savedJob,
          ));
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

  /// Computes the `MMM YYYY` month-id used by `jobLists` for a date.
  /// Mirrors `MonthlyService.getMonthlyDocumentId` without taking a
  /// dependency on it from inside this widget.
  static String _jobListMonthId(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  /// Invokes the `duplicateMapForJobCopy` Cloud Function. Errors are
  /// surfaced via SnackBar but never throw — folder creation can be
  /// retried later by re-saving the job.
  Future<void> _duplicateMapForCopiedJob({
    required String sourceJobMonthId,
    required String sourceJobItemId,
    required String newJobMonthId,
    required String newJobItemId,
    required JobListItem newJob,
  }) async {
    debugPrint('📋 [CopyJob] calling duplicateMapForJobCopy: '
        'source=$sourceJobMonthId/$sourceJobItemId new=$newJobMonthId/$newJobItemId');
    try {
      final callable =
          FirebaseFunctions.instance.httpsCallable('duplicateMapForJobCopy');
      final result = await callable.call(<String, dynamic>{
        'sourceJobMonthId': sourceJobMonthId,
        'sourceJobItemId': sourceJobItemId,
        'newJobMonthId': newJobMonthId,
        'newJobItemId': newJobItemId,
      });
      debugPrint('✅ [CopyJob] duplicateMapForJobCopy result: ${result.data}');

      // After the map is cloned, generate a fresh share link and write the
      // new URL into the duplicated job's `area` field. The cloud function
      // already created the storage folder and set `storageFolderPath` on
      // both the new map and new job, so we forward that path here too.
      final data = result.data;
      if (data is Map) {
        final newMapId = data['newMapId'] as String?;
        final newMapMonthKey = data['newMapMonthKey'] as String?;
        final newMapName = data['newMapName'] as String? ?? '';
        final newFolderPath = data['storageFolderPath'] as String?;
        if (newMapId != null && newMapMonthKey != null && mounted) {
          await ref.read(jobListRiverpod).linkExistingMapToJob(
                jobId: newJobItemId,
                mapId: newMapId,
                monthKey: newMapMonthKey,
                mapName: newMapName,
                storageFolderPath: newFolderPath,
                fallbackJob: newJob,
              );
          debugPrint(
              '✅ [CopyJob] linked new map $newMapMonthKey/$newMapId to job $newJobItemId folder="$newFolderPath"');
        }
      }
    } catch (e, st) {
      debugPrint('❌ [CopyJob] duplicateMapForJobCopy failed: $e\n$st');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Map clone failed: $e'),
            backgroundColor: Colors.orange,
          ),
        );
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
                  await ref.read(jobListRiverpod).deleteJobListItem(item.id);
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
    final provider = ref.read(jobListRiverpod);
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
                                        jobTypeId: item.jobTypeId),
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

    final timeWithMs =
        '${dateTime.hour.toString().padLeft(2, '0')}:${dateTime.minute.toString().padLeft(2, '0')}:${dateTime.second.toString().padLeft(2, '0')}.${dateTime.millisecond.toString().padLeft(3, '0')}';

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago (${dateTime.day}/${dateTime.month} $timeWithMs)';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago ($timeWithMs)';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago ($timeWithMs)';
    } else {
      return 'Just now ($timeWithMs)';
    }
  }

  // Helper method to get vehicle/trailer combination label from quantity (for tracked changes display)
  String? _getVehicleTrailerComboFromQuantity(int quantity, String jobTypeId) {
    if (!VehicleTrailerCombo.isVehicleJobType(jobTypeId)) {
      return quantity.toString();
    }
    return VehicleTrailerCombo.fromLegacyQuantity(quantity,
            jobTypeId: jobTypeId)
        ?.label;
  }
}
