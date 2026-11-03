import 'package:flutter/material.dart';

import 'application/services/expense_application_service.dart';
import 'application/services/product_application_service.dart';
import 'application/services/sales_application_service.dart';
import 'core/app_error.dart';
import 'data/account_repository.dart';
import 'data/expense_repository.dart';
import 'data/local_database.dart';
import 'data/product_repository.dart';
import 'data/sales_repository.dart';
import 'data/warehouse_repository.dart';
import 'features/branch_warehouse_page.dart';
import 'features/data_transfer_page.dart';
import 'features/expenses_page.dart';
import 'features/products_page.dart';
import 'features/sales_page.dart';

void main() {
  runApp(const SmartMerchantApp());
}

class SmartMerchantApp extends StatelessWidget {
  const SmartMerchantApp({super.key});

  @override
  Widget build(BuildContext context) {
    const seedGreen = Color(0xFF247A52);

    return MaterialApp(
      title: 'عدة التاجر الذكي',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: seedGreen,
          brightness: Brightness.light,
        ),
        scaffoldBackgroundColor: const Color(0xFFF5F8F5),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F8F5),
          foregroundColor: Color(0xFF183C2B),
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            color: Color(0xFF183C2B),
            fontSize: 21,
            fontWeight: FontWeight.w700,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
          color: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
            side: const BorderSide(color: Color(0xFFE7EEE8)),
          ),
        ),
      ),
      home: const Directionality(
        textDirection: TextDirection.rtl,
        child: HomeDashboard(),
      ),
    );
  }
}

class HomeDashboard extends StatelessWidget {
  const HomeDashboard({super.key});

  static const modules = <({IconData icon, String title, String subtitle})>[
    (icon: Icons.inventory_2_outlined, title: 'المنتجات والمخزون', subtitle: 'إضافة المنتجات ومتابعة الأرصدة'),
    (icon: Icons.point_of_sale_outlined, title: 'المبيعات والفواتير', subtitle: 'تسجيل عمليات البيع والمرتجعات'),
    (icon: Icons.account_balance_wallet_outlined, title: 'المصروفات والأرباح', subtitle: 'تسجيل المصروفات ومراجعة الملخص'),
    (icon: Icons.backup_outlined, title: 'النسخ الاحتياطي وتصدير البيانات', subtitle: 'حفظ نسخة محلية وتصدير ملفات CSV'),
    (icon: Icons.warehouse_outlined, title: 'الفروع والمخازن', subtitle: 'إدارة الأرصدة والتحويلات والتسويات'),
  ];

  Future<void> _openModule(BuildContext context, int index) async {
    try {
      final database = await openLocalDatabase();
      if (!context.mounted) {
        await database.close();
        return;
      }

      try {
        final Widget page = switch (index) {
          0 => ProductsPage(
              repository: ProductApplicationService(ProductRepository(database)),
              catalog: ProductRepository(database),
            ),
          1 => SalesPage(
              products: ProductApplicationService(ProductRepository(database)),
              sales: SalesApplicationService(SalesRepository(database)),
              warehouseStore: WarehouseRepository(database),
              accountRepository: AccountRepository(database),
            ),
          2 => ExpensesPage(repository: ExpenseApplicationService(ExpenseRepository(database))),
          3 => DataTransferPage(database: database),
          4 => BranchWarehousePage(store: WarehouseRepository(database)),
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
        2 => 'تعذر فتح شاشة المصروفات.',
        3 => 'تعذر فتح أدوات تصدير البيانات.',
        4 => 'تعذر فتح إدارة الفروع والمخازن.',
        _ => 'تعذر فتح القسم المطلوب.',
      };
      final operation = switch (index) {
        0 => 'database.open',
        1 => 'sales.open',
        2 => 'expenses.open',
        3 => 'data_transfer.open',
        4 => 'warehouse.open',
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
      appBar: AppBar(title: const Text('عدة التاجر الذكي')),
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