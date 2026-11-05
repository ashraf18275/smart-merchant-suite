import 'package:flutter/material.dart';

import '../application/services/expense_application_service.dart';
import '../application/services/product_application_service.dart';
import '../application/services/sales_application_service.dart';
import '../core/app_error.dart';
import '../data/account_repository.dart';
import '../data/cashbook_repository.dart';
import '../data/expense_repository.dart';
import '../data/local_database.dart';
import '../data/product_repository.dart';
import '../data/purchase_repository.dart';
import '../data/sales_repository.dart';
import '../data/warehouse_repository.dart';
import 'accounts_page.dart';
import 'cashbook_page.dart';
import 'branch_warehouse_page.dart';
import 'data_transfer_page.dart';
import 'expenses_page.dart';
import 'products_page.dart';
import 'purchases_page.dart';
import 'sales_page.dart';

class HomeDashboard extends StatelessWidget {
  const HomeDashboard({
    super.key,
    this.cloudEnabled = false,
    this.businessId,
    this.initialBranchId,
    this.initialWarehouseId,
    this.onOpenCloud,
  });

  final bool cloudEnabled;
  final String? businessId;
  final int? initialBranchId;
  final int? initialWarehouseId;
  final VoidCallback? onOpenCloud;

  static const modules = <({IconData icon, String title, String subtitle})>[
    (icon: Icons.inventory_2_outlined, title: 'المنتجات والمخزون', subtitle: 'إضافة المنتجات ومتابعة الأرصدة'),
    (icon: Icons.point_of_sale_outlined, title: 'المبيعات والفواتير', subtitle: 'تسجيل عمليات البيع والمرتجعات'),
    (icon: Icons.shopping_cart_checkout_outlined, title: 'المشتريات والاستلام', subtitle: 'فواتير الموردين واستلام المخزون'),
    (icon: Icons.account_balance_wallet_outlined, title: 'المصروفات والأرباح', subtitle: 'تسجيل المصروفات ومراجعة الملخص'),
    (icon: Icons.backup_outlined, title: 'النسخ الاحتياطي وتصدير البيانات', subtitle: 'حفظ نسخة محلية وتصدير ملفات CSV'),
    (icon: Icons.warehouse_outlined, title: 'الفروع والمخازن', subtitle: 'إدارة الأرصدة والتحويلات والتسويات'),
    (icon: Icons.account_balance_outlined, title: 'حسابات العملاء والموردين', subtitle: 'كشوف الحساب والتحصيل والسداد'),
    (icon: Icons.account_balance_wallet_outlined, title: 'الصندوق وسجل النشاط', subtitle: 'المقبوضات والمدفوعات وسجل العمليات'),
  ];

  Future<void> _openModule(BuildContext context, int index) async {
    try {
      final database = await openLocalDatabase(businessId: businessId);
      if (!context.mounted) {
        await database.close();
        return;
      }

      try {
        final Widget page = switch (index) {
          0 => ProductsPage(
              repository: ProductApplicationService(ProductRepository(database)),
              catalog: ProductRepository(database),
              initialWarehouseId: initialWarehouseId,
            ),
          1 => SalesPage(
              products: ProductApplicationService(ProductRepository(database)),
              sales: SalesApplicationService(SalesRepository(database)),
              warehouseStore: WarehouseRepository(database),
              accountRepository: AccountRepository(database),
              initialWarehouseId: initialWarehouseId,
            ),
          2 => PurchasesPage(
              purchases: PurchaseRepository(database),
              products: ProductRepository(database),
              warehouses: WarehouseRepository(database),
              initialWarehouseId: initialWarehouseId,
            ),
          3 => ExpensesPage(repository: ExpenseApplicationService(ExpenseRepository(database))),
          4 => DataTransferPage(database: database),
          5 => BranchWarehousePage(
              store: WarehouseRepository(database),
              initialBranchId: initialBranchId,
              initialWarehouseId: initialWarehouseId,
            ),
          6 => AccountsPage(
              accounts: AccountRepository(database),
              purchases: PurchaseRepository(database),
            ),
          7 => CashbookPage(repository: CashbookRepository(database)),
          _ => const SizedBox.shrink(),
        };

        await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
      } finally {
        await database.close();
      }
    } catch (error) {
      if (!context.mounted) return;
      final fallback = switch (index) {
        0 => 'تعذر فتح قاعدة البيانات المحلية.',
        1 => 'تعذر فتح شاشة المبيعات.',
        2 => 'تعذر فتح شاشة المشتريات.',
        3 => 'تعذر فتح شاشة المصروفات.',
        4 => 'تعذر فتح أدوات تصدير البيانات.',
        5 => 'تعذر فتح إدارة الفروع والمخازن.',
        6 => 'تعذر فتح حسابات العملاء والموردين.',
        7 => 'تعذر فتح الصندوق وسجل النشاط.',
        _ => 'تعذر فتح القسم المطلوب.',
      };
      final operation = switch (index) {
        0 => 'database.open',
        1 => 'sales.open',
        2 => 'purchases.open',
        3 => 'expenses.open',
        4 => 'data_transfer.open',
        5 => 'warehouse.open',
        6 => 'accounts.open',
        7 => 'cashbook.open',
        _ => 'module.open',
      };
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(appErrorMessage(error, fallback: fallback, operation: operation))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final columns = width >= 900 ? 4 : width >= 600 ? 3 : 2;

    return Scaffold(
      appBar: AppBar(
        title: const Text('عدة التاجر الذكي'),
        actions: [
          if (cloudEnabled && onOpenCloud != null)
            IconButton(
              tooltip: 'الحساب السحابي',
              icon: const Icon(Icons.cloud_outlined),
              onPressed: onOpenCloud,
            ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: GridView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: modules.length,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 1.05,
          ),
          itemBuilder: (context, index) {
            final module = modules[index];
            return Card(
              child: InkWell(
                borderRadius: BorderRadius.circular(18),
                onTap: () => _openModule(context, index),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 58,
                        height: 58,
                        decoration: BoxDecoration(color: const Color(0xFFEAF4ED), borderRadius: BorderRadius.circular(17)),
                        child: Icon(module.icon, color: const Color(0xFF247A52), size: 30),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        module.title,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(color: const Color(0xFF20372A), fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}