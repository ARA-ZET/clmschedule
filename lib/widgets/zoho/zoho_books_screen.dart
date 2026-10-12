import 'package:flutter/material.dart';

import 'zoho_customers_view.dart';
import 'zoho_invoices_view.dart';
import 'zoho_table.dart';

/// A company's Zoho Books — invoices and customers under one roof. Junk &
/// Stuff opens it from the Collection Schedule; Happy Sun embeds the two views
/// directly as tabs of its own section.
///
/// The counterpart to `XeroAccountingScreen`, and deliberately identical in
/// shape. These were two separate destinations off the Collection Schedule
/// menu, so moving between an invoice and the customer it belongs to meant a
/// back-and-push round trip through the menu. They are two views of the same
/// ledger; tabs say so.
///
/// Both tab bodies keep their state alive ([AutomaticKeepAliveClientMixin]), and
/// Flutter builds a [TabBarView] child only when it is first shown — so opening
/// this screen costs one Zoho fetch, not two, and switching tabs afterwards
/// costs none.
class ZohoBooksScreen extends StatelessWidget {
  /// Tab to open on, 0 = Invoices.
  final int initialIndex;

  /// Zoho Books organisation id — see `ZohoOrg`.
  final String orgId;

  /// Whose books these are, shown under the title.
  final String companyName;

  const ZohoBooksScreen({
    super.key,
    required this.orgId,
    required this.companyName,
    this.initialIndex = 0,
  });

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialIndex,
      child: Scaffold(
        backgroundColor: ZohoPalette.pageBackground,
        appBar: AppBar(
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Zoho Books'),
              // Named so nobody has to guess whose books they are in —
              // Community Life Media's Xero books live on the Job List.
              Text(
                companyName,
                style:
                    const TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
              ),
            ],
          ),
          backgroundColor: ZohoPalette.surface,
          foregroundColor: ZohoPalette.textPrimary,
          elevation: 0,
          scrolledUnderElevation: 0,
          shape: const Border(bottom: BorderSide(color: ZohoPalette.border)),
          bottom: const TabBar(
            labelColor: ZohoPalette.link,
            unselectedLabelColor: ZohoPalette.textMuted,
            indicatorColor: ZohoPalette.link,
            indicatorWeight: 2.5,
            labelStyle: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            unselectedLabelStyle: TextStyle(fontSize: 13),
            tabs: [
              Tab(icon: Icon(Icons.receipt_long, size: 18), text: 'Invoices'),
              Tab(
                  icon: Icon(Icons.people_outline, size: 18),
                  text: 'Customers'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            ZohoInvoicesView(orgId: orgId),
            ZohoCustomersView(orgId: orgId),
          ],
        ),
      ),
    );
  }
}
