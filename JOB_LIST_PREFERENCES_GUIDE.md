# Job List Column Preferences - Implementation Guide

## Overview

The job list now supports user-specific column visibility preferences that are saved to Firestore. Each user can customize which columns they want to see, optimizing their workflow.

## Features Implemented

### 1. **User Preferences Model** (`lib/models/job_list_preferences.dart`)

- Stores column visibility settings per user
- Default columns: All visible by default
- Required columns (cannot be hidden): date, client, jobStatus, refresh, actions
- Firestore serialization/deserialization

### 2. **Preferences Service** (`lib/services/job_list_preferences_service.dart`)

- Saves/loads preferences from Firestore path: `/userPreferences/{userId}/jobList/preferences`
- Real-time streaming of preference changes
- Reset to defaults functionality

### 3. **Preferences Provider** (`lib/providers/job_list_preferences_provider.dart`)

- Manages preferences state
- Optimistic updates with fallback on error
- Real-time synchronization across devices
- Helper methods: `isColumnVisible()`, `toggleColumnVisibility()`, `canToggleColumn()`

### 4. **Column Preferences Dialog** (`lib/widgets/job_list_columns_dialog.dart`)

- Visual UI for customizing column visibility
- Shows required columns with badges
- Summary of visible/hidden columns
- Reset to defaults button

### 5. **Column Configuration** (`lib/widgets/job_list_column_config.dart`)

- Centralized column width definitions
- Consistent widths between frozen and scrollable columns
- Helper methods for calculating total width

## Current Integration Status

### ✅ Completed

1. All models, services, and providers created
2. Preferences dialog UI implemented
3. Preferences button added to job list toolbar (column icon)
4. Provider registered in `main.dart`
5. Firestore structure defined

### 🚧 Remaining Integration Steps

The job list grid rendering needs to be updated to respect column visibility preferences. Here's how to complete the integration:

#### Step 1: Update DataTable Columns (Main Table)

In `job_list_grid.dart`, around line 590-660, replace the hardcoded columns with dynamic generation:

```dart
columns: _buildDataColumns(context),
```

Add this method to `_JobListGridState`:

```dart
List<DataColumn> _buildDataColumns(BuildContext context) {
  final prefsProvider = context.watch<JobListPreferencesProvider>();
  final columnOrder = [
    'date', 'client', 'jobStatus', 'invoiceStatus', 'jobType',
    'area', 'quantity', 'manDays', 'collectionAddress',
    'specialInstructions', 'collectionDate', 'invoice', 'amount',
    'quantityDistributed', 'invoiceDetails', 'reportAddresses',
    'whoToInvoice', 'actions'
  ];

  return columnOrder
      .where((col) => prefsProvider.isColumnVisible(col))
      .map((col) => _buildDataColumn(col))
      .toList();
}

DataColumn _buildDataColumn(String columnKey) {
  final labels = {
    'date': 'Date',
    'client': 'Client',
    'jobStatus': 'Job Status',
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

  return DataColumn(
    label: DataTableHeaderWidget(
      text: labels[columnKey] ?? columnKey,
      textColor: columnKey == 'client' ? Colors.black : null,
    ),
  );
}
```

#### Step 2: Update DataTable Rows (Data Cells)

In the `rows:` section, wrap each DataCell generation with visibility checks:

```dart
rows: jobListItems.map((item) {
  return DataRow(
    color: WidgetStateProperty.all(statusColor),
    cells: _buildDataCells(context, item),
  );
}).toList(),
```

Add this method:

```dart
List<DataCell> _buildDataCells(BuildContext context, JobListItem item) {
  final prefsProvider = context.watch<JobListPreferencesProvider>();
  final cells = <DataCell>[];

  if (prefsProvider.isColumnVisible('date')) {
    cells.add(DataCell(EditableDateCell(/* ... */)));
  }
  if (prefsProvider.isColumnVisible('client')) {
    cells.add(DataCell(EditableTableCell(/* ... */)));
  }
  // ... repeat for all columns

  return cells;
}
```

#### Step 3: Update Frozen Column Header (Lines ~1240-1440)

Replace the frozen header column widgets with dynamic generation:

```dart
children: _buildFrozenHeaders(context, scaleProvider),
```

Add this method:

```dart
List<Widget> _buildFrozenHeaders(BuildContext context, ScaleProvider scaleProvider) {
  final prefsProvider = context.watch<JobListPreferencesProvider>();
  final headers = <Widget>[];

  // Always include date, client, jobStatus (frozen columns)
  if (prefsProvider.isColumnVisible('date')) {
    headers.add(FrozenHeaderCell(text: 'Date', width: 80));
  }
  if (prefsProvider.isColumnVisible('client')) {
    headers.add(FrozenHeaderCell(text: 'Client', width: 252));
  }
  if (prefsProvider.isColumnVisible('jobStatus')) {
    headers.add(FrozenHeaderCell(text: 'Job Status', width: 150));
  }

  // Add remaining visible columns
  // ... (continue for all columns)

  return headers;
}
```

#### Step 4: Update Frozen Column Data Rows (Lines ~1450-1500)

Apply similar filtering to the frozen column data cells.

#### Step 5: Calculate Dynamic Widths

Update the frozen column container width dynamically:

```dart
width: _calculateFrozenColumnWidth(context),
```

Add this method:

```dart
double _calculateFrozenColumnWidth(BuildContext context) {
  final prefsProvider = context.watch<JobListPreferencesProvider>();
  double width = 0;

  if (prefsProvider.isColumnVisible('date')) width += 80;
  if (prefsProvider.isColumnVisible('client')) width += 252;
  if (prefsProvider.isColumnVisible('jobStatus')) width += 150;

  return width;
}
```

## Firestore Security Rules

Add these rules to `firestore.rules`:

```javascript
match /userPreferences/{userId}/jobList/{document=**} {
  allow read, write: if request.auth != null && request.auth.uid == userId;
}
```

## Usage

1. **Open Preferences**: Click the column icon (☰) in the job list toolbar
2. **Toggle Columns**: Check/uncheck columns to show/hide them
3. **View Summary**: See count of visible vs hidden columns
4. **Reset**: Click "Reset" button to restore all columns
5. **Required Columns**: Date, Client, Job Status, Refresh, and Actions cannot be hidden

## Testing

1. Open job list and click column preferences icon
2. Hide some optional columns (e.g., Invoice Details, Report Addresses)
3. Verify columns disappear from both main table and frozen header
4. Refresh page - preferences should persist
5. Login as different user - should see default columns
6. Test on multiple devices - changes should sync in real-time

## Column Widths Reference

```dart
'date': 80,
'client': 252,
'jobStatus': 150,
'invoiceStatus': 150,
'jobType': 200,
'area': 120,
'quantity': 150,
'manDays': 80,
'collectionAddress': 200,
'specialInstructions': 200,
'collectionDate': 100,
'invoice': 150,
'amount': 120,
'quantityDistributed': 110,
'invoiceDetails': 120,
'reportAddresses': 150,
'whoToInvoice': 120,
'refresh': 60,
'actions': 120,
```

## Benefits

- **Personalized Workflow**: Each user sees only columns relevant to their role
- **Improved Performance**: Fewer columns = faster rendering
- **Better UX**: Less scrolling, cleaner interface
- **Persistent**: Preferences sync across devices via Firestore
- **Safe**: Required columns cannot be accidentally hidden

## Next Steps

Complete the integration by updating the `job_list_grid.dart` DataTable and frozen column rendering to use the preferences provider. Follow the steps above to make columns dynamically visible based on user preferences.
