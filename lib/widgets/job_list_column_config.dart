/// Column configuration for JobListGrid
/// Maps column keys to their widths and properties
class JobListColumnConfig {
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
    'amount': 100,
    'quantityDistributed': 110,
    'invoiceDetails': 120,
    'reportAddresses': 150,
    'whoToInvoice': 120,
    'refresh': 60,
    'actions': 120,
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
