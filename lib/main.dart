import 'package:flutter/material.dart';

import 'application/services/expense_application_service.dart';
import 'application/services/product_application_service.dart';
import 'application/services/sales_application_service.dart';
import 'core/app_error.dart';
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
    (
      icon: Icons.inventory_2_outlined,
      title: 'المنتجات والمخزون',
      subtitle: 'إضافة المنتجات ومتابعة الأرصدة',
    ),
    (
      icon: Icons.point_of_sale_outlined,
      title: 'المبيعات والفواتير',
      subtitle: 'تسجيل عمليات البيع والمرتجعات',
    ),
    (
      icon: Icons.account_balance_wallet_outlined,
      title: 'المصروفات والأرباح',
      subtitle: 'تسجيل المصروفات ومراجعة الملخص',
    ),
    (
      icon: Icons.backup_outlined,
      title: 'النسخ الاحتياطي وتصدير البيانات',
      subtitle: 'حفظ نسخة محلية وتصدير ملفات CSV',
    ),
    (
      icon: Icons.warehouse_outlined,
      title: 'الفروع والمخازن',
      subtitle: 'إدارة الأرصدة والتحويلات والتسويات',
    ),
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
              repository: ProductApplicationService(
                ProductRepository(database),
              ),
              catalog: ProductRepository(database),
            ),
          1 => SalesPage(
              products: ProductApplicationService(ProductRepository(database)),
              sales: SalesApplicationService(SalesRepository(database)),
              warehouseStore: WarehouseRepository(database),
            ),
          2 => ExpensesPage(
              repository: ExpenseApplicationService(
                ExpenseRepository(database),
              ),
            ),
          3 => DataTransferPage(database: database),
          4 => BranchWarehousePage(store: WarehouseRepository(database)),
          _ => const SizedBox.shrink(),
        };

        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => page),
        );
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
        SnackBar(
          content: Text(
            appErrorMessage(error, fallback: fallback, operation: operation),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('عدة التاجر الذكي'),
      ),
      body: SafeArea(
        top: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 28),
          children: [
            _WelcomePanel(textTheme: textTheme),
            const SizedBox(height: 26),
            Row(
              children: [
                Text(
                  'أقسام البرنامج',
                  style: textTheme.titleLarge?.copyWith(
                    color: const Color(0xFF183C2B),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                Text(
                  '5 أقسام',
                  style: textTheme.labelMedium?.copyWith(
                    color: colors.primary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...List.generate(modules.length, (index) {
              final module = modules[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Card(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(18),
                    onTap: () => _openModule(context, index),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 15,
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: const Color(0xFFEAF4ED),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(
                              module.icon,
                              color: const Color(0xFF247A52),
                              size: 25,
                            ),
                          ),
                          const SizedBox(width: 13),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  module.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.titleMedium?.copyWith(
                                    color: const Color(0xFF20372A),
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  module.subtitle,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFF68766D),
                                    height: 1.35,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(
                            Icons.chevron_left_rounded,
                            color: Color(0xFF8A9A8F),
                            size: 23,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
            const SizedBox(height: 8),
            Center(
              child: Text(
                'إدارة متجرك ببساطة ووضوح',
                style: textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF829087),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WelcomePanel extends StatelessWidget {
  const _WelcomePanel({required this.textTheme});

  final TextTheme textTheme;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topRight,
          end: Alignment.bottomLeft,
          colors: [Color(0xFF247A52), Color(0xFF18583B)],
        ),
        borderRadius: BorderRadius.circular(24),
        boxShadow: const [
          BoxShadow(
            color: Color(0x1C18583B),
            blurRadius: 18,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(30),
              border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
            ),
            child: const Text(
              'نسخة تجريبية',
              style: TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(height: 17),
          Text(
            'إدارة متجرك من مكان واحد',
            style: textTheme.headlineSmall?.copyWith(
              color: Colors.white,
              fontWeight: FontWeight.w800,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 9),
          Text(
            'تابع المنتجات والمخزون والمبيعات والمصروفات من واجهة واحدة سهلة الاستخدام.',
            style: textTheme.bodyMedium?.copyWith(
              color: Colors.white.withValues(alpha: 0.92),
              height: 1.65,
            ),
          ),
          const SizedBox(height: 17),
          const Row(
            children: [
              Icon(Icons.touch_app_outlined, color: Colors.white, size: 18),
              SizedBox(width: 7),
              Text(
                'اختر أحد الأقسام للبدء',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
