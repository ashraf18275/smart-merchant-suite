import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/main.dart';

void main() {
  testWidgets('shows the polished Arabic dashboard and current modules', (tester) async {
    await tester.pumpWidget(const SmartMerchantApp());

    expect(find.text('عدة التاجر الذكي'), findsOneWidget);
    expect(find.text('إدارة متجرك من مكان واحد'), findsOneWidget);
    expect(find.text('أقسام البرنامج'), findsOneWidget);
    expect(find.text('المنتجات والمخزون'), findsOneWidget);
    expect(find.text('المبيعات والفواتير'), findsOneWidget);
    expect(find.text('المصروفات والأرباح'), findsOneWidget);
    expect(find.text('النسخ الاحتياطي وتصدير البيانات'), findsOneWidget);
    expect(find.text('الفروع والمخازن'), findsOneWidget);
    expect(find.textContaining('قيد التطوير'), findsNothing);
  });
}
