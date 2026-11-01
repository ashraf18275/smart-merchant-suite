import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/main.dart';

void main() {
  testWidgets('shows the polished Arabic dashboard and all current modules', (tester) async {
    await tester.pumpWidget(const SmartMerchantApp());

    expect(find.text('عدة التاجر الذكي'), findsOneWidget);
    expect(find.text('إدارة متجرك من مكان واحد'), findsOneWidget);
    expect(find.text('أقسام البرنامج'), findsOneWidget);
    expect(find.text('المنتجات والمخزون'), findsOneWidget);
    expect(find.text('المبيعات والفواتير'), findsOneWidget);
    expect(find.textContaining('قيد التطوير'), findsNothing);

    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(
      find.text('النسخ الاحتياطي وتصدير البيانات'),
      250,
      scrollable: scrollable,
    );
    expect(find.text('النسخ الاحتياطي وتصدير البيانات'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('الفروع والمخازن'),
      250,
      scrollable: scrollable,
    );
    expect(find.text('الفروع والمخازن'), findsOneWidget);
  });
}
