import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/main.dart';

void main() {
  testWidgets('shows a compact two-column Arabic dashboard', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const SmartMerchantApp());

    expect(find.text('عدة التاجر الذكي'), findsOneWidget);
    expect(find.text('أقسام البرنامج'), findsNothing);
    expect(find.text('نسخة تجريبية'), findsNothing);
    expect(find.text('إدارة متجرك من مكان واحد'), findsNothing);
    expect(find.text('المنتجات والمخزون'), findsOneWidget);
    expect(find.text('المبيعات والفواتير'), findsOneWidget);
    expect(find.text('المشتريات والاستلام'), findsOneWidget);
    expect(find.text('المصروفات والأرباح'), findsOneWidget);
    expect(find.text('النسخ الاحتياطي وتصدير البيانات'), findsOneWidget);
    expect(find.text('الفروع والمخازن'), findsOneWidget);
    expect(find.text('حسابات العملاء والموردين'), findsOneWidget);
    expect(find.textContaining('قيد التطوير'), findsNothing);
  });
}
