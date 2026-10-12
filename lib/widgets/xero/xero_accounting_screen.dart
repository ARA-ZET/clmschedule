import 'package:flutter/material.dart';

import '../zoho/zoho_table.dart';
import 'xero_customers_view.dart';
import 'xero_invoices_view.dart';

/// Community Life Media's Xero books — invoices and customers under one roof.
///
/// A single destination with tabs rather than two separate screens reached from
/// a menu: invoices and customers are two views of the same ledger, and moving
/// between them is common enough that a back-and-push round trip is friction.
///
/// The two tab bodies keep their state alive
/// ([AutomaticKeepAliveClientMixin]), so switching tabs does not refetch.
/// Flutter builds a [TabBarView] child only when it is first shown, so opening
/// this screen costs one API call, not two — which matters on Xero's
/// 1,000-call daily budget for an uncertified app.
class XeroAccountingScreen extends StatelessWidget {
  /// Tab to open on, 0 = Invoices.
  final int initialIndex;

  const XeroAccountingScreen({super.key, this.initialIndex = 0});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      initialIndex: initialIndex,
      child: Scaffold(
        backgroundColor: ZohoPalette.pageBackground,
        appBar: AppBar(
          title: const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Xero'),
              // Named so nobody has to guess whose books they are in — Junk &
              // Stuff's Zoho books live on the Collection Schedule.
              Text(
                'Community Life Media',
                style: TextStyle(fontSize: 11, color: ZohoPalette.textMuted),
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
        body: const TabBarView(
          children: [
            XeroInvoicesView(),
            XeroCustomersView(),
          ],
        ),
      ),
    );
  }
}
