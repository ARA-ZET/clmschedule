/// Column configuration for JobListGrid
/// Maps column keys to their widths and properties
class JobListColumnConfig {
  /// Width of one icon slot in the Actions column.
  ///
  /// Every action renders in a box exactly this wide. Left to size themselves,
  /// an `IconButton` and a struck-through placeholder come out different
  /// widths, which made the delete icon sit in a different place on every row
  /// depending on which actions happened to be available.
  static const double actionSlotWidth = 40;

  /// Edit, copy, invoice, report, delete.
  static const int actionSlotCount = 5;

  static const Map<String, double> columnWidths = {
    'date': 80,
    'client': 252,
    'jobStatus': 200, // Match actual dropdown width
    'reminder': 80, // Icon column for reminders
    'invoiceStatus': 180, // Match actual dropdown width
    'jobType': 180,
    'area': 120,
    'quantity': 150,
    'manDays': 80,
    'collectionAddress': 200,
    'specialInstructions': 200,
    'collectionDate': 100,
    'invoice': 100,
    'amount': 130,
    'quantityDistributed': 110,
    'invoiceDetails': 120,
    'reportAddresses': 150,
    'whoToInvoice': 120,
    'refresh': 60,
    // Derived from the slots themselves, plus a little breathing room, so
    // adding a sixth action cannot silently clip it out of sight the way a
    // fourth once was at a hardcoded 120.
    'actions': actionSlotWidth * actionSlotCount + 12,
  };

  static double getWidth(String columnKey) {
    return columnWidths[columnKey] ?? 120;
  }

  static double calculateTotalWidth(Set<String> visibleColumns) {
    double total = 0;
    for (final column in visibleColumns) {
      total += getWidth(column);
    }
    return total;
  }
}
