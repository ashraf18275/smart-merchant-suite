import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/main.dart';

void main() {
  testWidgets('shows Arabic app title and current modules', (tester) async {
    await tester.pumpWidget(const SmartMerchantApp());

    expect(find.text('عدة التاجر الذكي'), findsOneWidget);
    expect(find.text('أقسام البرنامج'), findsOneWidget);
    expect(find.text('المنتجات والمخزون'), findsOneWidget);
    expect(find.textContaining('— قيد التطوير'), findsNWidgets(3));
  });
}
