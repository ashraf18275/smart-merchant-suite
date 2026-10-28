import 'package:flutter_test/flutter_test.dart';
import 'package:smart_merchant_suite/core/app_error.dart';

void main() {
  test('shows the localized message for an expected application error', () {
    const error = AppException('الكمية غير كافية', code: 'stock_insufficient');

    expect(
      appErrorMessage(
        error,
        fallback: 'حدث خطأ غير متوقع.',
        operation: 'sales.create',
      ),
      'الكمية غير كافية',
    );
  });

  test('keeps internal exception details out of string output', () {
    const error = AppException('secret text', code: 'safe_code');
    expect(error.toString(), 'AppException(safe_code)');
  });

  test('hides unexpected internal error details from the user', () {
    expect(
      appErrorMessage(
        StateError('SQL failure at C:/private/path with sensitive data'),
        fallback: 'تعذر إكمال العملية.',
        operation: 'database.write',
      ),
      'تعذر إكمال العملية.',
    );
  });
}
