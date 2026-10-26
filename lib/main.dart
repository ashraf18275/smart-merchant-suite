import 'package:flutter/material.dart';

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
        colorScheme: ColorScheme.fromSeed(seedColor: seedGreen),
        scaffoldBackgroundColor: const Color(0xFFF7F9F7),
        cardTheme: const CardThemeData(
          elevation: 0,
          margin: EdgeInsets.zero,
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
      subtitle: 'إدارة الأصناف والكميات — قيد التطوير',
    ),
    (
      icon: Icons.point_of_sale_outlined,
      title: 'المبيعات والفواتير',
      subtitle: 'تسجيل المبيعات والمرتجعات — قيد التطوير',
    ),
    (
      icon: Icons.account_balance_wallet_outlined,
      title: 'المصروفات والأرباح',
      subtitle: 'تقارير مالية دقيقة — قيد التطوير',
    ),
    (
      icon: Icons.backup_outlined,
      title: 'النسخ الاحتياطي والمزامنة',
      subtitle: 'حماية البيانات والعمل بين الأجهزة — قيد التطوير',
    ),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('عدة التاجر الذكي'),
        centerTitle: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final columns = constraints.maxWidth >= 900
              ? 4
              : constraints.maxWidth >= 560
                  ? 2
                  : 1;

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              Card(
                color: Theme.of(context).colorScheme.primaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'إدارة محلك من مكان واحد',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'نسخة تأسيسية قيد التطوير. لم تُفعّل وظائف البيع أو المخزون أو الحسابات بعد.',
                      ),
                      const SizedBox(height: 12),
                      const Chip(
                        avatar: Icon(Icons.construction_outlined, size: 18),
                        label: Text('نسخة تجريبية أولية'),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'أقسام البرنامج المخططة',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: columns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  // Give Arabic titles and subtitles enough room on narrow screens.
                  mainAxisExtent: constraints.maxWidth < 560 ? 180 : 164,
                ),
                itemCount: modules.length,
                itemBuilder: (context, index) {
                  final module = modules[index];
                  return Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            module.icon,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(height: 10),
                          Text(
                            module.title,
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            module.subtitle,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ],
          );
        },
      ),
    );
  }
}
